import SwiftUI

/// Status hero card — redesigned for v1.2.
/// Sunken card with a colored dot, mono headline, explanatory sub-text,
/// and a trailing equalizer (running) or progress spinner (starting).
struct StatusView: View {
    @EnvironmentObject var healthMonitor: HealthMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(headline)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(healthMonitor.state.isError ? Color.red : Color.primary)
                Spacer()
                trailing
            }
            Text(sub)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(healthMonitor.state.isError ? Color.red : Color.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.dsElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.dsBorder, lineWidth: 0.5)
        )
    }

    private var dotColor: Color {
        switch healthMonitor.state {
        case .stopped:  return .secondary
        case .starting: return .yellow
        case .running:  return .dsGreen
        case .error:    return .red
        }
    }

    private var headline: String {
        switch healthMonitor.state {
        case .stopped:  return "Server stopped"
        case .starting: return "Starting\u{2026}"
        case .running:  return "Running"
        case .error:    return "Server crashed"
        }
    }

    private var sub: String {
        switch healthMonitor.state {
        case .stopped:
            return "Press Start to launch the local server."
        case .starting:
            return "Waiting for the first healthy /health poll."
        case .running(let info):
            let backend = info.primaryBackend?.name ?? "\u{2014}"
            return "\(backend) \u{00B7} \(info.voices.count) voice\(info.voices.count == 1 ? "" : "s") loaded"
        case .error(let message):
            return message
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if healthMonitor.state.isRunning {
            EqualizerView(active: true, color: .dsGreen, barCount: 11, maxHeight: 14)
        } else if healthMonitor.state.isStarting {
            ProgressView()
                .scaleEffect(0.65)
                .frame(width: 18, height: 18)
        }
    }
}
