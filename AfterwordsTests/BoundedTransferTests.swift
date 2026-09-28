import XCTest
@testable import Afterwords

/// Unit tests for the shared bounded-transfer reader (issue #9).
///
/// Every test runs against `MockHTTPProtocol` — an in-process transport — so no
/// test opens a socket, resolves a name, or touches the live TTS server. The
/// assertions are about *during-transfer* behaviour: how many body bytes the
/// client actually pulled, and how many it held in memory, rather than a
/// post-hoc predicate over an already-buffered body.
final class BoundedTransferTests: XCTestCase {

    private let limit = 64 * 1024

    private func request(path: String = "/probe") -> URLRequest {
        URLRequest(url: URL(string: "http://localhost:7911\(path)")!)
    }

    private func fetch(limit: Int? = nil,
                       requestTimeout: TimeInterval = 15,
                       resourceTimeout: TimeInterval = 60) async throws -> BoundedTransferResult {
        try await BoundedTransfer.fetch(request(),
                                        limit: limit ?? self.limit,
                                        configuration: MockHTTPProtocol.configuration(
                                            requestTimeout: requestTimeout,
                                            resourceTimeout: resourceTimeout))
    }

    // MARK: - Normal response

    func testNormalResponseUnderCapIsAcceptedWhole() async throws {
        var script = MockHTTPProtocol.Script()
        script.body = Data(repeating: 0x41, count: 4096)
        MockHTTPProtocol.setScript(script)

        let result = try await fetch()
        XCTAssertEqual(result.data.count, 4096)
        XCTAssertEqual(result.response.statusCode, 200)
        XCTAssertEqual(result.data, Data(repeating: 0x41, count: 4096))
        XCTAssertLessThanOrEqual(result.maximumRetainedBytes, limit)
    }

    /// Equality to the cap is accepted, not rejected — and the body is not
    /// truncated.
    func testBodyExactlyEqualToCapIsAccepted() async throws {
        var script = MockHTTPProtocol.Script()
        script.body = Data(repeating: 0x42, count: limit)
        MockHTTPProtocol.setScript(script)

        let result = try await fetch()
        XCTAssertEqual(result.data.count, limit, "count == limit must be accepted whole")
    }

    // MARK: - Advertised oversized body (stage 1)

    func testAdvertisedLengthOverCapAbortsBeforeAnyBodyByte() async throws {
        var script = MockHTTPProtocol.Script()
        // 4 MiB advertised against a 64 KiB cap. The reader must refuse in the
        // response callback, so the mock's delivery never starts.
        script.streamTotalBytes = 4 * 1024 * 1024
        MockHTTPProtocol.setScript(script)

        do {
            _ = try await fetch()
            XCTFail("Expected advertisedLengthOverCap")
        } catch let error as BoundedTransferError {
            guard case .advertisedLengthOverCap(let advertised, let cap) = error else {
                return XCTFail("Expected advertisedLengthOverCap, got \(error)")
            }
            XCTAssertEqual(advertised, Int64(4 * 1024 * 1024))
            XCTAssertEqual(cap, limit)
            XCTAssertTrue(error.isSizeRejection)
        }
        XCTAssertEqual(MockHTTPProtocol.deliveredBytes, 0,
                       "An advertised-oversized body must not be transferred at all")
    }

    // MARK: - Received bytes over cap (stage 2)

    func testChunkedBodyOverCapAbortsEarlyWithBoundedRetainedBytes() async throws {
        // No Content-Length at all: only the running byte count can catch this.
        var script = MockHTTPProtocol.Script()
        script.omitContentLength = true
        script.streamTotalBytes = 8 * 1024 * 1024
        script.chunkSize = 16 * 1024
        let chunkSize = script.chunkSize
        MockHTTPProtocol.setScript(script)

        do {
            _ = try await fetch()
            XCTFail("Expected receivedBytesOverCap")
        } catch let error as BoundedTransferError {
            guard case .receivedBytesOverCap(let received, let retained, let cap) = error else {
                return XCTFail("Expected receivedBytesOverCap, got \(error)")
            }
            XCTAssertEqual(cap, limit)
            // Aborted on the first chunk past the cap: at most one chunk of
            // overshoot, never the whole 8 MiB body.
            XCTAssertGreaterThan(received, limit)
            XCTAssertLessThanOrEqual(received, limit + script.chunkSize)
            XCTAssertLessThanOrEqual(retained, limit,
                                     "The rejected chunk must not enter the retained buffer")
        }

        let delivered = MockHTTPProtocol.deliveredBytes
        XCTAssertLessThanOrEqual(delivered, limit + 2 * script.chunkSize,
                                 "The transfer must abort at the cap, not after the whole body")
        XCTAssertLessThan(delivered, 8 * 1024 * 1024,
                          "8 MiB body, \(limit)-byte cap: the client pulled \(delivered) bytes")
    }

