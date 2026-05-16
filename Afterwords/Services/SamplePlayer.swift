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

    init(cliExecutor: CLIExecutor) {
        self.cliExecutor = cliExecutor
        super.init()
    }

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

        Task { [weak self] in
            guard let self else { return }
            await self.fetchAndPlay(url: url, voice: voice, token: myToken)
        }
    }

    /// Halt the currently-playing sound. Safe to call from .onDisappear.
    func stopPlayback() {
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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            await applyIfCurrent(token) {
                self.playingVoice = nil
                self.lastError = error.localizedDescription
            }
            return
        }

        // If a newer click superseded us, drop everything.
        guard token == latestToken else { return }

        guard let httpResponse = response as? HTTPURLResponse else {
            await applyIfCurrent(token) {
                self.playingVoice = nil
                self.lastError = "No HTTP response"
            }
            return
        }

        guard httpResponse.statusCode == 200 else {
            let message = humanReadable(status: httpResponse.statusCode)
            await applyIfCurrent(token) {
                self.playingVoice = nil
                self.lastError = message
            }
            return
        }

        guard let sound = NSSound(data: data) else {
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
