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
                        let path = await Task.detached { CLIExecutor.detectCLIPath() }.value
                        if let path { cliPathOverride = path }
                    }
                }
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
                Text(detectedCLIPath ?? "Not found")
                    .foregroundStyle(detectedCLIPath != nil ? .green : .red)
                    .task {
                        guard detectedCLIPath == nil else { return }
                        detectedCLIPath = await Task.detached { CLIExecutor.detectCLIPath() }.value
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