import SwiftUI

@main
struct AfterwordsApp: App {
    @StateObject private var cliExecutor: CLIExecutor
    @StateObject private var healthMonitor: HealthMonitor

    init() {
        // Wire HealthMonitor to read its port from CLIExecutor so a Settings
        // change reaches the next poll without restarting the monitor.
        let executor = CLIExecutor()
        _cliExecutor = StateObject(wrappedValue: executor)
        _healthMonitor = StateObject(wrappedValue: HealthMonitor(cliExecutor: executor))
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(healthMonitor)
                .environmentObject(cliExecutor)
        } label: {
            Image(systemName: healthMonitor.state.statusIconName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(cliExecutor)
        }
    }
}