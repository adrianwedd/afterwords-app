import XCTest
@testable import Afterwords

final class ResponseLimitTests: XCTestCase {

    private let limit = 1000

    func testUnderLimitByBothMeasuresIsAccepted() {
        XCTAssertFalse(ResponseLimit.exceeds(advertisedContentLength: 500, byteCount: 500, limit: limit))
    }

    func testByteCountOverLimitIsRejected() {
        XCTAssertTrue(ResponseLimit.exceeds(advertisedContentLength: -1, byteCount: limit + 1, limit: limit))
    }

    func testAdvertisedLengthOverLimitIsRejected() {
        // Advertised length over the cap is rejected even if byteCount is small.
        XCTAssertTrue(ResponseLimit.exceeds(advertisedContentLength: Int64(limit + 1), byteCount: 10, limit: limit))
    }

    func testUnknownAdvertisedLengthFallsBackToByteCount() {
        // -1 (NSURLResponseUnknownLength) is ignored; byteCount under limit → accepted.
        XCTAssertFalse(ResponseLimit.exceeds(advertisedContentLength: -1, byteCount: limit, limit: limit))
    }

    func testByteCountEqualToLimitIsAccepted() {
        // byteCount == limit with a positive advertisedLength also at limit: both boundaries accepted.
        XCTAssertFalse(ResponseLimit.exceeds(advertisedContentLength: Int64(limit), byteCount: limit, limit: limit))
    }

    func testAdvertisedLengthEqualToLimitIsAccepted() {
        XCTAssertFalse(ResponseLimit.exceeds(advertisedContentLength: Int64(limit), byteCount: 10, limit: limit))
    }

    func testRealCapsArePositive() {
        XCTAssertGreaterThan(ResponseLimit.health, 0)
        XCTAssertGreaterThan(ResponseLimit.sample, ResponseLimit.health)
    }
}
