import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var cliExecutor: CLIExecutor
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoStartServer") private var autoStartServer = false
    @AppStorage("cliPathOverride") private var cliPathOverride = ""

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
                    if let path = CLIExecutor.detectCLIPath() {
                        cliPathOverride = path
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
                TextField(
                    "7860",
                    value: Binding(
                        get: { cliExecutor.port },
                        set: { cliExecutor.setPort($0) }
                    ),
                    format: .number.grouping(.never)
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
            }
            .help("Used for health checks and the API link. The server itself binds to the port it was launched with — restart the server manually after changing this.")

            LabeledContent("Detected CLI") {
                Text(CLIExecutor.detectCLIPath() ?? "Not found")
                    .foregroundStyle(CLIExecutor.detectCLIPath() != nil ? .green : .red)
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

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = false
            print("Failed to \(enabled ? "register" : "unregister") launch at login: \(error)")
        }
    }
}