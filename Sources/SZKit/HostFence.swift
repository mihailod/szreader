import Foundation

/// Where a browser inside this app is allowed to go.
///
/// The app embeds a web view for two reasons — reading a forum topic you have
/// unlocked, and finding an item on archive.org — and neither of them is "a web
/// browser". An embedded view that follows any link a page happens to carry is
/// one: a forum post links out to file hosts, image hosts and wherever else, and
/// an archive.org item page links to whatever its uploader typed into the
/// description.
///
/// So each browser is fenced to the site it exists for. There is no address bar
/// to type into — the URL is shown, never edited — and this closes the other way
/// out.
///
/// In SZKit rather than beside the web view it guards, because this is the one
/// piece of that screen with a right and a wrong answer, and the difference
/// between them is a host string. `admits` is the whole fence; everything in
/// the app layer is the WebKit plumbing that calls it.
public struct HostFence: Sendable, Equatable {

    /// The domains admitted, each covering its own subdomains.
    public let hosts: Set<String>
    /// What the fence is called in the one sentence shown when it turns
    /// something away.
    public let name: String

    public init(hosts: Set<String>, name: String) {
        self.hosts = Set(hosts.map { $0.lowercased() })
        self.name = name
    }

    /// The forum, and nothing else.
    public static let stripzona = HostFence(hosts: ["stripzona.com"], name: "StripZona")

    /// archive.org and everything under it: the search page and item pages sit
    /// on the bare domain, the Wayback Machine on `web.archive.org`, and a
    /// download redirects to whichever item server holds the file today —
    /// `ia601403.us.archive.org` this week, something else next year.
    public static let archive = HostFence(hosts: [ArchiveOrg.host], name: "archive.org")

    /// Comic Book Plus, which needs the bare domain and gets its subdomains
    /// from the same entry: the site itself is on `comicbookplus.com`, and
    /// every thumbnail, page image and file comes off `box01.comicbookplus.com`.
    /// `admits` matches a leading dot, so one host covers both.
    ///
    /// The forum is inside the fence too, and has to be — signing in happens
    /// at `/forum/?action=login`, and it is the same site.
    public static let comicBookPlus =
        HostFence(hosts: [ComicBookPlus.host], name: IssueSite.comicbookplus.display)

    /// Whether this browser may follow a link.
    ///
    /// Three separate refusals, and each of them has to be here:
    ///
    ///  * **Scheme.** Only http and https. Without this, `mailto:`, `tel:` and
    ///    `itms-apps:` links leave the app entirely — which is a way out of the
    ///    fence that never touches a host name.
    ///  * **Host.** The domain itself or something under it, matched on a
    ///    leading dot so that `notarchive.org` and `archive.org.example.com`
    ///    are refused. A plain `contains` or `hasSuffix` on the bare name
    ///    admits both, and both are trivially registrable.
    ///  * **Case.** Host names are case-insensitive and a link may be written
    ///    in any of them.
    ///
    /// `about:` is admitted because WebKit loads `about:blank` itself, between
    /// pages and on its own account, and refusing it fences the browser off
    /// from its own machinery.
    public func admits(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return true }
        guard scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
