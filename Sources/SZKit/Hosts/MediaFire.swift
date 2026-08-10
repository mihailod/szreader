import Foundation

/// MediaFire — the dominant host in the corpus (645 of 1004 links).
///
/// Five URL shapes appear across a decade of posts, all keyed by the same file
/// id. Surveying the corpus is what turned up the last three:
///
///     /?<key>                        oldest, key is the whole query
///     /download.php?<key>
///     /download/<key>
///     /view/<key>/<filename>         filename already embedded
///     /file/<key>/<filename>/file    current canonical form
public struct MediaFireHost: FileHost {

    public let name = "mediafire"
    public init() {}

    private static let keyFromPath = Rx(#"mediafire\.com/(?:download|view|file)/([A-Za-z0-9]{8,})"#)
    private static let keyFromQuery = Rx(#"mediafire\.com/(?:download\.php)?\?([A-Za-z0-9]{8,})"#)
    private static let directURL = Rx(#"https?://download[0-9]*\.mediafire\.com/[^"'\s<>]+"#)
    private static let titleTag = Rx(#"(?is)<title>\s*(.*?)\s*</title>"#)
    private static let archiveName = Rx(#"[^/]+\.(?:cbr|cbz|rar|zip|7z|pdf)$"#, [.caseInsensitive])

    public func canHandle(_ url: URL) -> Bool {
        (url.host ?? "").lowercased().contains("mediafire.com")
    }

    /// The file id, whichever shape the link takes.
    static func key(from url: URL) -> String? {
        let s = url.absoluteString
        if let g = keyFromPath.firstGroups(s) { return g[1] }
        if let g = keyFromQuery.firstGroups(s) { return g[1] }
        return nil
    }

    private func canonical(_ url: URL) throws -> URL {
        guard let key = Self.key(from: url),
              let u = URL(string: "https://www.mediafire.com/file/\(key)")
        else { throw HostError.unrecognisedURL(url.absoluteString) }
        return u
    }

    /// Normally a single request with no body: the redirect Location carries
    /// `/file/<key>/<filename>`, which is all a probe needs.
    public func probe(_ url: URL, via transport: Transport) async throws -> FileMeta {
        // /view/ and /file/ shapes already contain the filename.
        if let embedded = Self.filename(inPath: url.path) {
            return FileMeta(filename: embedded)
        }
        var current = try canonical(url)
        for _ in 0..<3 {
            let resp = try await transport.send(HTTPRequest(url: current))
            if (300..<400).contains(resp.status) {
                guard let loc = resp.location,
                      let next = URL(string: loc, relativeTo: current)?.absoluteURL
                else { throw HostError.apiError("redirect without Location") }
                if let name = Self.filename(inPath: next.path) { return FileMeta(filename: name) }
                current = next
                continue
            }
            if resp.status == 404 { throw HostError.notFound }
            guard resp.status == 200 else { throw HostError.apiError("HTTP \(resp.status)") }

            // No filename in the path: the <title> is the filename minus its
            // extension. Read only the head of the document, not 300 KB.
            let body = try await transport.send(
                HTTPRequest(url: current, maxBodyBytes: 65_536))
            if let g = Self.titleTag.firstGroups(body.text), !g[1].isEmpty,
               !g[1].lowercased().contains("mediafire") {
                return FileMeta(filename: g[1])
            }
            return FileMeta(filename: nil)
        }
        throw HostError.apiError("too many redirects")
    }

    /// The signed `download###.mediafire.com` URL sits in the static HTML — no
    /// JavaScript, no captcha. It is time-limited, so resolve it immediately
    /// before downloading rather than caching it.
    public func directLink(_ url: URL, via transport: Transport) async throws -> DirectLink {
        let page = try canonical(url)
        let resp = try await transport.send(HTTPRequest(url: page, maxBodyBytes: 512_000))
        let html = resp.text.isEmpty && (300..<400).contains(resp.status)
            ? try await follow(page, resp, via: transport)
            : resp.text
        guard let direct = Self.directURL.allMatches(html).first,
              let u = URL(string: direct) else {
            throw HostError.apiError("no direct link in page (dead or changed layout)")
        }
        return DirectLink(url: u)
    }

    private func follow(_ from: URL, _ resp: HTTPResponse,
                        via transport: Transport) async throws -> String {
        guard let loc = resp.location, let next = URL(string: loc, relativeTo: from)?.absoluteURL
        else { throw HostError.apiError("redirect without Location") }
        return try await transport.send(HTTPRequest(url: next, maxBodyBytes: 512_000)).text
    }

    static func filename(inPath path: String) -> String? {
        for segment in path.split(separator: "/").reversed() {
            // MediaFire encodes spaces as '+' in the path. Undo that BEFORE
            // percent-decoding, so a genuine %2B survives as a literal plus.
            let plussed = String(segment).replacingOccurrences(of: "+", with: " ")
            let s = plussed.removingPercentEncoding ?? plussed
            if archiveName.matches(s) { return s }
        }
        return nil
    }
}
