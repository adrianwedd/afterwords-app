import XCTest
@testable import Afterwords

/// Call-site tests driving a real `checkHealth()` poll through the bounded
/// reader against an in-process mock transport (issue #9). Offline: no socket,
/// and the live TTS server is never contacted.
@MainActor
final class HealthMonitorPollTests: XCTestCase {

    private var monitor: HealthMonitor!
    private var executor: CLIExecutor!
    private var stubDir: URL!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "serverPort")
        UserDefaults.standard.removeObject(forKey: "autoStartServer")
        // Same no-op `afterwords` stub as HealthMonitorTests, so the auto-start
        // path's launch-acceptance gate passes without a real binary.
        stubDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
        let stub = stubDir.appendingPathComponent("afterwords")
        try? "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        UserDefaults.standard.set(stub.path, forKey: "cliPathOverride")
        executor = CLIExecutor()
        monitor = HealthMonitor(cliExecutor: executor)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        UserDefaults.standard.removeObject(forKey: "autoStartServer")
        UserDefaults.standard.removeObject(forKey: "cliPathOverride")
        try? FileManager.default.removeItem(at: stubDir)
        stubDir = nil
        monitor = nil
        executor = nil
        super.tearDown()
    }

    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 10,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    private func startPolling() {
        monitor.sessionConfigurationForTesting = MockHTTPProtocol.configuration(requestTimeout: 2,
                                                                                resourceTimeout: 2)
        monitor.notifyStartAttempt()
        monitor.startMonitoring()
    }

    func testPollAcceptsAnUnderCapHealthBody() {
        var script = MockHTTPProtocol.Script()
        script.body = Data(#"{"status":"ok","voices":["a","b"]}"#.utf8)
        MockHTTPProtocol.setScript(script)

        startPolling()
        waitUntil("the poll to reach .running") { self.monitor.state.isRunning }
        guard case .running(let info) = monitor.state else {
            return XCTFail("Expected .running, got \(monitor.state)")
        }
        XCTAssertEqual(info.voices, ["a", "b"])
    }

    /// The whole-body guard from the earlier fix is now enforced during transfer:
    /// a valid but oversized JSON body is rejected without ever being buffered
    /// whole, and the failed poll keeps the state out of `.running`.
    func testPollRejectsAdvertisedOversizeBodyWithoutTransferringIt() {
        var script = MockHTTPProtocol.Script()
        script.streamTotalBytes = ResponseLimit.health + 1
        script.chunkSize = 128 * 1024
        // Deliberately valid JSON would be unnecessary here — the reader refuses
        // on the advertised length alone, before any byte arrives.
        MockHTTPProtocol.setScript(script)

        startPolling()
        // Give the poll time to fail and reschedule at least once.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(monitor.state.isRunning,
                       "An oversized /health body must not produce .running")
        XCTAssertEqual(MockHTTPProtocol.deliveredBytes, 0,
                       "An advertised-oversized /health body must not be transferred")
    }

    func testPollAcceptsUnknownLengthBodyAtExactCap() {
        var script = MockHTTPProtocol.Script()
        script.omitContentLength = true
        let wrapper = "{\"status\":\"ok\",\"pad\":\"\"}"
        let pad = String(repeating: "a", count: ResponseLimit.health - wrapper.utf8.count)
        script.body = Data(("{\"status\":\"ok\",\"pad\":\"" + pad + "\"}").utf8)
        XCTAssertEqual(script.body.count, ResponseLimit.health)
        MockHTTPProtocol.setScript(script)

        startPolling()
        waitUntil("an exact-cap health body to reach running") { self.monitor.state.isRunning }
        XCTAssertEqual(MockHTTPProtocol.deliveredBytes, ResponseLimit.health)
    }

    /// The 3s poll budget survives the move to the bounded reader.
    func testPollSessionConfigurationKeepsBoundedTimeouts() {
        let config = HealthMonitor.defaultSessionConfiguration
        XCTAssertEqual(config.timeoutIntervalForRequest, 3.0)
        XCTAssertEqual(config.timeoutIntervalForResource, 3.0)
        XCTAssertFalse(config.waitsForConnectivity)
    }
}
