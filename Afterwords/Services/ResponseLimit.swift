import Foundation

/// Localhost response caps enforced while bytes arrive, before decoding or playback.
enum ResponseLimit {
    static let health = 5 * 1024 * 1024
    static let sample = 25 * 1024 * 1024

    /// Equality to the cap is accepted. A negative advertised length is unknown.
    static func exceeds(advertisedContentLength: Int64, byteCount: Int, limit: Int) -> Bool {
        if advertisedContentLength >= 0 && advertisedContentLength > Int64(limit) { return true }
        return byteCount > limit
    }
}

enum BoundedTransferError: Error, LocalizedError {
    case advertisedLengthOverCap(advertised: Int64, limit: Int)
    case receivedBytesOverCap(received: Int, retained: Int, limit: Int)
    case nonHTTPResponse
    case httpStatus(code: Int)
    case cancelled
    case transport(message: String)

    var isSizeRejection: Bool {
        switch self {
        case .advertisedLengthOverCap, .receivedBytesOverCap: return true
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .advertisedLengthOverCap(_, let limit):
            return "Server response advertises more than the \(limit)-byte cap."
        case .receivedBytesOverCap(_, _, let limit):
            return "Server response exceeded the \(limit)-byte cap."
        case .nonHTTPResponse:
            return "No HTTP response"
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .cancelled:
            return "Request cancelled"
        case .transport(let message):
            return message
        }
    }
}

struct BoundedTransferResult {
    let data: Data
    let response: HTTPURLResponse
    /// Largest reader-owned body buffer after a delegate callback. URLSession's
    /// current delivered chunk is transient and is not included in this count.
    let maximumRetainedBytes: Int
}

/// A per-request URLSession delegate that refuses bodies above `limit`.
///
/// The response callback rejects an oversized advertised length before body
/// processing. For unknown/chunked lengths, the first chunk crossing the cap
/// cancels the task without appending that chunk. The retained Data is therefore
/// never larger than the accepted response cap; no response body is written to
/// disk. URLSession may have one delivered chunk in flight at cancellation.
enum BoundedTransfer {
    static func fetch(_ request: URLRequest,
                      limit: Int,
                      configuration: URLSessionConfiguration) async throws -> BoundedTransferResult {
        precondition(limit >= 0, "limit must be non-negative")
        let reader = BoundedTransferReader(limit: limit)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(configuration: configuration,
                                         delegate: reader,
                                         delegateQueue: nil)
                reader.start(session: session, continuation: continuation, request: request)
            }
        } onCancel: {
            reader.cancel()
        }
    }
}

final class BoundedTransferReader: NSObject, URLSessionDataDelegate {
    let limit: Int

    /// Delegate callbacks are serialized by URLSession, while `cancel()` can
    /// arrive on another thread. The lock also protects the continuation from
    /// double resumption.
    private let lock = NSLock()
    private var settled = false
    private var cancelRequested = false
    private var continuation: CheckedContinuation<BoundedTransferResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var httpResponse: HTTPURLResponse?
    private var buffer = Data()
    private var receivedBytes = 0
    private var maximumRetainedBytes = 0

    init(limit: Int) {
        self.limit = limit
        super.init()
    }

    var peakRetainedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return maximumRetainedBytes
    }

    func start(session: URLSession,
               continuation: CheckedContinuation<BoundedTransferResult, Error>,
               request: URLRequest) {
        lock.lock()
        self.session = session
        self.continuation = continuation
        if cancelRequested {
            lock.unlock()
            settle(.failure(BoundedTransferError.cancelled))
            return
        }

        // Creation and resume stay inside the lock. A concurrent cancel cannot
        // settle between publishing the continuation and publishing the task,
        // then leave a newly resumed request behind.
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        let hasContinuation = continuation != nil
        let alreadySettled = settled
        let task = self.task
        lock.unlock()

        task?.cancel()
        if hasContinuation && !alreadySettled {
            settle(.failure(BoundedTransferError.cancelled))
        }
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            settle(.failure(BoundedTransferError.nonHTTPResponse))
            return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel)
            settle(.failure(BoundedTransferError.httpStatus(code: http.statusCode)))
            return
        }
        if ResponseLimit.exceeds(advertisedContentLength: http.expectedContentLength,
                                 byteCount: 0, limit: limit) {
            completionHandler(.cancel)
            settle(.failure(BoundedTransferError.advertisedLengthOverCap(
                advertised: http.expectedContentLength, limit: limit)))
            return
        }
        lock.lock()
        httpResponse = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        if data.count > limit - receivedBytes {
            let received = receivedBytes + data.count
            let retained = buffer.count
            lock.unlock()
            dataTask.cancel()
            settle(.failure(BoundedTransferError.receivedBytesOverCap(
                received: received, retained: retained, limit: limit)))
            return
        }
        receivedBytes += data.count
        buffer.append(data)
        maximumRetainedBytes = max(maximumRetainedBytes, buffer.count)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock()
            let wasCancelled = cancelRequested
            lock.unlock()
            if wasCancelled {
                settle(.failure(BoundedTransferError.cancelled))
            } else {
                settle(.failure(BoundedTransferError.transport(message: error.localizedDescription)))
            }
        } else {
            finishSuccess()
        }
    }

    private func finishSuccess() {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        let continuation = self.continuation
        let session = self.session
        let http = httpResponse
        let data = buffer
        let peak = maximumRetainedBytes
        self.continuation = nil
        self.session = nil
        self.task = nil
        buffer = Data()
        lock.unlock()

        if let http {
            continuation?.resume(returning: BoundedTransferResult(
                data: data, response: http, maximumRetainedBytes: peak))
        } else {
            continuation?.resume(throwing: BoundedTransferError.nonHTTPResponse)
        }
        session?.finishTasksAndInvalidate()
    }

    private func settle(_ result: Result<BoundedTransferResult, Error>) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.session = nil
        self.task = nil
        buffer = Data()
        lock.unlock()

        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
