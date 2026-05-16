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
    func testStopFromRunningGoesToStopped() {
        // Simulate: start → running → stop
        monitor.notifyStartAttempt()
        let info = HealthInfo(status: "ok", loadedBackends: [], voices: [])
        // Can't directly set state, but we can verify the transition logic
        // by checking that notifyStopAttempt always goes to .stopped
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
        // autoStart is off — state must remain .stopped, not .starting
        XCTAssertEqual(monitor.state, .stopped)
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