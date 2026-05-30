import Foundation

/// Byte-size caps for accepted localhost responses, plus a pure predicate that
/// callers apply before decoding/playing a fetched body. Defense-in-depth for a
/// localhost-only threat model (security review 2026-05-29, finding #4).
enum ResponseLimit {
    /// Cap for the /health JSON body. Real payloads are tens of KB.
    static let health = 5 * 1024 * 1024      // 5 MiB

    /// Cap for a /synthesize WAV sample. Fixed-phrase samples are ~30–100 KB.
    static let sample = 25 * 1024 * 1024     // 25 MiB

    /// True when the response should be rejected as too large.
    ///
    /// `byteCount` is the real enforcement point — the body has already been
    /// buffered by the time callers have it, so the received count is
    /// authoritative. `advertisedContentLength` is an advisory fast-path: it
    /// short-circuits a server that honestly advertises an oversized body
    /// (present only when >= 0; a negative value means chunked/unknown and is
    /// ignored). Equality (count == limit) is accepted, not rejected.
    static func exceeds(advertisedContentLength: Int64, byteCount: Int, limit: Int) -> Bool {
        if advertisedContentLength >= 0 && advertisedContentLength > Int64(limit) { return true }
        return byteCount > limit
    }
}
