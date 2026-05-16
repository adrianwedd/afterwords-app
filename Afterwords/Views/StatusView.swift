import SwiftUI

struct StatusView: View {
    @EnvironmentObject var healthMonitor: HealthMonitor

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            statusText
            Spacer()
            if healthMonitor.state.isStarting {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let color: Color = switch healthMonitor.state {
        case .stopped: .secondary
        case .starting: .yellow
        case .running: .green
        case .error: .red
        }
        Image(systemName: healthMonitor.state.statusIconName)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var statusText: some View {
        switch healthMonitor.state {
        case .stopped:
            Text("Server stopped")
                .foregroundStyle(.secondary)
        case .starting(let since):
            Text("Starting \(since, style: .timer)…")
        case .running(let info):
            Text("Running — \(info.voices.count) voice\(info.voices.count == 1 ? "" : "s")")
        case .error(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Error")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}