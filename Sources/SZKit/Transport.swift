import Foundation

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String = "GET"
    public var headers: [String: String] = [:]
    public var body: Data?
    /// 0 means "don't read the body at all" — a probe usually only needs the
    /// Location header, which is a few hundred bytes rather than 90 MB.
    public var maxBodyBytes: Int = 0

    public init(url: URL, method: String = "GET", headers: [String: String] = [:],
                body: Data? = nil, maxBodyBytes: Int = 0) {
        self.url = url; self.method = method; self.headers = headers
        self.body = body; self.maxBodyBytes = maxBodyBytes
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        // Header names are case-insensitive; normalise so lookups can't miss.
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) },
                                  uniquingKeysWith: { _, b in b })
        self.body = body
    }

    public var location: String? { headers["location"] }
    public var text: String { String(data: body, encoding: .utf8) ?? "" }
}

public enum TransportError: Error, CustomStringConvertible {
    case badStatus(Int)
    case notHTTP
    case unsupportedURL(String)
    case hostRefused(String)

    public var description: String {
        switch self {
        case .badStatus(let c): return "HTTP \(c)"
        case .notHTTP: return "not an HTTP response"
        case .unsupportedURL(let u): return "unsupported URL: \(u)"
        case .hostRefused(let m): return m
        }
    }
}

/// Injectable HTTP so every host can be tested without touching the network.
public protocol Transport: Sendable {
    /// Redirects must NOT be followed — MediaFire's filename arrives in the
    /// `Location` header, and following it would download the file.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public final class URLSessionTransport: NSObject, Transport, URLSessionTaskDelegate {

    private let userAgent: String

    /// Built without a delegate so it can be a constant.
    ///
    /// It used to be `lazy`, because a session-wide delegate has to be `self`
    /// and `self` does not exist yet during `init`. A mutable stored property
    /// on a `Sendable` class is a data race waiting to happen, though, and an
    /// error under the Swift 6 language mode — so the delegate is supplied per
    /// task instead, which suppresses redirects just the same.
    private let session = URLSession(configuration: .ephemeral)

    public init(userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15") {
        self.userAgent = userAgent
    }

    /// Never follow redirects; the caller decides what a 3xx means.
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? { nil }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        // A download host serves the file itself; a probe must never hit it.
        if request.url.host?.lowercased().hasPrefix("download") == true, request.maxBodyBytes == 0 {
            throw TransportError.hostRefused("refusing to fetch file host \(request.url.host!)")
        }
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method
        req.httpBody = request.body
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9,hr;q=0.8", forHTTPHeaderField: "Accept-Language")
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }

        // Per-task delegate: this is what stops redirects being followed.
        let (data, response) = try await session.data(for: req, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw TransportError.notHTTP }
        let headers = Dictionary(
            http.allHeaderFields.compactMap { k, v -> (String, String)? in
                guard let k = k as? String, let v = v as? String else { return nil }
                return (k, v)
            }, uniquingKeysWith: { _, b in b })
        let body = request.maxBodyBytes > 0 ? data.prefix(request.maxBodyBytes) : Data()
        return HTTPResponse(status: http.statusCode, headers: headers, body: Data(body))
    }
}

/// Serialises requests and spaces them out.
///
/// Not politeness theatre: these are third-party file hosts that rate-limit,
/// and a burst of parallel probes is what gets an IP throttled.
public actor ThrottledTransport: Transport {
    private let inner: Transport
    private let minInterval: TimeInterval
    private var lastSend: Date = .distantPast

    public init(_ inner: Transport, minInterval: TimeInterval = 2.0) {
        self.inner = inner; self.minInterval = minInterval
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let wait = minInterval - Date().timeIntervalSince(lastSend)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastSend = Date()
        return try await inner.send(request)
    }
}
