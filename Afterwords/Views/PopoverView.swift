import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var healthMonitor: HealthMonitor
    @EnvironmentObject var cliExecutor: CLIExecutor
    @Environment(\.openWindow) private var openWindow
    @AppStorage("preferredVoice") private var preferredVoice = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusView()

            Divider()

            HStack(spacing: 8) {
                Button {
                    cliExecutor.startServer()
                    healthMonitor.notifyStartAttempt()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(healthMonitor.state.isRunning || healthMonitor.state.isStarting || cliExecutor.isExecuting)
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    cliExecutor.stopServer()
                    healthMonitor.notifyStopAttempt()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!healthMonitor.state.isRunning || cliExecutor.isExecuting)

                Button {
                    cliExecutor.restartServer()
                    healthMonitor.notifyStartAttempt()
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .disabled(!healthMonitor.state.isRunning || cliExecutor.isExecuting)
            }

            if let error = cliExecutor.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    cliExecutor.openLogs()
                } label: {
                    Label("Logs", systemImage: "text.justify.leading")
                }

                Button {
                    if let url = URL(string: "http://localhost:\(cliExecutor.port)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("API", systemImage: "globe")
                }
            }

            Divider()

            if case .running(let info) = healthMonitor.state {
                Text("\(info.loadedBackends.count) backend\(info.loadedBackends.count == 1 ? "" : "s"), \(info.voices.count) voice\(info.voices.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !preferredVoice.isEmpty {
                Text("Default voice: \(preferredVoice)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Button {
                openWindow(id: "voice-list")
            } label: {
                Label("Voices…", systemImage: "list.bullet")
            }
            .disabled(!healthMonitor.state.isRunning)

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label("Settings…", systemImage: "gear")
            }
        }
        .padding(12)
        .frame(minWidth: 240)
    }
}