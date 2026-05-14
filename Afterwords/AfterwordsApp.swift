import SwiftUI

@main
struct AfterwordsApp: App {
    @StateObject private var healthMonitor = HealthMonitor()
    @StateObject private var cliExecutor = CLIExecutor()

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