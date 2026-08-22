import Foundation

/// BatCave, as far as this app is concerned.
///
/// The site publishes no index — no sitemap of issues, no API — so it works
/// the way StripZona and Comic Book Plus do: the reader browses, and Import
/// reads the page they are standing on. One difference from both, and it
/// shapes everything below: a Comic Book Plus leaf page lists a whole *run*
/// and a forum topic lists a whole *set*, while a BatCave detail page
/// describes exactly one issue. So an import here writes one row.
///
/// **Two gates sit in front of this site, and they decide the download
/// architecture.** Measured, not assumed:
///
///  * A request without a browser behind it is refused outright — a plain
///    `curl` with an iPad Safari User-Agent gets **HTTP 403** and Cloudflare's
///    "Just a moment…" challenge page.
///  * A real browser then meets the site's *own* interstitial at
///    `/_c?t=<token>&u=<target>`, which fingerprints the client, runs a
///    proof-of-work loop and only then redirects to the page that was asked
///    for.
///
/// A `WKWebView` with a reader in front of it passes both, the way any browser
/// does. `URLSession` does not, and no User-Agent string changes that — which
/// is why page images cannot simply be handed to `URLSessionDownloader` the
/// way every other source's archive is. The fetch has to carry the session the
/// reader's own browsing established, which is what `SiteCookies` already
/// exists for; `ComicBookPlusHost` uses it for the same reason, one gate
/// weaker.
public enum BatCave {

    /// The domain, matched by `HostFence` on a leading dot so any subdomain
    /// serving covers or page images is admitted by the same entry.
    public static let host = "batcave.biz"

    public static let base = "https://\(host)/"

    /// Where the browser opens: the site root.
    ///
    /// Unlike Comic Book Plus — whose root is a news page and whose catalogue
    /// is one level in, so the browser is pointed at the index instead — this
    /// site's root *is* its front door, with search and the category menu on
    /// it. Here rather than in the view because an address is an address, and
    /// the app layer holding a second copy of one is how the two drift.
    public static let browseURL = base

    /// A detail page: `/4454-republic-of-the-skull.html`.
    ///
    /// Anchored at both ends. Unanchored, this matches the leading digits of
    /// anything — and the site's category and search paths carry numbers too,
    /// so a loose pattern would light Import up on a page listing forty
    /// issues, none of which is the one that would be imported.
    ///
    /// The slug is not read. It is the title in kebab-case and the page
    /// states the title properly; deriving one from the other would be
    /// guessing at a string the page hands over.
    private static let detailPath = Rx(#"^/(\d+)-[^/]*\.html$"#, [.caseInsensitive])

    /// The site's own id for an issue, from its address, or nil if this is not
    /// an issue page.
    ///
    /// The whole of an issue's identity here, and what `code` is written from:
    /// the slug changes if the site retitles something, and the number does
    /// not.
    public static func issueID(from url: URL) -> Int? {
        guard let host = url.host?.lowercased(),
              host == Self.host || host.hasSuffix("." + Self.host),
              let groups = detailPath.firstGroups(url.path)
        else { return nil }
        return Int(groups[1])
    }

    /// Whether an address is one issue's page — the cheap half of deciding
    /// whether Import is lit.
    ///
    /// Cheap on purpose: it is asked on every navigation. It is only half the
    /// answer because an address can look right while the page behind it is
    /// the site's 404, so the parser confirms against the markup — the same
    /// division `ComicBookPlusBrowserView` makes, and for the same reason.
    public static func isIssuePage(_ url: URL) -> Bool { issueID(from: url) != nil }

    /// Where one issue describes itself, rebuilt from its id.
    ///
    /// Recorded as the issue's mirror. Stable, carries no token, and is the
    /// page a download has to read anyway to find the reader — the same rule
    /// `ComicBookPlus.bookURL` follows and for the same reason.
    ///
    /// The slug is included when it is known because the site is friendlier
    /// about it than it needs to be, but it is not required to be correct:
    /// the id is what resolves.
    public static func issueURL(id: Int, slug: String? = nil) -> String {
        guard let slug, !slug.isEmpty else { return "\(base)\(id)-.html" }
        return "\(base)\(id)-\(slug).html"
    }

    /// Where one chapter is read: `/reader/<series>/<chapter>`.
    ///
    /// This is the address recorded as an issue's mirror, and it is the page a
    /// download has to open — the site serves no archive, so the only route to
    /// the scans is the reader that displays them.
    ///
    /// Both halves are required. The chapter id is unique on its own, but the
    /// site addresses it under its series and there is no form that omits one.
    public static func readerURL(series: Int, chapter: Int) -> String {
        "\(base)reader/\(series)/\(chapter)"
    }
}
