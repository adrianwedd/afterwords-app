import XCTest
import AppKit
@testable import Afterwords

final class ServerStateTests: XCTestCase {

    func testStoppedState() {
        let state = ServerState.stopped
        XCTAssertFalse(state.isRunning)
        XCTAssertFalse(state.isStarting)
        XCTAssertFalse(state.isError)
        XCTAssertEqual(state.displayName, "Stopped")
        XCTAssertEqual(state.statusIconName, "waveform.circle")
    }

    func testStartingState() {
        let date = Date()
        let state = ServerState.starting(since: date)
        XCTAssertFalse(state.isRunning)
        XCTAssertTrue(state.isStarting)
        XCTAssertFalse(state.isError)
        XCTAssertEqual(state.displayName, "Starting…")
        XCTAssertEqual(state.statusIconName, "waveform.circle")
    }

    func testRunningState() {
        let info = HealthInfo(
            status: "ok",
            loadedBackends: [
                HealthInfo.BackendInfo(name: "qwen3-0.6b", supportedLangs: ["en", "es"])
            ],
            voices: ["galadriel", "picard"]
        )
        let state = ServerState.running(info)
        XCTAssertTrue(state.isRunning)
        XCTAssertFalse(state.isStarting)
        XCTAssertFalse(state.isError)
        XCTAssertEqual(state.displayName, "Running (2 voices)")
        XCTAssertEqual(state.statusIconName, "waveform.circle.fill")
    }

    func testErrorState() {
        let state = ServerState.error(message: "Connection refused")
        XCTAssertFalse(state.isRunning)
        XCTAssertTrue(state.isError)
        XCTAssertEqual(state.displayName, "Error: Connection refused")
        XCTAssertEqual(state.statusIconName, "waveform.badge.exclamationmark")
    }

    func testAllStatusIconNamesResolveToImages() {
        let date = Date()
        let info = HealthInfo(status: "ok", loadedBackends: [], voices: [])
        let states: [ServerState] = [.stopped, .starting(since: date), .running(info), .error(message: "x")]
        for state in states {
            let name = state.statusIconName
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            XCTAssertNotNil(image, "SF Symbol '\(name)' is unavailable on this OS — icon will be invisible")
        }
    }

    func testEquality() {
        let date = Date()
        XCTAssertNotEqual(ServerState.starting(since: date), ServerState.stopped)
        XCTAssertNotEqual(ServerState.starting(since: date), ServerState.starting(since: Date()))
        XCTAssertEqual(ServerState.starting(since: date), ServerState.starting(since: date))

        let info = HealthInfo(status: "ok", loadedBackends: [], voices: [])
        XCTAssertEqual(ServerState.running(info), ServerState.running(info))
        XCTAssertNotEqual(ServerState.running(info), ServerState.stopped)
    }
}