import XCTest
@testable import Afterwords

/// Call-site tests for the bounded /synthesize read (issue #9).
///
/// These drive the *real* `playSample` → `fetchAndPlay` path against an
/// in-process mock transport, so they prove the cap is enforced during the
/// transfer rather than inferring it from a predicate. No socket is opened and
/// the live TTS server is never contacted.
@MainActor
final class SamplePlayerFetchTests: XCTestCase {

    private var player: SamplePlayer!
    private var executor: CLIExecutor!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "serverPort")
        UserDefaults.standard.removeObject(forKey: "cliPathOverride")
        executor = CLIExecutor()
        player = SamplePlayer(cliExecutor: executor)
        player.fetchConfiguration = MockHTTPProtocol.configuration(requestTimeout: 3,
                                                                   resourceTimeout: 3)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        UserDefaults.standard.removeObject(forKey: "cliPathOverride")
        player = nil
        executor = nil
        super.tearDown()
    }

    /// Wait for `condition` on the main actor, pumping the run loop so the
    /// player's Task can settle. Bounded so a hung path fails instead of hanging.
    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 20,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    private func makePlayer() {
        player.playSample(voice: "galadriel")
    }

    // MARK: - Normal response

    func testNormalSampleIsPlayedAndNoErrorIsReported() {
        var script = MockHTTPProtocol.Script()
        // Not a real WAV: NSSound(data:) is expected to reject it, which is
        // enough to prove the body itself was accepted and handed onward.
        script.body = Data(repeating: 0x52, count: 2048)
        MockHTTPProtocol.setScript(script)

        makePlayer()
        waitUntil("the fetch to settle (NSSound decode rejection)") {
            self.player.lastError == "Could not decode WAV from server"
        }
        XCTAssertNil(player.playingVoice, "The spinner clears once the body is handed to NSSound")
    }

    // MARK: - Advertised oversized body

    func testAdvertisedOversizeSampleAbortsBeforeTransfer() {
        var script = MockHTTPProtocol.Script()
        script.streamTotalBytes = ResponseLimit.sample + 1
        script.chunkSize = 64 * 1024
        MockHTTPProtocol.setScript(script)

        makePlayer()
        waitUntil("the advertised-size rejection") {
            self.player.lastError == "Server response too large to play."
        }
        XCTAssertNil(player.playingVoice, "A rejected sample must clear the spinner")
        XCTAssertEqual(MockHTTPProtocol.deliveredBytes, 0,
                       "A sample advertising more than the cap must not be transferred at all")
    }

    // MARK: - Chunked / unknown length over cap

    func testChunkedOversizeSampleAbortsEarlyAndBoundedRetainedBytes() {
        var script = MockHTTPProtocol.Script()
        script.omitContentLength = true
        // Just over the cap, in 64 KiB hops: enough to prove the running count
        // trips the cap, without streaming 50 MiB at ~200 hops/second.
        script.streamTotalBytes = ResponseLimit.sample + 4 * 1024 * 1024
        script.chunkSize = 64 * 1024
        MockHTTPProtocol.setScript(script)

        makePlayer()
        waitUntil("the chunked size rejection") {
            self.player.lastError == "Server response too large to play."
        }
        XCTAssertNil(player.playingVoice)
        XCTAssertLessThanOrEqual(MockHTTPProtocol.deliveredBytes,
                                 ResponseLimit.sample + 2 * script.chunkSize,
                                 "Chunked cap must trip at the cap, not after the whole body")
    }

    // MARK: - Transport failure

    func testTransportFailureSurfacesAnErrorAndClearsSpinner() {
        var script = MockHTTPProtocol.Script()
        script.failWith = URLError(.cannotConnectToHost)
        MockHTTPProtocol.setScript(script)

        makePlayer()
        waitUntil("the transport error") { self.player.lastError != nil }
        XCTAssertNil(player.playingVoice)
        XCTAssertFalse(player.lastError?.isEmpty ?? true)
    }

    // MARK: - Cancellation (superseded click / stopPlayback)

    func testStopPlaybackCancelsWithoutReportingAnError() {
        var script = MockHTTPProtocol.Script()
        script.omitContentLength = true
        script.streamTotalBytes = 4 * 1024 * 1024
        script.chunkSize = 32 * 1024
        MockHTTPProtocol.setScript(script)

        makePlayer()
        waitUntil("the sample transfer to begin") { MockHTTPProtocol.deliveredBytes > 0 }
        let beforeStop = MockHTTPProtocol.deliveredBytes
        player.stopPlayback()

        waitUntil("URLSession to cancel the superseded transfer") {
            MockHTTPProtocol.stopCount > 0
        }
        XCTAssertNil(player.playingVoice, "stopPlayback must keep the spinner cleared")
        XCTAssertNil(player.lastError,
                     "A superseded/cancelled fetch must not report an error — the token guard drops it")
        XCTAssertLessThanOrEqual(MockHTTPProtocol.deliveredBytes,
                                 beforeStop + 2 * script.chunkSize,
                                 "Playback stop must not keep streaming the full sample")
    }

    func testNon200SampleReportsTheHumanReadableMessage() {
        var script = MockHTTPProtocol.Script()
        script.statusCode = 503
        script.body = Data(repeating: 0x53, count: 64)
        MockHTTPProtocol.setScript(script)

        makePlayer()
        waitUntil("the status error") { self.player.lastError != nil }
        XCTAssertEqual(player.lastError, "Server is warming up — try again in a moment.")
        XCTAssertEqual(MockHTTPProtocol.deliveredBytes, 0,
                       "A non-200 body must not be transferred")
    }
}
