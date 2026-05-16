import Foundation

/// Polls GET /health and publishes server state transitions.
///
/// State machine:
/// - `.stopped` → `afterwords start` → `.starting(since: Date)`
/// - `.starting` → health 200 → `.running(HealthInfo)`
/// - `.starting` → 90s timeout → `.error("Server did not become healthy…")`
/// - `.running` → 3 consecutive failures → `.error(message)`
/// - `.error` → `afterwords start` → `.starting(since: Date)`
/// - `.running` → `afterwords stop` → `.stopped`
///
/// HealthMonitor is the single source of truth for server state.
/// CLIExecutor calls are fire-and-forget; this class detects the results.
@MainActor
final class HealthMonitor: ObservableObject {
    @Published private(set) var state: ServerState = .stopped

    /// The CLIExecutor owns the configurable server port. We read it fresh on
    /// every poll so a Settings change takes effect on the next health check
    /// without needing to restart the monitor.
    private let cliExecutor: CLIExecutor

    /// How often to poll when server is `.running` (seconds).
    private let normalInterval: TimeInterval = 5.0

    /// How often to poll when server is `.starting` (seconds).
    private let startingInterval: TimeInterval = 2.0

    /// How long to wait for server to become healthy before declaring `.error`.
    private let startupTimeout: TimeInterval = 90.0

    /// Consecutive health-check failures before declaring server down.
    private let crashConfirmCount = 3

    private var timer: Timer?
    private var consecutiveFailures = 0
    private var startAttemptDate: Date?

    init(cliExecutor: CLIExecutor) {
        self.cliExecutor = cliExecutor
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Start polling. Called once when the app launches.
    func startMonitoring() {
        // Immediately check if server is already running
        checkHealth()
        scheduleNextPoll()
    }

    /// Stop polling. Called when the app quits.
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Notify that a start command was issued. Transitions to `.starting`.
    func notifyStartAttempt() {
        startAttemptDate = Date()
        state = .starting(since: startAttemptDate!)
        consecutiveFailures = 0
        // Switch to faster polling during startup
        reschedulePoll(interval: startingInterval)
    }

    /// Notify that a stop command was issued. Transitions to `.stopped`.
    func notifyStopAttempt() {
        state = .stopped
        consecutiveFailures = 0
        startAttemptDate = nil
    }

    // MARK: - Polling

    private func scheduleNextPoll() {
        let interval: TimeInterval
        switch state {
        case .starting:
            interval = startingInterval
        default:
            interval = normalInterval
        }
        reschedulePoll(interval: interval)
    }

    private func reschedulePoll(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.checkHealth()
                self?.scheduleNextPoll()
            }
        }
    }

    private func checkHealth() {
        let urlString = "http://localhost:\(cliExecutor.port)/health"
        guard let url = URL(string: urlString) else { return }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            Task { @MainActor in
                self?.handleHealthResponse(data: data, response: response, error: error)
            }
        }
        task.resume()
    }

    private func handleHealthResponse(data: Data?, response: URLResponse?, error: Error?) {
        // Connection refused or network error
        if error != nil || data == nil {
            handleHealthFailure(error: error?.localizedDescription ?? "No response")
            return
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            handleHealthFailure(error: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            return
        }

        do {
            let info = try JSONDecoder().decode(HealthInfo.self, from: data!)
            handleHealthSuccess(info)
        } catch {
            handleHealthFailure(error: "Invalid JSON: \(error.localizedDescription)")
        }
    }

    private func handleHealthSuccess(_ info: HealthInfo) {
        consecutiveFailures = 0
        startAttemptDate = nil
        state = .running(info)
    }

    private func handleHealthFailure(error: String) {
        consecutiveFailures += 1

        switch state {
        case .starting(let since):
            // Check for startup timeout
            let elapsed = Date().timeIntervalSince(since)
            if elapsed >= startupTimeout {
                state = .error(message: "Server did not become healthy within \(Int(startupTimeout))s")
                startAttemptDate = nil
                return
            }
            // Still starting, keep polling at the faster rate
            return

        case .running:
            // Was running, now failing. Confirm crash before declaring error.
            if consecutiveFailures >= crashConfirmCount {
                state = .error(message: "Server crashed: \(error)")
            }
            // If not enough failures yet, keep polling at normal rate

        case .stopped:
            // Server was stopped, health failure is expected
            break

        case .error:
            // Already in error state, no change needed
            break
        }
    }
}