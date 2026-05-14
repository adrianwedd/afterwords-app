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
                .onChange(of: launchAtLogin) { _, newValue in
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
                Text("\(cliExecutor.port)")
                    .foregroundStyle(.secondary)
            }
            .help("Port is currently hardcoded to 7860. Will be configurable in a future version.")

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