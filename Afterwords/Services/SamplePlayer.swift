import Foundation
import AppKit

/// Fetches a synthesized WAV from the afterwords server and plays it via NSSound.
///
/// Stays out of CLIExecutor (which is for `afterwords` CLI commands only) and
/// out of HealthMonitor (which is for polling). One synthesis at a time —
/// starting a new sample cancels any in-flight playback by re-assigning the
/// `currentSound` reference.
@MainActor
final class SamplePlayer: ObservableObject {
    private let cliExecutor: CLIExecutor

    /// The voice name currently being fetched or played, for UI affordances.
    @Published private(set) var playingVoice: String?

    /// Last error from a sample fetch/playback, for UI display.
    @Published var lastError: String?

    /// Holds the active NSSound so it isn't deallocated mid-playback.
    private var currentSound: NSSound?

    /// Tracks the in-flight fetch so a newer click can cancel an older one.
    private var currentTask: Task<Void, Never>?

    init(cliExecutor: CLIExecutor) {
        self.cliExecutor = cliExecutor
    }

    /// Synthesize a fixed phrase with the named voice and play it.
    func playSample(voice: String) {
        // Cancel any in-flight task and stop any playing sound.
        currentTask?.cancel()
        currentSound?.stop()

        let phrase = "Hello. This is the \(voice) voice."
        guard let url = synthesizeURL(text: phrase, voice: voice) else {
            lastError = "Could not build synthesize URL for voice \(voice)"
            return
        }

        playingVoice = voice
        lastError = nil

        let task = Task { [weak self] in
            guard let self else { return }
            await self.fetchAndPlay(url: url, voice: voice)
        }
        currentTask = task
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

    private func fetchAndPlay(url: URL, voice: String) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse else {
                await finish(error: "No HTTP response")
                return
            }
            guard httpResponse.statusCode == 200 else {
                await finish(error: "HTTP \(httpResponse.statusCode)")
                return
            }

            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("afterwords-sample-\(voice).wav")
            try data.write(to: tempURL, options: .atomic)

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let sound = NSSound(contentsOf: tempURL, byReference: false) else {
                    self.lastError = "Could not decode WAV from server"
                    self.playingVoice = nil
                    return
                }
                self.currentSound = sound
                sound.play()
            }
        } catch is CancellationError {
            // Newer click superseded us; the newer task will set playingVoice.
        } catch {
            await finish(error: error.localizedDescription)
        }

        // Once the sound is queued for playback, clear playingVoice. NSSound is
        // fire-and-forget; the UI's "playing" state ends when the network/decode
        // step completes, not when the audio actually finishes — playing the
        // full clip would require a delegate, which we can add if users want it.
        await MainActor.run { [weak self] in
            self?.playingVoice = nil
        }
    }

    private func finish(error message: String) async {
        await MainActor.run { [weak self] in
            self?.playingVoice = nil
            self?.lastError = message
        }
    }
}
