import Foundation

enum ServerState: Equatable {
    case stopped
    case starting(since: Date)
    case running(HealthInfo)
    case error(message: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running(let info): return "Running (\(info.voices.count) voices)"
        case .error(let message): return "Error: \(message)"
        }
    }

    var statusIconName: String {
        switch self {
        case .stopped: return "waveform.circle"
        case .starting: return "waveform.circle"
        case .running: return "waveform.circle.fill"
        case .error: return "waveform.badge.exclamationmark"
        }
    }
    // Equatable conformance is synthesized — all associated values
    // (Date, HealthInfo, String) are themselves Equatable.
}