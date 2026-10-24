import Foundation
import AppKit

/// Fetches a synthesized WAV from the afterwords server and plays it via NSSound.
///
/// Design notes (after multi-agent QA round 2 on commit 11b1c8c):
///
/// - **Request tokens.** Each playSample() call bumps a monotonic token.
///   fetchAndPlay() carries its token and bails out if a newer call has
///   superseded it before any state mutation that follows an `await`. This
///   replaces the earlier checkCancellation pattern, which had race windows
///   between the await suspension and the next checkCancellation call.
///
/// - **Off-main file I/O.** The synthesized WAV (~30–100 KB) is decoded
///   directly into NSSound from the in-memory Data; we never write a temp
///   file. This avoids both the main-thread file-write block Gemini flagged
///   and the temp-file accumulation Hermes/Codex flagged. Also dodges the
///   path-traversal concern from voice names containing slashes.
///
/// - **Sound lifecycle.** NSSoundDelegate clears currentSound when playback
///   finishes, so we don't accumulate decoded audio buffers across clicks.
///   stop() lets the window owner halt playback on close (the SamplePlayer
///   StateObject outlives the window, so without an explicit stop, audio
///   keeps playing into the void).
@MainActor
final class SamplePlayer: NSObject, ObservableObject {
    private let cliExecutor: CLIExecutor

    /// The voice name currently being fetched or played, for UI affordances.
    @Published private(set) var playingVoice: String?

    /// Last error from a sample fetch/playback, for UI display.
    @Published var lastError: String?

    /// Holds the active NSSound so it isn't deallocated mid-playback.
    private var currentSound: NSSound?

    /// Monotonic request token. Incremented for every playSample call;
    /// fetchAndPlay only mutates state if its captured token still matches.
    private var latestToken: UInt64 = 0
    private var fetchTask: Task<Void, Never>?

    /// Configuration for the bounded sample fetch. Passed to `BoundedTransfer`,
    /// which builds a per-transfer session from it, so the timeouts below are the
    /// transfer's timeouts. `internal` for the config assertion in
    /// SamplePlayerTests.
    static let sessionConfiguration: URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return config
    }()

    init(cliExecutor: CLIExecutor) {
        self.cliExecutor = cliExecutor
        super.init()
    }

    #if DEBUG
    /// Test seam: configuration used for sample fetches. Tests install one
    /// carrying a mock `URLProtocol`, so no test ever opens a socket.
    var fetchConfiguration: URLSessionConfiguration = SamplePlayer.sessionConfiguration
    #else
    private let fetchConfiguration: URLSessionConfiguration = SamplePlayer.sessionConfiguration
    #endif

    /// Synthesize a fixed phrase with the named voice and play it.
    func playSample(voice: String) {
        // stopPlayback() increments latestToken to cancel any prior in-flight request.
        // Capture myToken AFTER the stop so it equals the new latestToken — capturing
        // before would leave myToken one behind, making every applyIfCurrent check fail.
        stopPlayback()
        let myToken = latestToken

        let phrase = "Hello. This is the \(voice) voice."
        guard let url = synthesizeURL(text: phrase, voice: voice) else {
            lastError = "Could not build synthesize URL for voice \(voice)"
            return
        }

        playingVoice = voice
        lastError = nil

        fetchTask = Task { [weak self] in
            guard let self else { return }
            await self.fetchAndPlay(url: url, voice: voice, token: myToken)
        }
    }

    /// Halt the currently-playing sound. Safe to call from .onDisappear.
    func stopPlayback() {
        fetchTask?.cancel()
        fetchTask = nil
        currentSound?.stop()
        currentSound = nil
        // Invalidate any in-flight token so the resuming task won't mutate
        // playingVoice or play a fetched sound after a user-initiated stop.
        latestToken &+= 1
        playingVoice = nil
    }

    /// Build the GET /synthesize URL for the given text+voice.
    /// Internal access for testability.
    func synthesizeURL(text: String, voice: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = cliExecutor.port
        components.path = "/synthesize"
        components.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "voice", value: voice),
        ]
        return components.url
    }

    private func fetchAndPlay(url: URL, voice: String, token: UInt64) async {
        defer {
            if token == latestToken { fetchTask = nil }
        }
        let body: Data
        do {
            // Bounded read (issue #9): the transfer is aborted as soon as the
            // /synthesize response crosses the sample cap, instead of buffering
            // the whole body and rejecting it afterwards. The 200 check moved
            // into the reader so a non-200 body is never transferred.
            let result = try await BoundedTransfer.fetch(URLRequest(url: url),
                                                          limit: ResponseLimit.sample,
                                                          configuration: fetchConfiguration)
            body = result.data
        } catch let error as BoundedTransferError {
            // A newer click or stopPlayback() already won — drop everything and
            // leave the state to the newer request (unchanged semantics).
            guard token == latestToken else { return }
            await applyIfCurrent(token) {
                self.playingVoice = nil
                switch error {
                case .httpStatus(let code):  self.lastError = self.humanReadable(status: code)
                case .cancelled:             self.lastError = nil
                case .nonHTTPResponse:       self.lastError = error.localizedDescription
                case .advertisedLengthOverCap, .receivedBytesOverCap:
                    self.lastError = "Server response too large to play."
                case .transport:
                    self.lastError = error.localizedDescription
                }
            }
            return
        } catch {
            await applyIfCurrent(token) {
                self.playingVoice = nil
                self.lastError = error.localizedDescription
            }
            return
        }

        // If a newer click superseded us, drop everything.
        guard token == latestToken else { return }

        guard let sound = NSSound(data: body) else {
            await applyIfCurrent(token) {
                self.playingVoice = nil
                self.lastError = "Could not decode WAV from server"
            }
            return
        }

        await applyIfCurrent(token) {
            sound.delegate = self
            self.currentSound = sound
            sound.play()
            // playingVoice stays set until the sound's delegate clears it on
            // didFinishPlaying — that's the natural moment the spinner should
            // disappear.
        }
    }

    /// Apply state mutations on MainActor, but only if this request is still
    /// the latest. Centralizes the "is my token still current?" check after
    /// every async suspension point.
    private func applyIfCurrent(_ token: UInt64, _ body: @MainActor () -> Void) async {
        await MainActor.run { [weak self] in
            guard let self, token == self.latestToken else { return }
            body()
        }
    }

    private func humanReadable(status: Int) -> String {
        switch status {
        case 503: return "Server is warming up — try again in a moment."
        case 404: return "Voice not found on the server."
        case 400: return "Server rejected the synthesize request (HTTP 400)."
        default:  return "HTTP \(status)"
        }
    }
}

extension SamplePlayer: NSSoundDelegate {
    nonisolated func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.currentSound === sound {
                self.currentSound = nil
                self.playingVoice = nil
            }
        }
    }
}
