import Foundation

/// A plain file on a web server.
///
/// The other three hosts exist because a MediaFire or Mega link is not a file
/// — it is a page, or an API, that has to be talked into yielding a signed URL
/// that expires in minutes. The shipped catalogues have none of that: they
/// record `https://retrospec.elite.org/pcsux/SKH/ZIP/1984_10.zip` and
/// `https://archive.org/download/amiga-bilten-1/Amiga%20Bilten%201.pdf`, and
/// those *are* the files. So this host resolves nothing and asks nothing.
///
/// archive.org answers with a redirect to whichever of its servers holds the
/// item — `dn721609.ca.archive.org` today, something else next year. Nothing
/// here has to know that: the redirect is followed by URLSession inside the
/// download, and it is exactly why the catalogue records the `/download/`
/// address rather than the node the metadata happens to name.
///
/// Scoped to named hosts rather than claiming every URL nobody else wants.
/// As a catch-all it would swallow the unrecognised links on a forum page —
/// which today fail loudly as `noHostFor`, naming the host so it can be
/// added — and turn them into downloads of whatever HTML the server returns,
/// diagnosed several steps later as "magic bytes match neither zip nor rar".
public struct DirectHost: FileHost {

    public let name = "direct"

    /// Hosts whose files may be fetched by URL alone.
    public let hosts: Set<String>

    /// Defaults to the archives the shipped catalogues point at. Taken as a
    /// parameter so a test can stand up its own server, and so an archive
    /// moving is a one-line change rather than a new host implementation.
    ///
    /// Every one of these is a plain file server, which is the whole point of
    /// this host: nothing to resolve, nothing signed, nothing that expires.
    /// A catalogue whose host is missing from this list is not a broken
    /// download — it is `noHostFor` on every single issue in it, which is how
    /// the bombjack catalogue shipped the first time.
    public init(hosts: Set<String> = ["retrospec.elite.org", "archive.org",
                                     "commodore.bombjack.org", "arcarc.xmission.com",
                                     "www.atarimania.com"]) {
        self.hosts = Set(hosts.map { $0.lowercased() })
    }

    public func canHandle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// The filename, without asking anyone.
    ///
    /// It is the last path component, which for a static file server is the
    /// name the file will arrive under anyway. Spending a HEAD to be told
    /// what the URL already says is the kind of extra request the comment on
    /// `FileDownloader.download` warns about — and the size the caller might
    /// want from it is already in the database, recorded when the catalogue
    /// was built.
    public func probe(_ url: URL, via transport: Transport) async throws -> FileMeta {
        guard canHandle(url) else { throw HostError.unrecognisedURL(url.absoluteString) }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { return FileMeta(filename: nil) }
        return FileMeta(filename: name.removingPercentEncoding ?? name)
    }

    /// The URL, unchanged.
    ///
    /// Nothing is signed and nothing expires, so unlike the other three this
    /// answer stays true — which is exactly why there is no work to do here.
    public func directLink(_ url: URL, via transport: Transport) async throws -> DirectLink {
        guard canHandle(url) else { throw HostError.unrecognisedURL(url.absoluteString) }
        return DirectLink(url: url)
    }
}
