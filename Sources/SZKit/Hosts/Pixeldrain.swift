import Foundation

/// Pixeldrain — 15 links in the corpus, all from recent FIBRA posts.
///
/// UNVERIFIED against the live service. The endpoints below are implemented
/// from Pixeldrain's documented public API but, unlike MediaFire (54/54) and
/// Mega (6/6), no probe has actually been run against it. Treat a failure here
/// as "check the API shape" before assuming the link is dead.
public struct PixeldrainHost: FileHost {

    public let name = "pixeldrain"
    public init() {}

    private static let idPattern = Rx(#"pixeldrain\.com/(?:u|l|api/file)/([A-Za-z0-9]+)"#)

    public func canHandle(_ url: URL) -> Bool {
        (url.host ?? "").lowercased().contains("pixeldrain.com")
    }

    static func id(from url: URL) -> String? {
        idPattern.firstGroups(url.absoluteString).map { $0[1] }
    }

    public func probe(_ url: URL, via transport: Transport) async throws -> FileMeta {
        guard let id = Self.id(from: url),
              let info = URL(string: "https://pixeldrain.com/api/file/\(id)/info")
        else { throw HostError.unrecognisedURL(url.absoluteString) }

        let resp = try await transport.send(HTTPRequest(url: info, maxBodyBytes: 32_000))
        if resp.status == 404 { throw HostError.notFound }
        guard resp.status == 200 else { throw HostError.apiError("HTTP \(resp.status)") }
        guard let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        else { throw HostError.apiError("info endpoint returned non-JSON") }
        return FileMeta(filename: obj["name"] as? String, size: obj["size"] as? Int)
    }

    public func directLink(_ url: URL, via transport: Transport) async throws -> DirectLink {
        guard let id = Self.id(from: url),
              let u = URL(string: "https://pixeldrain.com/api/file/\(id)")
        else { throw HostError.unrecognisedURL(url.absoluteString) }
        return DirectLink(url: u)
    }
}
