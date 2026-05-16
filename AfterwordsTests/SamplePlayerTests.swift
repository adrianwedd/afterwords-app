import XCTest
@testable import Afterwords

final class SamplePlayerTests: XCTestCase {

    // MARK: - URL construction

    @MainActor
    func testSynthesizeURLUsesCurrentPort() throws {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        defer { UserDefaults.standard.removeObject(forKey: "serverPort") }
        let executor = CLIExecutor()
        let player = SamplePlayer(cliExecutor: executor)

        let url = try XCTUnwrap(player.synthesizeURL(text: "hello", voice: "galadriel"))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "localhost")
        XCTAssertEqual(url.port, 7860)
        XCTAssertEqual(url.path, "/synthesize")

        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryDict = Dictionary(uniqueKeysWithValues:
            (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(queryDict["text"], "hello")
        XCTAssertEqual(queryDict["voice"], "galadriel")
    }

    @MainActor
    func testSynthesizeURLReflectsPortChange() throws {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        defer { UserDefaults.standard.removeObject(forKey: "serverPort") }
        let executor = CLIExecutor()
        let player = SamplePlayer(cliExecutor: executor)

        executor.setPort(8080)
        let url = try XCTUnwrap(player.synthesizeURL(text: "x", voice: "y"))
        XCTAssertEqual(url.port, 8080, "URL should use the new port after setPort")
    }

    @MainActor
    func testSynthesizeURLEncodesQueryCharacters() throws {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        defer { UserDefaults.standard.removeObject(forKey: "serverPort") }
        let executor = CLIExecutor()
        let player = SamplePlayer(cliExecutor: executor)

        // Text containing characters that must be percent-encoded in a query.
        let url = try XCTUnwrap(player.synthesizeURL(
            text: "hello & goodbye, world?",
            voice: "the-doctor"
        ))
        let raw = url.absoluteString
        XCTAssertFalse(raw.contains("hello & goodbye"),
            "Ampersand must be percent-encoded")
        XCTAssertTrue(raw.contains("the-doctor"),
            "Hyphenated voice names are valid in URL queries")
    }

    // MARK: - Initial state

    @MainActor
    func testInitialPlayingVoiceIsNil() {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        defer { UserDefaults.standard.removeObject(forKey: "serverPort") }
        let executor = CLIExecutor()
        let player = SamplePlayer(cliExecutor: executor)
        XCTAssertNil(player.playingVoice)
        XCTAssertNil(player.lastError)
    }

    // MARK: - stopPlayback

    @MainActor
    func testStopPlaybackClearsPlayingVoice() {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        defer { UserDefaults.standard.removeObject(forKey: "serverPort") }
        let executor = CLIExecutor()
        let player = SamplePlayer(cliExecutor: executor)

        // playSample sets playingVoice immediately (the async fetch happens
        // off-thread; we test only the synchronous state mutation here).
        player.playSample(voice: "galadriel")
        XCTAssertEqual(player.playingVoice, "galadriel")

        player.stopPlayback()
        XCTAssertNil(player.playingVoice, "stopPlayback must clear playingVoice")
    }

    @MainActor
    func testRapidPlaySampleSupersedesPreviousVoice() {
        UserDefaults.standard.removeObject(forKey: "serverPort")
        defer { UserDefaults.standard.removeObject(forKey: "serverPort") }
        let executor = CLIExecutor()
        let player = SamplePlayer(cliExecutor: executor)

        player.playSample(voice: "galadriel")
        XCTAssertEqual(player.playingVoice, "galadriel")
        player.playSample(voice: "picard")
        XCTAssertEqual(player.playingVoice, "picard",
            "A second playSample must replace the in-flight playingVoice")
    }
}
