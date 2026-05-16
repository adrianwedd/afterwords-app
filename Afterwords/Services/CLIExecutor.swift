import Foundation

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

    /// Resolves the path to the `afterwords` binary. Priority:
    /// 1. User-configured override (Settings)
    /// 2. `/usr/local/bin/afterwords` (where setup.sh symlinks it)
    /// 3. `which afterwords` output (run via shell)
    static func detectCLIPath() -> String? {
        // Check the default symlink location first
        let defaultPath = "/usr/local/bin/afterwords"
        if FileManager.default.isExecutableFile(atPath: defaultPath) {
            return defaultPath
        }

        // Fall back to `which`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "which afterwords"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {
            // Detection failed, return nil
        }
        return nil
    }

    // MARK: - Resolved Paths

    /// The resolved path to the `afterwords` binary, used for all CLI calls.
    private var resolvedCLIPath: String {
        let override = UserDefaults.standard.string(forKey: "cliPathOverride") ?? ""
        if !override.isEmpty {
            return override
        }
        return Self.detectCLIPath() ?? "/usr/local/bin/afterwords"
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

    func startServer() {
        lastError = nil
        run(["start"])
    }

    func stopServer() {
        lastError = nil
        run(["stop"])
    }

    func restartServer() {
        lastError = nil
        run(["restart"])
    }

    func openLogs() {
        run(["logs"])
    }

    // MARK: - Execution

    private func run(_ arguments: [String]) {
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
                process.waitUntilExit()

                let _ = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                await MainActor.run {
                    self.isExecuting = false
                    if process.terminationStatus != 0 {
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