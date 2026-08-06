import SwiftUI

/// Menu-bar popover — v1.2 redesign.
/// Layout: header → status hero → transport → utility row →
///         voice chip → footer menu items.
struct PopoverView: View {
    @EnvironmentObject var healthMonitor: HealthMonitor
    @EnvironmentObject var cliExecutor: CLIExecutor
    @EnvironmentObject var updaterController: UpdaterController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("preferredVoice") private var preferredVoice = ""

    private var busy: Bool    { cliExecutor.isExecuting }
    private var running: Bool { healthMonitor.state.isRunning }
    private var starting: Bool { healthMonitor.state.isStarting }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 8) {
                StatusView()
                transportRow
                if let error = cliExecutor.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                utilityRow
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            voiceChip
            Divider()
            footerItems
        }
        .frame(width: 300)
        .animation(.easeInOut(duration: 0.15), value: healthMonitor.state)
        .animation(.easeInOut(duration: 0.15), value: cliExecutor.lastError)
        .animation(.easeInOut(duration: 0.15), value: cliExecutor.isMuted)
        .onAppear { cliExecutor.lastError = nil }
    }

    // MARK: — Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: running ? "waveform.circle.fill" : "waveform.circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(running ? Color.accentColor : Color.secondary)
            Text("afterwords")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Text("CONTROL PANEL")
                .font(.system(size: 9, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: — Transport

    private var transportRow: some View {
        HStack(spacing: 6) {
            if running || starting {
                Button {
                    guard !busy else { return }
                    // Only mirror the state change if the CLI accepted the
                    // command — a refused launch (validation error) must not
                    // fake a transition the poll loop can never confirm.
                    if cliExecutor.stopServer() {
                        healthMonitor.notifyStopAttempt()
                    }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Color.red.opacity(0.75))
                .disabled(busy || starting)
            } else {
                Button {
                    guard !busy else { return }
                    if cliExecutor.startServer() {
                        healthMonitor.notifyStartAttempt()
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(busy)
            }
            Button {
                guard !busy else { return }
                if cliExecutor.restartServer() {
                    healthMonitor.notifyStartAttempt()
                }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
            .disabled(!running || busy)
        }
    }

    // MARK: — Utility row

    private var utilityRow: some View {
        HStack(spacing: 6) {
            Button {
                cliExecutor.openLogs()
            } label: {
                Label("Logs", systemImage: "text.justify.leading")
            }
            .disabled(!running)

            Button {
                if let url = URL(string: "http://localhost:\(cliExecutor.port)") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("API", systemImage: "globe")
            }
            .disabled(!running)

            Spacer()

            Button {
                cliExecutor.toggleMute()
            } label: {
                Label(
                    cliExecutor.isMuted ? "Unmute" : "Mute",
                    systemImage: cliExecutor.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                )
            }
            .tint(cliExecutor.isMuted ? .orange : nil)
        }
    }

    // MARK: — Voice chip

    private var voiceChip: some View {
        Button {
            openWindow(id: "voice-list")
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "mic")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("DEFAULT VOICE")
                        .font(.system(size: 9, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(.tertiary)
                    Text(preferredVoice.isEmpty ? "none set" : preferredVoice)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(preferredVoice.isEmpty ? Color.secondary : Color.accentColor)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!running)
        .opacity(running ? 1 : 0.55)
    }

    // MARK: — Footer

    private var footerItems: some View {
        VStack(spacing: 0) {
            PopoverMenuRow(icon: "list.bullet", label: "Voices\u{2026}", meta: voicesMeta) {
                openWindow(id: "voice-list")
            }
            .disabled(!running)

            settingsRow

            PopoverMenuRow(icon: "arrow.down.circle", label: "Check for Updates\u{2026}", meta: nil) {
                updaterController.checkForUpdates()
            }
            .disabled(!updaterController.canCheckForUpdates)
        }
        .padding(.vertical, 4)
    }

    private var settingsRow: some View {
        PopoverMenuRow(icon: "gear", label: "Settings\u{2026}", meta: nil) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
            DispatchQueue.main.async {
                NSApp.windows.first(where: { $0.title == "Settings" })?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private var voicesMeta: String? {
        guard case .running(let info) = healthMonitor.state else { return nil }
        return "\(info.voices.count)"
    }
}

// MARK: — Footer row helpers

private struct PopoverMenuRow: View {
    let icon: String
    let label: String
    let meta: String?
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            PopoverMenuRowContent(icon: icon, label: label, meta: meta)
        }
        .buttonStyle(.plain)
        .background(hovered ? Color.primary.opacity(0.06) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { hovered = $0 }
        .padding(.horizontal, 6)
    }
}


struct PopoverMenuRowContent: View {
    let icon: String
    let label: String
    let meta: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 13))
            Spacer()
            if let meta {
                Text(meta)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}
