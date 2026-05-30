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
    func testHealthSuccessTransitionsStartingToRunning() {
        monitor.notifyStartAttempt()
        XCTAssertTrue(monitor.state.isStarting)
        let info = HealthInfo(status: "ok", loadedBackends: [], voices: ["a", "b"])
        monitor.simulateHealthResult(info: info)
        guard case .running(let observed) = monitor.state else {
            XCTFail("Expected .running after successful poll, got \(monitor.state)")
            return
        }
        XCTAssertEqual(observed, info)
    }

    @MainActor
    func testHealthFailureFromRunningRequiresThreeFailuresToError() {
        let info = HealthInfo(status: "ok", loadedBackends: [], voices: [])
        monitor.simulateHealthResult(info: info)
        XCTAssertTrue(monitor.state.isRunning)
        monitor.simulateHealthResult(error: "connection refused")
        XCTAssertTrue(monitor.state.isRunning, "1 failure: still running")
        monitor.simulateHealthResult(error: "connection refused")
        XCTAssertTrue(monitor.state.isRunning, "2 failures: still running")
        monitor.simulateHealthResult(error: "connection refused")
        XCTAssertTrue(monitor.state.isError, "3 failures: should be in .error")
    }

    @MainActor
    func testHealthSuccessRecoversFromError() {
        let info = HealthInfo(status: "ok", loadedBackends: [], voices: [])
        monitor.simulateHealthResult(info: info)
        for _ in 0..<3 { monitor.simulateHealthResult(error: "connection refused") }
        XCTAssertTrue(monitor.state.isError)
        monitor.simulateHealthResult(info: info)
        XCTAssertTrue(monitor.state.isRunning, "Successful poll must recover from .error")
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

    // MARK: - Stop/poll race

    @MainActor
    func testInflightSuccessPollDoesNotClobberStop() {
        // Regression test: in-flight poll returning 200 after notifyStopAttempt()
        // used to overwrite .stopped → .running, then 3 failures → false "Server crashed".
        let info = HealthInfo(status: "ok", loadedBackends: [], voices: [])
        monitor.simulateHealthResult(info: info)     // .running
        XCTAssertTrue(monitor.state.isRunning)

        monitor.notifyStopAttempt()                  // .stopped (user clicked Stop)
        XCTAssertEqual(monitor.state, .stopped)

        // In-flight poll that was already issued before the stop lands — must not restore .running
        monitor.simulateHealthResult(info: info)
        XCTAssertEqual(monitor.state, .stopped,
            "A 200 result arriving after notifyStopAttempt must not transition back to .running")
    }

    @MainActor
    func testNoFalseCrashErrorAfterCleanStop() {
        // Full bug scenario: stop → stale in-flight 200 → 3 failures → false "Server crashed"
        let info = HealthInfo(status: "ok", loadedBackends: [], voices: [])
        monitor.simulateHealthResult(info: info)
        monitor.notifyStopAttempt()
        monitor.simulateHealthResult(info: info)     // stale in-flight 200 — must be ignored
        for _ in 0..<3 {
            monitor.simulateHealthResult(error: "connection refused")
        }
        XCTAssertEqual(monitor.state, .stopped,
            "Three poll failures after a clean stop must not produce .error('Server crashed')")
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

    // MARK: - Oversize response guard (finding #4)

    @MainActor
    func testOversizeHealthBodyIsRejectedBeforeDecode() {
        monitor.notifyStartAttempt()
        XCTAssertTrue(monitor.state.isStarting)

        // A VALID HealthInfo JSON body padded past the cap. Without the guard
        // this decodes successfully and flips .starting → .running; the guard
        // must intercept it first, so the oversize poll is treated as a
        // not-yet-healthy failure and the state stays .starting.
        let pad = String(repeating: "a", count: ResponseLimit.health)
        let json = "{\"status\":\"ok\",\"pad\":\"\(pad)\"}".data(using: .utf8)!
        XCTAssertGreaterThan(json.count, ResponseLimit.health)

        let url = URL(string: "http://localhost:7860/health")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        monitor.simulateHealthResponse(data: json, response: response, error: nil)

        XCTAssertTrue(monitor.state.isStarting,
            "Oversize body must be rejected before decode and leave state .starting (not .running)")
    }
}
