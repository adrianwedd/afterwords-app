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
        case .error: return "waveform.circle.badge.xmark"
        }
    }

    static func == (lhs: ServerState, rhs: ServerState) -> Bool {
        switch (lhs, rhs) {
        case (.stopped, .stopped): return true
        case (.starting(let l), .starting(let r)): return l == r
        case (.running(let l), .running(let r)): return l == r
        case (.error(let l), .error(let r)): return l == r
        default: return false
        }
    }
}