    func testUnknownLengthBodyExactlyAtCapIsAccepted() async throws {
        var script = MockHTTPProtocol.Script()
        script.omitContentLength = true
        script.body = Data(repeating: 0x43, count: limit)
        MockHTTPProtocol.setScript(script)

        let result = try await fetch()
        XCTAssertEqual(result.data.count, limit)
        XCTAssertEqual(result.data.first, 0x43)
        XCTAssertEqual(result.data.last, 0x43)
    }

    func testUnknownLengthBodyBelowCapIsAcceptedWithoutDiskSpill() async throws {
        // A legitimate body larger than the small test cap, accepted under a
        // larger cap and retained only in memory.
        var script = MockHTTPProtocol.Script()
        script.omitContentLength = true
        script.streamTotalBytes = 768 * 1024
        script.chunkSize = 64 * 1024
        MockHTTPProtocol.setScript(script)

        let result = try await fetch(limit: 4 * 1024 * 1024)
        XCTAssertEqual(result.data.count, 768 * 1024)
        XCTAssertEqual(result.maximumRetainedBytes, result.data.count)
        XCTAssertLessThanOrEqual(result.maximumRetainedBytes, 4 * 1024 * 1024)
    }

    // MARK: - Failure paths

    func testTransportFailureSurfaces() async throws {
        var script = MockHTTPProtocol.Script()
        script.failWith = URLError(.cannotConnectToHost)
        MockHTTPProtocol.setScript(script)

        do {
            _ = try await fetch()
            XCTFail("Expected a transport failure")
        } catch let error as BoundedTransferError {
            guard case .transport = error else {
                return XCTFail("Expected .transport, got \(error)")
            }
            XCTAssertFalse(error.isSizeRejection)
        }
    }

    func testNon200IsAStatusErrorNotASizeRejection() async throws {
        var script = MockHTTPProtocol.Script()
        script.statusCode = 503
        script.body = Data(repeating: 0x44, count: 128)
        MockHTTPProtocol.setScript(script)

        do {
            _ = try await fetch()
            XCTFail("Expected httpStatus")
        } catch let error as BoundedTransferError {
            guard case .httpStatus(let code) = error else {
                return XCTFail("Expected .httpStatus, got \(error)")
            }
            XCTAssertEqual(code, 503)
            XCTAssertFalse(error.isSizeRejection)
            XCTAssertEqual(error.localizedDescription, "HTTP 503")
        }
        XCTAssertEqual(MockHTTPProtocol.deliveredBytes, 0,
                       "A non-200 body must not be transferred")
    }

    /// A server that accepts the connection and then stalls without finishing.
    /// The bounded reader must still fail — the stall is ended by the caller's
    /// resource timeout, which stays in force.
    func testStalledTransferBoundedByResourceTimeout() async throws {
        var script = MockHTTPProtocol.Script()
        script.omitContentLength = true
        script.stallAfterBytes = 1024
        MockHTTPProtocol.setScript(script)

        do {
            _ = try await fetch(requestTimeout: 1, resourceTimeout: 1)
            XCTFail("A stalled transfer must fail, not hang")
        } catch let error as BoundedTransferError {
            guard case .transport = error else {
                return XCTFail("Expected .transport (timeout), got \(error)")
            }
        }
    }

    func testCancellingTheSwiftTaskAbortsTheTransfer() async throws {
        // Cap far above the amount delivered before cancellation, so only
        // cancellation ends this transfer.
        var script = MockHTTPProtocol.Script()
        script.omitContentLength = true
        script.streamTotalBytes = 64 * 1024 * 1024
        script.chunkSize = 16 * 1024
        MockHTTPProtocol.setScript(script)

        let probe = request()
        let configuration = MockHTTPProtocol.configuration(requestTimeout: 5, resourceTimeout: 30)
        let task = Task {
            try await BoundedTransfer.fetch(probe, limit: 4 * 1024 * 1024, configuration: configuration)
        }
        try? await Task.sleep(nanoseconds: 50_000_000) // let a few chunks land
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must abort the transfer")
        } catch let error as BoundedTransferError {
            guard case .cancelled = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
        }
        XCTAssertLessThan(MockHTTPProtocol.deliveredBytes, 4 * 1024 * 1024,
                          "Cancellation must stop delivery well short of the body")
    }
}
