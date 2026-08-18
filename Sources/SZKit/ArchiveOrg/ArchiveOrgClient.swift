import Foundation

/// Asks archive.org what an item holds.
///
/// The one request the app makes while browsing, and it is made against the
/// metadata API rather than against the page the reader is looking at. The
/// details page is a JavaScript application built out of web components; the
/// same facts are served as JSON at a fixed address, exactly, and this app
/// already had a decoder for that JSON before it had a browser.
///
/// Deliberately not on the throttled transport the downloads use. That one
/// spaces requests 1.5 seconds apart because it talks to third-party file
/// hosts that rate-limit and ban; this is archive.org's own public API being
/// asked one small question per page the reader opens, and a second and a half
/// of latency on every tap is paid by the person browsing for no benefit to
/// anyone.
public struct ArchiveOrgClient: Sendable {

    private let transport: Transport

    /// How large a metadata document may be.
    ///
    /// Comfortably more than any item worth reading: the largest of the Zagor
    /// items is 4 KB of metadata and 17 files. An item with tens of thousands
    /// of files would exceed it, decode to nothing and be reported as
    /// unreadable — which is the right answer for something that is not a
    /// comic or a magazine anyway.
    static let maxBytes = 8 << 20

    /// How many times a 5xx is forgiven.
    ///
    /// The same allowance `archive-build` makes, for the same observed reason:
    /// the archive answers a small fraction of requests with a 500 and the
    /// identical URL succeeds a moment later. Only 5xx — a 404 is an answer.
    static let attempts = 3
    static let pause: UInt64 = 1_000_000_000

    public init(transport: Transport) {
        self.transport = transport
    }

    /// One item, or nil when the archive has no such identifier.
    ///
    /// The nil is real and has to be distinguished from an error: a missing
    /// item is answered with `{}` and HTTP 200, so "no metadata object" is the
    /// only way to be told.
    public func item(_ identifier: String) async throws -> ArchiveOrgItem? {
        guard let url = URL(string: ArchiveOrg.metadataURL(item: identifier)) else {
            throw TransportError.unsupportedURL(identifier)
        }
        let request = HTTPRequest(url: url, maxBodyBytes: Self.maxBytes)

        var last = TransportError.badStatus(500)
        for round in 1...Self.attempts {
            if round > 1 { try await Task.sleep(nanoseconds: Self.pause) }
            let response = try await transport.send(request)
            // A decode failure is thrown rather than retried: the same bytes
            // will fail the same way.
            if response.status == 200 { return try ArchiveOrgItem.decode(response.body) }
            // A 4xx is the archive's final word; only a 5xx is worth asking
            // again.
            guard (500...599).contains(response.status) else {
                throw TransportError.badStatus(response.status)
            }
            last = .badStatus(response.status)
        }
        throw last
    }
}
