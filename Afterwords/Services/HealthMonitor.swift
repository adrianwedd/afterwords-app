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

    /// The CLIExecutor owns the configurable server port. We read it fresh
    /// at the start of each poll — an in-flight URLSession task still hits
    /// the old URL until it completes, but the next poll (2–5s later) picks
    /// up the new value, which is acceptable for human-driven config changes.
    private let cliExecutor: CLIExecutor

    /// How often to poll when server is `.running` (seconds).
    private let normalInterval: TimeInterval = 5.0

    /// How often to poll when server is `.starting` (seconds).
    private let startingInterval: TimeInterval = 2.0

    /// How long to wait for server to become healthy before declaring `.error`.
    private let startupTimeout: TimeInterval = 90.0

    /// Per-request timeout. Health is a localhost call against a server that
    /// either responds in ~1ms or won't respond at all; the default URLSession
    /// timeout (60s) would let a single hung connection mask many polls.
    private let requestTimeout: TimeInterval = 3.0

    /// Consecutive health-check failures before declaring server down.
    private let crashConfirmCount = 3

    private var timer: Timer?
    private var consecutiveFailures = 0
    private var startAttemptDate: Date?
    private var hasCompletedFirstPoll = false

    /// Tracks whether a poll is in flight so we don't pile multiple URLSession
    /// requests on top of each other when responses are slow.
    private var pollInFlight = false

    /// Set by notifyStopAttempt(); cleared on the first poll result while in
    /// .stopped state. Blocks a stale in-flight 200 from clobbering the
    /// user-requested .stopped state and triggering a false crash error.
    private var pendingStop = false

    /// Dedicated URLSession so the short per-request timeout doesn't affect
    /// any other code path that happens to use URLSession.shared.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 3.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

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
        pendingStop = false
        startAttemptDate = Date()
        state = .starting(since: startAttemptDate!)
        consecutiveFailures = 0
        // Switch to faster polling during startup
        reschedulePoll(interval: startingInterval)
    }

    /// Notify that a stop command was issued. Transitions to `.stopped`.
    func notifyStopAttempt() {
        pendingStop = true
        state = .stopped
        consecutiveFailures = 0
        startAttemptDate = nil
    }

    // MARK: - Testing

    #if DEBUG
    /// Simulate a health-check result. For unit tests only — not callable in
    /// release builds, preventing accidental production use.
    func simulateHealthResult(info: HealthInfo? = nil, error: String? = nil) {
        if let info {
            handleHealthSuccess(info)
        } else {
            handleHealthFailure(error: error ?? "connection refused")
        }
    }

    /// Drive handleHealthResponse directly for tests (e.g. the oversize-body
    /// guard, which simulateHealthResult cannot reach because it takes a decoded
    /// HealthInfo). For unit tests only.
    func simulateHealthResponse(data: Data?, response: URLResponse?, error: Error?) {
        handleHealthResponse(data: data, response: response, error: error)
    }
    #endif

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
                // Note: scheduleNextPoll() is now driven by checkHealth's
                // completion handler so the next poll never overlaps with
                // an in-flight one. See pollInFlight.
            }
        }
    }

    private func checkHealth() {
        // If a previous poll is still in flight, skip this tick. The completion
        // handler will reschedule once it lands. This prevents request pile-up
        // when the server is slow or unreachable.
        if pollInFlight {
            scheduleNextPoll()
            return
        }

        let urlString = "http://localhost:\(cliExecutor.port)/health"
        guard let url = URL(string: urlString) else {
            scheduleNextPoll()
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        pollInFlight = true

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.pollInFlight = false
                self.handleHealthResponse(data: data, response: response, error: error)
                self.scheduleNextPoll()
            }
        }
        task.resume()
    }

    private func handleHealthResponse(data: Data?, response: URLResponse?, error: Error?) {
        // Bind data locally so the precondition is explicit (no later force-unwrap).
        guard error == nil, let data = data else {
            handleHealthFailure(error: error?.localizedDescription ?? "No response")
            return
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            handleHealthFailure(error: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            return
        }

        // Reject an oversized body before decoding it (security finding #4).
        if ResponseLimit.exceeds(advertisedContentLength: httpResponse.expectedContentLength,
                                 byteCount: data.count,
                                 limit: ResponseLimit.health) {
            handleHealthFailure(error: "Health response too large")
            return
        }

        do {
            let info = try JSONDecoder().decode(HealthInfo.self, from: data)
            handleHealthSuccess(info)
        } catch {
            handleHealthFailure(error: "Invalid JSON: \(error.localizedDescription)")
        }
    }

    private func handleHealthSuccess(_ info: HealthInfo) {
        consecutiveFailures = 0
        startAttemptDate = nil
        hasCompletedFirstPoll = true
        // Ignore a stale in-flight 200 that arrived after the user clicked Stop.
        // Without this guard, the .stopped → .running flip causes the next 3 poll
        // failures to surface as a false "Server crashed" error after a clean stop.
        if case .stopped = state, pendingStop { pendingStop = false; return }
        state = .running(info)
    }

    private func handleHealthFailure(error: String) {
        consecutiveFailures += 1
        // hasCompletedFirstPoll is set unconditionally on every poll result so
        // that a .starting or .running→.error path can't leave the flag false
        // and inadvertently re-arm auto-start on a later .stopped poll.
        // @MainActor serialises all callers, so no lock is needed.
        defer { hasCompletedFirstPoll = true }

        switch state {
        case .starting(let since):
            // Check for startup timeout
            let elapsed = Date().timeIntervalSince(since)
            if elapsed >= startupTimeout {
                state = .error(message: "Server did not become healthy within \(Int(startupTimeout))s")
                startAttemptDate = nil
            }
            // Still starting (or just timed out) — keep polling at the faster rate

        case .running:
            // Was running, now failing. Confirm crash before declaring error.
            if consecutiveFailures >= crashConfirmCount {
                state = .error(message: "Server crashed: \(error)")
            }
            // If not enough failures yet, keep polling at normal rate

        case .stopped:
            pendingStop = false
            // On first confirmed-stopped result, honour the auto-start preference.
            // notifyStartAttempt() before startServer() matches the manual UI path
            // and ensures state is .starting before the fire-and-forget CLI call.
            if !hasCompletedFirstPoll,
               UserDefaults.standard.bool(forKey: "autoStartServer") {
                notifyStartAttempt()
                cliExecutor.startServer()
            }

        case .error:
            break
        }
    }
}