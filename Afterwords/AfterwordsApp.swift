import SwiftUI

@main
struct AfterwordsApp: App {
    @StateObject private var cliExecutor: CLIExecutor
    @StateObject private var healthMonitor: HealthMonitor
    @StateObject private var samplePlayer: SamplePlayer
    @StateObject private var updaterController = UpdaterController()

    init() {
        // Wire HealthMonitor to read its port from CLIExecutor so a Settings
        // change reaches the next poll without restarting the monitor.
        let executor = CLIExecutor()
        let monitor = HealthMonitor(cliExecutor: executor)
        let player = SamplePlayer(cliExecutor: executor)
        _cliExecutor = StateObject(wrappedValue: executor)
        _healthMonitor = StateObject(wrappedValue: monitor)
        _samplePlayer = StateObject(wrappedValue: player)

        // Kick off polling immediately so the status icon reflects the live
        // server state on app launch (pre-existing server detection). Without
        // this, the timer never starts until the user clicks Start.
        Task { @MainActor in
            monitor.startMonitoring()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(healthMonitor)
                .environmentObject(cliExecutor)
                .environmentObject(updaterController)
        } label: {
            Image(systemName: healthMonitor.state.statusIconName)
                .accessibilityLabel("Afterwords — \(healthMonitor.state.displayName)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(cliExecutor)
        }

        Window("Voices", id: "voice-list") {
            VoiceListView()
                .environmentObject(healthMonitor)
                .environmentObject(samplePlayer)
        }
        .windowResizability(.contentSize)
    }
}