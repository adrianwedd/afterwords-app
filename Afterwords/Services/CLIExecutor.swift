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

    /// Whether playback is muted. Mirrors the sentinel file at `/tmp/afterwords-muted`.
    @Published var isMuted: Bool = FileManager.default.fileExists(atPath: "/tmp/afterwords-muted")

    private let muteFilePath = "/tmp/afterwords-muted"

    /// The detected CLI path, resolved synchronously on init by probing known
    /// install locations. Nil if none of the known locations contain the binary.
    @Published private(set) var detectedCLIPath: String?

    init() {
        detectedCLIPath = CLIExecutor.detectCLIPath()
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

    // MARK: - Validation

    /// Validates a candidate CLI path before it is handed to `Process`.
    /// Returns a human-readable error string if the path is unsafe to run,
    /// or nil if it is acceptable.
    ///
    /// Defense-in-depth for the unsandboxed-subprocess surface: `cliPathOverride`
    /// and `additionalPath` live in UserDefaults, which any process running as
    /// the same user can write. This doesn't cross a privilege boundary (such a
    /// process can already run code as the user), but refusing to launch a binary
    /// whose name isn't `afterwords` blocks the casual "repurpose the override to
    /// run something else" attack — including the silent auto-start path — at
    /// zero cost to legitimate use, since every path the app itself produces
    /// (search-path probes, auto-detect, the Settings placeholder) ends in
    /// `/afterwords`.
    nonisolated static func validationError(forCLIPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name == "afterwords" else {
            return "Refusing to run \u{201C}\(name)\u{201D} — the CLI path must point to a binary named afterwords. Check the CLI Path override in Settings."
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return "afterwords binary not found or not executable at \(path)"
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

    // MARK: - Mute

    func toggleMute() {
        lastError = nil
        if isMuted {
            do {
                try FileManager.default.removeItem(atPath: muteFilePath)
            } catch {
                lastError = "Could not unmute: \(error.localizedDescription)"
            }
        } else {
            if !FileManager.default.createFile(atPath: muteFilePath, contents: nil) {
                lastError = "Could not mute: failed to create \(muteFilePath)"
            }
        }
        // The sentinel file remains the source of truth — a failed toggle
        // leaves isMuted matching reality, with lastError explaining why.
        isMuted = FileManager.default.fileExists(atPath: muteFilePath)
    }

    func refreshMuteState() {
        let current = FileManager.default.fileExists(atPath: muteFilePath)
        if current != isMuted { isMuted = current }
    }

    // MARK: - Server Lifecycle Commands

    /// Each lifecycle command returns whether the launch was ACCEPTED — the
    /// CLI path passed validation and the process spawned. It is NOT proof
    /// the command succeeded (the CLI's exit remains fire-and-forget; /health
    /// polling is the single source of truth). Callers use the return value to
    /// avoid flipping HealthMonitor into a .starting/.stopped state that no
    /// process could ever satisfy — a refused or failed-to-spawn Start used to
    /// strand the UI in "Starting…" for the full 90s timeout.
    @discardableResult func startServer() -> Bool { run(["start"], timeout: 30) }
    @discardableResult func stopServer() -> Bool { run(["stop"], timeout: 10) }
    @discardableResult func restartServer() -> Bool { run(["restart"], timeout: 30) }
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

    #if DEBUG
    /// Test seam: drive run() with a custom timeout. Unit tests use this to
    /// exercise subprocess behavior (e.g. pipe-buffer pressure) without the
    /// 10–30s production timeouts. Not compiled into release builds.
    @discardableResult
    func testRun(_ arguments: [String], timeout: TimeInterval) -> Bool {
        run(arguments, timeout: timeout)
    }
    #endif

    /// Returns true if the command was accepted (validated + spawned),
    /// false if it was refused (busy, CLI path validation failed, or the
    /// spawn itself failed). The spawn happens synchronously — posix_spawn
    /// is sub-millisecond — so acceptance means a live process exists;
    /// only exit monitoring is fire-and-forget.
    private func run(_ arguments: [String], timeout: TimeInterval = 30) -> Bool {
        guard !isExecuting else { return false }
        lastError = nil

        let cliPath = resolvedCLIPath
        if let validationError = Self.validationError(forCLIPath: cliPath) {
            lastError = validationError
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments

        // Inject PATH — GUI apps don't inherit shell PATH
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = resolvedPATH
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Spawn before returning: validation can pass yet the spawn still
        // fail (binary replaced or perms lost in between). Reporting that as
        // accepted would flip HealthMonitor into a .starting state no process
        // can ever satisfy, stranding the UI until the 90s startup timeout.
        do {
            try process.run()
        } catch {
            lastError = "Failed to run afterwords: \(error.localizedDescription)"
            return false
        }

        isExecuting = true

        Task.detached {
            // Kill the subprocess after the deadline so isExecuting can never stay true forever.
            // OSAllocatedUnfairLock provides safe cross-Task signalling without a data race.
            let didTimeout = OSAllocatedUnfairLock(initialState: false)
            let watchdog = Task { [process] in
                try await Task.sleep(for: .seconds(timeout))
                didTimeout.withLock { $0 = true }
                process.terminate()
            }
            // Drain both pipes WHILE the process runs. A pipe buffer holds
            // ~64KB; a verbose CLI that fills it blocks on write and never
            // exits, so draining only after waitUntilExit() would stall
            // every such command until the watchdog kills it and reports a
            // bogus timeout.
            async let stdoutData = Self.drain(stdout.fileHandleForReading)
            async let stderrData = Self.drain(stderr.fileHandleForReading)

            process.waitUntilExit()
            watchdog.cancel()

            _ = await stdoutData
            let errorOutput = String(data: await stderrData, encoding: .utf8) ?? ""

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
        }
        return true
    }

    /// Read a pipe to EOF off the calling thread. `readDataToEndOfFile()` is
    /// blocking, so it runs on a global queue; the caller awaits both pipes
    /// concurrently while waitUntilExit() blocks the detached task's thread.
    nonisolated private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: handle.readDataToEndOfFile())
            }
        }
    }
}
