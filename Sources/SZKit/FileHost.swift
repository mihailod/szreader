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

    public init(url: URL, headers: [String: String] = [:], postProcess: PostProcess? = nil) {
        self.url = url; self.headers = headers; self.postProcess = postProcess
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
                                     DirectHost()]) {
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
