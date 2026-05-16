import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var cliExecutor: CLIExecutor
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoStartServer") private var autoStartServer = false
    @AppStorage("cliPathOverride") private var cliPathOverride = ""

    /// Local text buffer for the port TextField. Commits to cliExecutor only
    /// on submit (Enter) or focus loss — typing intermediate values like
    /// empty string or partial digits doesn't trigger clamping.
    @State private var portText: String = ""
    @FocusState private var portFocused: Bool

    /// Populated asynchronously on first appear — detectCLIPath() spawns a
    /// subprocess and must not block the main thread.
    @State private var detectedCLIPath: String? = nil

    /// Guards against the re-entrant onChange call that fires when we revert
    /// launchAtLogin inside updateLaunchAtLogin's catch block.
    @State private var isUpdatingLaunchAtLogin = false

    /// Prevents concurrent detectCLIPath() subprocesses when the Advanced tab
    /// is dismissed and re-shown before the first detection finishes.
    @State private var isDetectingCLIPath = false

    /// Set to true once the first detection task completes (or is cancelled
    /// and re-tried). Keeps the display in "Detecting…" state until then so
    /// the user never sees a false red "Not found" on initial render.
    @State private var cliDetectionComplete = false

    /// Prevents concurrent Auto-detect button taps from spawning multiple
    /// zsh subprocesses; also grays out the button while in flight.
    @State private var isAutoDetecting = false

    var body: some View {
        TabView {
            GeneralTab()
            AdvancedTab()
        }
        .frame(width: 450, height: 280)
    }

    private func GeneralTab() -> some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    guard !isUpdatingLaunchAtLogin else { return }
                    updateLaunchAtLogin(newValue)
                }
                .help("Automatically open Afterwords when you log in")

            Toggle("Auto-start Server", isOn: $autoStartServer)
                .help("Start the TTS server when Afterwords opens")

            LabeledContent("CLI Path") {
                TextField("/usr/local/bin/afterwords", text: $cliPathOverride)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                Button("Auto-detect") {
                    Task {
                        guard !isAutoDetecting else { return }
                        isAutoDetecting = true
                        defer { isAutoDetecting = false }
                        let path = await Task.detached { CLIExecutor.detectCLIPath() }.value
                        if !Task.isCancelled, let path { cliPathOverride = path }
                    }
                }
                .disabled(isAutoDetecting)
            }
            .help("Path to the afterwords binary. Leave empty for auto-detection.")
        }
        .padding()
        .tabItem { Label("General", systemImage: "gearshape") }
    }

    private func AdvancedTab() -> some View {
        Form {
            LabeledContent("Server Port") {
                TextField(String(CLIExecutor.defaultPort), text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .focused($portFocused)
                    .onAppear { portText = String(cliExecutor.port) }
                    .onSubmit { commitPortText() }
                    .onChange(of: portFocused) { focused in
                        if !focused { commitPortText() }
                    }
            }
            .help("Sets where the app looks for the server (1024–65535). The server binds to whatever port its launchd plist (or command line) specified — to actually change where the server listens, edit the plist or pass --port separately, then restart it. Changing this alone will make the app's health checks fail until the server is reconfigured.")

            LabeledContent("Detected CLI") {
                Text(cliDetectionComplete ? (detectedCLIPath ?? "Not found") : "Detecting…")
                    .foregroundStyle(
                        !cliDetectionComplete ? Color.secondary :
                        detectedCLIPath != nil ? Color.green : Color.red
                    )
                    .task {
                        guard detectedCLIPath == nil, !isDetectingCLIPath else { return }
                        isDetectingCLIPath = true
                        defer { isDetectingCLIPath = false }
                        let path = await Task.detached { CLIExecutor.detectCLIPath() }.value
                        if !Task.isCancelled {
                            detectedCLIPath = path
                            cliDetectionComplete = true
                        }
                    }
            }

            LabeledContent("Health Endpoint") {
                Text("http://localhost:\(cliExecutor.port)/health")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
    }

    /// Parse the port text buffer and commit it to cliExecutor (which clamps
    /// to the valid range). On invalid input (non-numeric, empty), revert the
    /// buffer to the current persisted value so the user sees the rejection.
    private func commitPortText() {
        if let parsed = Int(portText) {
            cliExecutor.setPort(parsed)
        }
        portText = String(cliExecutor.port)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        isUpdatingLaunchAtLogin = true
        defer { isUpdatingLaunchAtLogin = false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = !enabled
            print("Failed to \(enabled ? "register" : "unregister") launch at login: \(error)")
        }
    }
}