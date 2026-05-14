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
        switch healthMonitor.state {
        case .stopped:
            Image(systemName: "waveform.circle")
                .foregroundStyle(.secondary)
        case .starting:
            Image(systemName: "waveform.circle")
                .foregroundStyle(.yellow)
        case .running:
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "waveform.circle.badge.xmark")
                .foregroundStyle(.red)
        }
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