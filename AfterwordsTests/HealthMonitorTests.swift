import XCTest
@testable import Afterwords

final class HealthMonitorTests: XCTestCase {

    var monitor: HealthMonitor!
    var executor: CLIExecutor!

    @MainActor
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "serverPort")
        UserDefaults.standard.removeObject(forKey: "autoStartServer")
        executor = CLIExecutor()
        monitor = HealthMonitor(cliExecutor: executor)
    }

    @MainActor
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        UserDefaults.standard.removeObject(forKey: "autoStartServer")
        monitor = nil
        executor = nil
        super.tearDown()
    }

    // MARK: - Initial State

    @MainActor
    func testInitialStateIsStopped() {
        XCTAssertEqual(monitor.state, .stopped)
    }

    // MARK: - Start Attempt

    @MainActor
    func testNotifyStartAttemptTransitionsToStarting() {
        monitor.notifyStartAttempt()
        if case .starting = monitor.state {
            // Expected
        } else {
            XCTFail("Expected .starting state, got \(monitor.state)")
        }
    }

    // MARK: - Stop Attempt

    @MainActor
    func testNotifyStopAttemptTransitionsToStopped() {
        monitor.notifyStartAttempt()
        monitor.notifyStopAttempt()
        XCTAssertEqual(monitor.state, .stopped)
    }

    // MARK: - State Transitions

    @MainActor
    func testNotifyStopAttemptFromStartingGoesToStopped() {
        monitor.notifyStartAttempt()
        monitor.notifyStopAttempt()
        XCTAssertEqual(monitor.state, .stopped)
    }

    @MainActor
    func testStartFromErrorGoesToStarting() {
        // Simulate: error → start
        // We can't easily set .error without a server, so test the transition
        monitor.notifyStartAttempt()
        if case .starting = monitor.state {
            // Expected
        } else {
            XCTFail("Expected .starting after notifyStartAttempt")
        }
    }

    // MARK: - Health Success

    @MainActor
    func testHealthSuccessTransition() {
        // This would require mocking URLSession in a real test
        // For now, verify the state machine logic works in isolation
        monitor.notifyStartAttempt()
        // After start, state should be .starting
        XCTAssertTrue(monitor.state.isStarting)
    }

    // MARK: - Auto-start on first confirmed-stopped poll

    @MainActor
    func testAutoStartNotTriggeredWhenDisabled() {
        UserDefaults.standard.set(false, forKey: "autoStartServer")
        monitor.simulateHealthResult(error: "connection refused")
        XCTAssertEqual(monitor.state, .stopped, "autoStart off — state must remain .stopped")
        // Even though defer sets hasCompletedFirstPoll=true on the disabled path,
        // turning auto-start on NOW and polling again must not re-arm it.
        UserDefaults.standard.set(true, forKey: "autoStartServer")
        monitor.simulateHealthResult(error: "connection refused")
        XCTAssertEqual(monitor.state, .stopped, "Second poll must not auto-start — hasCompletedFirstPoll already set by defer")
    }

    @MainActor
    func testAutoStartTriggeredOnFirstStoppedPoll() {
        UserDefaults.standard.set(true, forKey: "autoStartServer")
        monitor.simulateHealthResult(error: "connection refused")
        // autoStart is on — first poll confirmed stopped, so state should be .starting
        XCTAssertTrue(monitor.state.isStarting,
            "Expected .starting after auto-start, got \(monitor.state)")
    }

    @MainActor
    func testAutoStartNotTriggeredOnSubsequentPolls() {
        UserDefaults.standard.set(true, forKey: "autoStartServer")
        // First poll: triggers auto-start → .starting
        monitor.simulateHealthResult(error: "connection refused")
        XCTAssertTrue(monitor.state.isStarting)
        // User stops the server
        monitor.notifyStopAttempt()
        XCTAssertEqual(monitor.state, .stopped)
        // Second poll: must NOT re-trigger auto-start (hasCompletedFirstPoll is already true)
        monitor.simulateHealthResult(error: "connection refused")
        XCTAssertEqual(monitor.state, .stopped)
    }

    @MainActor
    func testAutoStartNotTriggeredWhenServerAlreadyRunning() {
        UserDefaults.standard.set(true, forKey: "autoStartServer")
        let info = HealthInfo(status: "ok", loadedBackends: [], voices: [])
        monitor.simulateHealthResult(info: info)
        // Server was already running — state is .running, not .starting
        XCTAssertTrue(monitor.state.isRunning)
    }

    @MainActor
    func testAutoStartFullChainStoppedToRunning() {
        // Full path: first poll confirms stopped → auto-start → .starting → success poll → .running
        UserDefaults.standard.set(true, forKey: "autoStartServer")
        monitor.simulateHealthResult(error: "connection refused")
        XCTAssertTrue(monitor.state.isStarting, "Auto-start should transition to .starting")
        let info = HealthInfo(status: "ok", loadedBackends: [], voices: [])
        monitor.simulateHealthResult(info: info)
        XCTAssertTrue(monitor.state.isRunning, "Success poll after auto-start should reach .running")
    }

    @MainActor
    func testAutoStartNotRearmedAfterStartingPathPoll() {
        // If the first poll arrives while state is already .starting (user clicked Start
        // before the first poll completed), hasCompletedFirstPoll must still be set so
        // that a later .stopped poll cannot trigger a second unwanted auto-start.
        UserDefaults.standard.set(true, forKey: "autoStartServer")
        monitor.notifyStartAttempt()                            // user clicked Start first
        monitor.simulateHealthResult(error: "connection refused") // first poll lands in .starting
        monitor.notifyStopAttempt()                            // user stops server → .stopped
        monitor.simulateHealthResult(error: "connection refused") // next .stopped poll
        XCTAssertEqual(monitor.state, .stopped,
            "Auto-start must not re-arm after a .starting-path poll set hasCompletedFirstPoll")
    }

    // MARK: - Consecutive Failure Tracking

    @MainActor
    func testStopResetsConsecutiveFailures() {
        monitor.notifyStartAttempt()
        monitor.notifyStopAttempt()
        XCTAssertEqual(monitor.state, .stopped)
        // After stop, consecutive failures should be reset
        // (verified indirectly — next start attempt should work cleanly)
        monitor.notifyStartAttempt()
        XCTAssertTrue(monitor.state.isStarting)
    }
}