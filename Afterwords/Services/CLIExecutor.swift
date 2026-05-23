import AppKit
import Foundation
import os

/// Executes `afterwords` CLI commands via Foundation.Process with explicit PATH injection.
///
/// macOS GUI apps don't inherit the shell PATH, so every process environment gets
/// `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` plus any user-configured path prepended.
@MainActor
final class CLIExecutor: ObservableObject {
    /// The server port used for health polling and the "Open API" link.
    ///
    /// Persisted in UserDefaults under `"serverPort"`. Setter clamps to a valid
    /// TCP port range. Changing this does NOT reconfigure the server — the
    /// server binds to whatever port its launchd plist (or command-line) specified.
    /// To make the server bind to a new port, edit the launchd plist (or pass
    /// `--port`) separately.
    @Published var port: Int = CLIExecutor.loadPort()

    /// Valid TCP port range for the afterwords server. The launchd LaunchAgent
    /// runs unprivileged, so ports 1...1023 are unbindable without elevation —
    /// we reject them outright rather than let a user save a port that will
    /// never work in the shipped deployment.
    static let portRange = 1024...65535

    /// Factory-default port. Used as the loadPort() fallback when no override
    /// is stored, and as the SettingsView TextField placeholder.
    static let defaultPort = 7860

    private static func loadPort() -> Int {
        let stored = UserDefaults.standard.integer(forKey: "serverPort")
        return portRange.contains(stored) ? stored : defaultPort
    }

    /// Update the server port. Clamps to the valid range and persists.
    func setPort(_ newValue: Int) {
        let clamped = max(Self.portRange.lowerBound, min(Self.portRange.upperBound, newValue))
        port = clamped
        UserDefaults.standard.set(clamped, forKey: "serverPort")
    }

    /// Whether a CLI command is currently executing.
    @Published private(set) var isExecuting = false

    /// The last error from a CLI command, if any.
    @Published var lastError: String?

    /// The asynchronously-detected CLI path, populated once on init. Cached so
    /// that `run()` never has to spawn `which afterwords` (a login-shell
    /// subprocess that sources ~/.zshrc) on the MainActor. Nil until detection
    /// completes; consumers fall back to the hardcoded default.
    @Published private(set) var detectedCLIPath: String?

    init() {
        // Kick off detection in the background so the first user click never
        // pays for it. The detection itself runs off-MainActor (detectCLIPath
        // is `nonisolated`) via a child detached task; the assignment hops
        // back to MainActor through this Task's implicit MainActor inheritance.
        Task { [weak self] in
            let path = await Task.detached { CLIExecutor.detectCLIPath() }.value
            self?.detectedCLIPath = path
        }
    }

    private let defaultPathDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    // MARK: - CLI Discovery

    /// Well-known locations to probe for the `afterwords` binary, in
    /// preference order. Pure filesystem checks — no subprocess, no shell,
    /// no .zshrc side effects, deterministic.
    /// `nonisolated` so detectCLIPath() (also nonisolated) can read it from
    /// the background detection task without bouncing off MainActor.
    nonisolated private static let cliSearchPaths = [
        "/usr/local/bin/afterwords",      // setup.sh symlink
        "/opt/homebrew/bin/afterwords",   // Apple Silicon Homebrew
        "/opt/homebrew/sbin/afterwords",
        "/usr/bin/afterwords",
    ]

    /// Resolves the path to the `afterwords` binary by probing known
    /// install locations. Returns nil if none are present; callers fall
    /// back to a hardcoded default. Users with a binary outside these
    /// locations should set an explicit override in Settings.
    nonisolated static func detectCLIPath() -> String? {
        for path in cliSearchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - Resolved Paths

    /// The resolved path to the `afterwords` binary, used for all CLI calls.
    /// Order: user override > cached background-detected path > hardcoded
    /// default. Never spawns a subprocess on the calling thread.
    private var resolvedCLIPath: String {
        let override = UserDefaults.standard.string(forKey: "cliPathOverride") ?? ""
        if !override.isEmpty {
            return override
        }
        return detectedCLIPath ?? "/usr/local/bin/afterwords"
    }

    /// The PATH value injected into every subprocess environment.
    private var resolvedPATH: String {
        let userPaths = UserDefaults.standard.string(forKey: "additionalPath") ?? ""
        let defaultPath = defaultPathDirectories.joined(separator: ":")
        if userPaths.isEmpty {
            return defaultPath
        }
        return userPaths + ":" + defaultPath
    }

    // MARK: - Server Lifecycle Commands

    func startServer() { run(["start"], timeout: 30) }
    func stopServer() { run(["stop"], timeout: 10) }
    func restartServer() { run(["restart"], timeout: 30) }
    func openLogs() {
        lastError = nil
        let logPath = "/tmp/claude-tts-server.log"
        guard FileManager.default.fileExists(atPath: logPath) else {
            lastError = "Log file not found — start the server to create it"
            return
        }
        // afterwords logs runs `tail -f` — it never exits and has no terminal to display in.
        // Open the log file in Console.app instead (created by launchd at server start).
        if !NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) {
            lastError = "Could not open log file in Console.app"
        }
    }

    // MARK: - Execution

    private func run(_ arguments: [String], timeout: TimeInterval = 30) {
        guard !isExecuting else { return }
        lastError = nil
        isExecuting = true

        Task.detached { [cliPath = resolvedCLIPath, path = resolvedPATH] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = arguments

            // Inject PATH — GUI apps don't inherit shell PATH
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            process.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()

                // Kill the subprocess after the deadline so isExecuting can never stay true forever.
                // OSAllocatedUnfairLock provides safe cross-Task signalling without a data race.
                let didTimeout = OSAllocatedUnfairLock(initialState: false)
                let watchdog = Task { [process] in
                    try await Task.sleep(for: .seconds(timeout))
                    didTimeout.withLock { $0 = true }
                    process.terminate()
                }
                process.waitUntilExit()
                watchdog.cancel()

                let _ = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                await MainActor.run {
                    self.isExecuting = false
                    if didTimeout.withLock({ $0 }) && process.terminationStatus != 0 {
                        // terminationStatus != 0 guards against the narrow race where the watchdog
                        // sets didTimeout just before the process exits cleanly (status 0).
                        self.lastError = "Command timed out after \(Int(timeout))s"
                    } else if process.terminationStatus != 0 {
                        self.lastError = errorOutput.isEmpty
                            ? "Command failed with exit code \(process.terminationStatus)"
                            : errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isExecuting = false
                    self.lastError = "Failed to run afterwords: \(error.localizedDescription)"
                }
            }
        }
    }
}