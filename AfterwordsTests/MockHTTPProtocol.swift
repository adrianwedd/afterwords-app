import XCTest
@testable import Afterwords

/// In-process HTTP transport for tests: registered in a session configuration's
/// `protocolClasses`, it answers every request from the scripted response — no
/// socket, no DNS, no server. Requests to a host other than `localhost` are
/// declined so a misconfigured URL falls through to URLSession's own handling
/// and fails loudly rather than silently hitting the network.
///
/// Delivery is asynchronous, one batch per hop, and stops when `stopLoading()`
/// fires — which is what makes it usable as evidence: the recorded
/// `deliveredBytes` is the real number of body bytes the client pulled before a
/// bounded transfer aborted, not a post-hoc claim.
final class MockHTTPProtocol: URLProtocol {

    struct Script {
        /// Materialised body for a 200 response. Chunked into `chunkSize`-byte
        /// pieces to mimic a streaming server.
        var body: Data = Data()
        /// Batch size for each delivery hop.
        var chunkSize: Int = 32 * 1024
        var statusCode: Int = 200
        /// Overrides the advertised `Content-Length`. `nil` advertises
        /// `body.count` (or `streamTotalBytes`).
        var contentLengthOverride: Int64? = nil
        /// Advertise no `Content-Length` at all — the chunked/unknown-length case.
        var omitContentLength: Bool = false
        /// Stream this many copies of `streamByte` instead of `body`, so a test
        /// can script a body far larger than it wants to allocate.
        var streamTotalBytes: Int? = nil
        var streamByte: UInt8 = 0
        /// Deliver exactly this many body bytes, then stall forever — the
        /// hung-server case that only a timeout or cancellation can end.
        var stallAfterBytes: Int? = nil
        /// Fail the request with this transport error instead of responding.
        var failWith: Error? = nil
        /// Pause before the first delivery hop. Gives the client's delegate queue
        /// time to process the response headers and cancel, so a test asserting
        /// "nothing was transferred" is not racing the transport.
        var initialHopDelay: TimeInterval = 0.02
    }

    /// Script for the next request(s). Guarded because protocol instances run on
    /// a URLSession-managed queue.
    private static let lock = NSLock()
    private static var script = Script()
    private static var deliveredBytesTotal = 0
    private static var stopCountTotal = 0

    /// Serial queue for delivery hops — keeps the hops independent of the
    /// client's delegate queue.
    private static let deliveryQueue = DispatchQueue(label: "MockHTTPProtocol.delivery")

    static func setScript(_ newScript: Script) {
        lock.lock()
        script = newScript
        deliveredBytesTotal = 0
        stopCountTotal = 0
        lock.unlock()
    }

    /// Body bytes handed to the client across all deliveries.
    static var deliveredBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return deliveredBytesTotal
    }

    static var stopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return stopCountTotal
    }

    private static func currentScript() -> Script {
        lock.lock(); defer { lock.unlock() }
        return script
    }

    private static func addDelivered(_ count: Int) {
        lock.lock(); deliveredBytesTotal += count; lock.unlock()
    }

    private static func byteCount(of script: Script) -> Int {
        script.streamTotalBytes ?? script.body.count
    }

    private static func chunk(of script: Script, offset: Int, size: Int) -> Data {
        if let total = script.streamTotalBytes {
            let end = min(offset + size, total)
            return Data(repeating: script.streamByte, count: max(0, end - offset))
        }
        let end = min(offset + size, script.body.count)
        guard offset < end else { return Data() }
        return script.body.subdata(in: offset..<end)
    }

    /// Session configuration using this protocol. Mirrors the shape of the
    /// production configurations (timeouts + no connectivity wait) so tests
    /// exercise the real reader against a realistic configuration.
    static func configuration(requestTimeout: TimeInterval = 15,
                              resourceTimeout: TimeInterval = 60) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.protocolClasses = [MockHTTPProtocol.self]
        return config
    }

    // MARK: - Per-instance stop state

    private let stopLock = NSLock()
    private var stopped = false

    private var isStopped: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopped
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func stopLoading() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
        Self.lock.lock()
        Self.stopCountTotal += 1
        Self.lock.unlock()
    }

    override func startLoading() {
        let script = Self.currentScript()

        if let failure = script.failWith {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        var headers: [String: String] = ["Content-Type": "application/octet-stream"]
        if !script.omitContentLength {
            headers["Content-Length"] = String(script.contentLengthOverride ?? Int64(Self.byteCount(of: script)))
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url,
                                             statusCode: script.statusCode,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let endLimit = script.stallAfterBytes ?? Self.byteCount(of: script)
        deliver(script: script, offset: 0, endLimit: endLimit, stalls: script.stallAfterBytes != nil)
    }

    /// Deliver one batch per hop, stopping as soon as the client cancels.
    ///
    /// The first hop is delayed *off* the session's delegate queue: the client
    /// needs that queue free to process the response headers (and cancel) before
    /// any body byte is handed over, otherwise a "nothing was transferred"
    /// assertion is just a race the transport happens to win.
    private func deliver(script: Script, offset: Int, endLimit: Int, stalls: Bool) {
        guard !isStopped else { return }
        let work: () -> Void = { [weak self] in
            guard let self, !self.isStopped else { return }
            guard offset < endLimit else {
                if !stalls { self.client?.urlProtocolDidFinishLoading(self) }
                return
            }
            let size = min(script.chunkSize, endLimit - offset)
            let data = Self.chunk(of: script, offset: offset, size: size)
            guard !data.isEmpty else {
                if !stalls { self.client?.urlProtocolDidFinishLoading(self) }
                return
            }
            Self.addDelivered(data.count)
            self.client?.urlProtocol(self, didLoad: data)
            // Yield so the client's delegate queue can process the batch (and
            // cancel) between hops.
            Thread.sleep(forTimeInterval: 0.0005)
            self.deliver(script: script, offset: offset + data.count, endLimit: endLimit, stalls: stalls)
        }
        if offset == 0 && script.initialHopDelay > 0 {
            Self.deliveryQueue.asyncAfter(deadline: .now() + script.initialHopDelay, execute: work)
        } else {
            Self.deliveryQueue.async(execute: work)
        }
    }
}
