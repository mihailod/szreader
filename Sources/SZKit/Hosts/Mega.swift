import Foundation

/// Mega — 244 of 1004 links in the corpus, so not a corner case.
///
/// Unlike every other host, the decryption key lives in the URL *fragment* and
/// never reaches the server, so a plain GET cannot work: the file id must be
/// exchanged for a temp URL through Mega's API, and the bytes decrypted client
/// side.
///
/// The key derivation and attribute decryption here were verified against six
/// live links whose filenames were independently known from the forum post
/// text; all six decrypted correctly.
public struct MegaHost: FileHost {

    public let name = "mega"
    public init() {}

    private static let modern = Rx(#"mega(?:\.co)?\.nz/file/([^#?/]+)#([\w\-]+)"#)
    private static let legacy = Rx(#"mega(?:\.co)?\.nz/#!([^!]+)!([\w\-]+)"#)
    private static let apiBase = "https://g.api.mega.co.nz/cs"

    public func canHandle(_ url: URL) -> Bool {
        let h = (url.host ?? "").lowercased()
        return h.hasSuffix("mega.nz") || h.hasSuffix("mega.co.nz")
    }

    struct Link { let id: String; let fragment: String }

    /// Both the current `/file/<id>#<key>` and the legacy `#!<id>!<key>` forms
    /// appear in the corpus — the older posts predate the URL change.
    static func parse(_ url: URL) -> Link? {
        let s = url.absoluteString
        if let g = modern.firstGroups(s) { return Link(id: g[1], fragment: g[2]) }
        if let g = legacy.firstGroups(s) { return Link(id: g[1], fragment: g[2]) }
        return nil
    }

    /// A file key is 32 bytes = 8 big-endian words. The AES key is the first
    /// half XORed with the second; the nonce follows it.
    /// The storage node URL, forced to TLS.
    static func secureNode(_ raw: String) -> URL? {
        URL(string: raw.replacingOccurrences(of: "http://", with: "https://"))
    }

    static func derive(fragment: String) throws -> (key: Data, nonce: Data) {
        guard let raw = Base64URL.decode(fragment), raw.count >= 32 else {
            throw HostError.decryptionFailed("key too short (folder link?)")
        }
        let words: [UInt32] = (0..<8).map { i in
            raw.withUnsafeBytes { buf in
                let o = i * 4
                return (UInt32(buf[o]) << 24) | (UInt32(buf[o + 1]) << 16)
                     | (UInt32(buf[o + 2]) << 8) | UInt32(buf[o + 3])
            }
        }
        var key = Data(capacity: 16)
        for i in 0..<4 {
            var w = (words[i] ^ words[i + 4]).bigEndian
            withUnsafeBytes(of: &w) { key.append(contentsOf: $0) }
        }
        return (key, raw.subdata(in: 16..<24))
    }

    private func apiCall(_ command: [String: Any], via transport: Transport) async throws -> [String: Any] {
        let seq = Int.random(in: 0..<1_000_000_000)
        guard let url = URL(string: "\(Self.apiBase)?id=\(seq)") else {
            throw HostError.apiError("bad API URL")
        }
        let body = try JSONSerialization.data(withJSONObject: [command])
        let resp = try await transport.send(HTTPRequest(
            url: url, method: "POST", headers: ["Content-Type": "application/json"],
            body: body, maxBodyBytes: 64_000))
        guard resp.status == 200 else { throw HostError.apiError("HTTP \(resp.status)") }

        let parsed = try JSONSerialization.jsonObject(with: resp.body)
        // Errors come back as a bare int, or an array containing one.
        if let code = parsed as? Int { throw Self.mapError(code) }
        guard let array = parsed as? [Any], let first = array.first else {
            throw HostError.apiError("unexpected API response")
        }
        if let code = first as? Int { throw Self.mapError(code) }
        guard let dict = first as? [String: Any] else {
            throw HostError.apiError("unexpected API response")
        }
        return dict
    }

    private static func mapError(_ code: Int) -> HostError {
        switch code {
        case -9: return .notFound              // dead link
        case -3, -4: return .apiError("rate limited (\(code)) — back off")
        default: return .apiError("API error \(code)")
        }
    }

    /// Filename and size without downloading a byte. The `at` blob is
    /// AES-128-CBC over the derived key and starts with the literal "MEGA".
    public func probe(_ url: URL, via transport: Transport) async throws -> FileMeta {
        guard let link = Self.parse(url) else { throw HostError.unrecognisedURL(url.absoluteString) }
        let (key, _) = try Self.derive(fragment: link.fragment)
        let result = try await apiCall(["a": "g", "p": link.id], via: transport)
        let size = result["s"] as? Int
        guard let at = result["at"] as? String else { return FileMeta(filename: nil, size: size) }
        return FileMeta(filename: try Self.filename(fromAttributes: at, key: key), size: size)
    }

    static func filename(fromAttributes at: String, key: Data) throws -> String? {
        guard let blob = Base64URL.decode(at),
              let plain = AES.decryptCBCNoPadding(blob, key: key) else {
            throw HostError.decryptionFailed("could not decrypt attributes")
        }
        guard plain.prefix(4) == Data("MEGA".utf8) else {
            // Garbage here means the key derivation is wrong, not the link.
            throw HostError.decryptionFailed("attribute blob did not start with MEGA")
        }
        let json = plain.dropFirst(4).prefix { $0 != 0 }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any]
        else { throw HostError.decryptionFailed("attribute JSON malformed") }
        return obj["n"] as? String
    }

    /// The temp URL serves *encrypted* bytes. That is deliberate: a plain
    /// background URLSession can fetch them while the app is suspended, and
    /// the AES-CTR pass runs on completion.
    public func directLink(_ url: URL, via transport: Transport) async throws -> DirectLink {
        guard let link = Self.parse(url) else { throw HostError.unrecognisedURL(url.absoluteString) }
        let (key, nonce) = try Self.derive(fragment: link.fragment)
        let result = try await apiCall(["a": "g", "g": 1, "p": link.id], via: transport)
        guard let temp = result["g"] as? String else {
            throw HostError.apiError("no temp URL in response")
        }
        // The API hands back an http:// storage node, which App Transport
        // Security refuses outright (NSURLErrorDomain -1022) — the request
        // never leaves the device. The nodes serve the same bytes over TLS, so
        // upgrade rather than widening the ATS exceptions for a hostname that
        // changes per download anyway.
        guard let u = Self.secureNode(temp) else {
            throw HostError.apiError("unusable temp URL in response")
        }
        return DirectLink(url: u, postProcess: .aesCTR(key: key, nonce: nonce))
    }
}
