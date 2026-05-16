import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var cliExecutor: CLIExecutor
    @AppStorage("autoStartServer") private var autoStartServer = false
    @AppStorage("cliPathOverride") private var cliPathOverride = ""

    // OS registration state — SMAppService is the source of truth, not @AppStorage.
    @State private var launchAtLogin = false
    @State private var launchAtLoginLoaded = false
    @State private var launchAtLoginError: String?

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
                .disabled(!launchAtLoginLoaded)
                .onChange(of: launchAtLogin) { newValue in
                    guard !isUpdatingLaunchAtLogin else { return }
                    updateLaunchAtLogin(newValue)
                }
                .help("Automatically open Afterwords when you log in")
                .task {
                    syncLaunchAtLogin()
                }
                .alert("Launch at Login", isPresented: Binding(
                    get: { launchAtLoginError != nil },
                    set: { if !$0 { launchAtLoginError = nil } }
                )) {
                    Button("OK") { launchAtLoginError = nil }
                } message: {
                    Text(launchAtLoginError ?? "")
                }

            Toggle("Auto-start Server", isOn: $autoStartServer)
                .help("Start the TTS server when Afterwords opens")

            LabeledContent("CLI Path") {
                TextField("/usr/local/bin/afterwords", text: $cliPathOverride)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                Button("Auto-detect") {
                    Task {
                        isAutoDetecting = true
                        defer { isAutoDetecting = false }
                        let path = await Task.detached { CLIExecutor.detectCLIPath() }.value
                        guard !Task.isCancelled else { return }
                        if let path { cliPathOverride = path }
                        // Always write detectedCLIPath (even nil) so a re-detect that
                        // finds nothing clears a previously-green stale path.
                        detectedCLIPath = path
                        cliDetectionComplete = true
                    }
                }
                .disabled(isAutoDetecting)
            }
            .help("Path to the afterwords binary. Leave empty for auto-detection.")
        }
        .padding()
        .tabItem { Label("General", systemImage: "gearshape") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLaunchAtLogin()
        }
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
                        // Gate on cliDetectionComplete (not detectedCLIPath == nil) so
                        // a "not found" result (nil path, completion flag true) doesn't
                        // re-probe on every subsequent tab switch.
                        guard !cliDetectionComplete, !isDetectingCLIPath else { return }
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
                Text("http://localhost:\(String(cliExecutor.port))/health")
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

    private func syncLaunchAtLogin() {
        isUpdatingLaunchAtLogin = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        launchAtLoginLoaded = true
        launchAtLoginError = nil
        isUpdatingLaunchAtLogin = false
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
            let status = SMAppService.mainApp.status
            launchAtLogin = status == .enabled
            if enabled && status == .requiresApproval {
                launchAtLoginError = "Afterwords needs permission to open at login. Open System Settings > General > Login Items and enable it there."
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = "Could not \(enabled ? "enable" : "disable") Launch at Login: \(error.localizedDescription)"
        }
    }
}