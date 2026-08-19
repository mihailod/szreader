import Foundation

/// What a probe learns without downloading anything.
public struct FileMeta: Equatable, Sendable {
    public let filename: String?
    public let size: Int?

    public init(filename: String?, size: Int? = nil) {
        self.filename = filename; self.size = size
    }
}

/// Work that must happen to the bytes after they land.
public enum PostProcess: Equatable, Sendable {
    /// Mega ships the file AES-128-CTR encrypted. The bytes can be fetched by
    /// a plain background URLSession — which is what keeps downloads alive
    /// while the app is suspended — and decrypted afterwards.
    case aesCTR(key: Data, nonce: Data)
}

public struct DirectLink: Equatable, Sendable {
    public let url: URL
    public let headers: [String: String]
    public let postProcess: PostProcess?
    /// How large the file is, when the host knows and the server will not say.
    ///
    /// Most servers declare a length and this stays nil. Comic Book Plus does
    /// not: its download is a PHP script that streams the bytes without a
    /// `Content-Length`, so `expectedContentLength` comes back as -1 and there
    /// is no total to show a progress bar — or to check free space against.
    /// The book page states a size, so the host reads it there and passes it
    /// down here.
    ///
    /// A hint, not a measurement: the page rounds to two decimals of a
    /// megabyte, so it is out by up to a few hundred bytes. Fine for a bar and
    /// for a space check with 3x headroom; not something to verify a transfer
    /// against.
    public let expectedBytes: Int64?

    public init(url: URL, headers: [String: String] = [:],
                postProcess: PostProcess? = nil, expectedBytes: Int64? = nil) {
        self.url = url; self.headers = headers
        self.postProcess = postProcess; self.expectedBytes = expectedBytes
    }
}

/// One file host.
///
/// `probe` and `directLink` are split because their results have completely
/// different lifetimes: a filename is permanent and worth caching in the
/// database forever, while a direct URL is a signed, expiring token that must
/// be fetched immediately before the download starts.
public protocol FileHost: Sendable {
    var name: String { get }
    func canHandle(_ url: URL) -> Bool
    func probe(_ url: URL, via transport: Transport) async throws -> FileMeta
    func directLink(_ url: URL, via transport: Transport) async throws -> DirectLink
}

public enum HostError: Error, CustomStringConvertible {
    case unrecognisedURL(String)
    case noHostFor(String)
    case apiError(String)
    case decryptionFailed(String)
    case notFound

    public var description: String {
        switch self {
        case .unrecognisedURL(let u): return "unrecognised URL shape: \(u)"
        case .noHostFor(let u): return "no host implementation for \(u)"
        case .apiError(let m): return "host API error: \(m)"
        case .decryptionFailed(let m): return "decryption failed: \(m)"
        case .notFound: return "file not found (dead link)"
        }
    }
}

/// Routes a URL to whichever host claims it.
public struct HostRegistry: Sendable {
    public let hosts: [FileHost]

    /// `DirectHost` sits last, though the order does not actually matter:
    /// it claims only the archive the shipped catalogue points at, and the
    /// other three claim only their own domains, so no URL is contested.
    /// Last is where a fallback belongs regardless, in case it is ever
    /// widened.
    public init(hosts: [FileHost] = [MediaFireHost(), MegaHost(), PixeldrainHost(),
                                     ComicBookPlusHost(), DirectHost()]) {
        self.hosts = hosts
    }

    public func host(for url: URL) -> FileHost? {
        hosts.first { $0.canHandle(url) }
    }

    public func probe(_ url: URL, via transport: Transport) async throws -> FileMeta {
        guard let h = host(for: url) else { throw HostError.noHostFor(url.absoluteString) }
        return try await h.probe(url, via: transport)
    }

    public func directLink(_ url: URL, via transport: Transport) async throws -> DirectLink {
        guard let h = host(for: url) else { throw HostError.noHostFor(url.absoluteString) }
        return try await h.directLink(url, via: transport)
    }
}
