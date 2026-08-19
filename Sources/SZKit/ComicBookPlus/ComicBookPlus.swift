import Foundation

/// Comic Book Plus, as far as this app is concerned.
///
/// The site is a public-domain archive of Golden Age comics, pulps and story
/// papers. Two of its pages matter here and they divide the work cleanly:
///
///  * A **leaf page**, `?cid=<id>`, lists every scan of one series. It is
///    public — no account, no session — and every row on it carries the
///    metadata *and* the file hash the download is keyed on. That page is what
///    `ComicBookPlusPage` reads, and one read of it yields the whole run.
///  * A **book page**, `?dlid=<id>`, describes one scan. It is where the
///    filename and format live, and it is what a `FileHost.probe` would ask.
///
/// Nothing here talks to the network and nothing here holds a session. The
/// download address needs a session token, and the rule about it is in
/// `downloadURL` below.
public enum ComicBookPlus {

    /// The domain, matched by `HostFence` on a leading dot so the `box01`
    /// subdomain that serves thumbnails and files is admitted by the same
    /// entry.
    public static let host = "comicbookplus.com"

    public static let base = "https://comicbookplus.com/"

    /// Where one scan describes itself.
    ///
    /// This is the form to record as an issue's mirror, and deliberately not
    /// the download address: it is stable, it carries no session token, and it
    /// is the page a resolver would have to read anyway to learn the filename.
    public static func bookURL(dlid: Int) -> String { "\(base)?dlid=\(dlid)" }

    /// Where a series lists its scans.
    public static func seriesURL(cid: Int) -> String { "\(base)?cid=\(cid)" }

    /// Where the browser opens.
    ///
    /// The comic-book index rather than the site root: the root is a front
    /// page of news and featured scans whose only route into the catalogue is
    /// the menu, and this is one tap from every publisher and every genre.
    ///
    /// Here rather than in the view for the same reason `ArchiveOrg.searchURL`
    /// is — an address is an address, and the app layer holding a second copy
    /// of one is how the two drift.
    public static let indexURL = seriesURL(cid: 1507)

    /// The cover thumbnail for one scan.
    ///
    /// Three things here were each got wrong first and corrected against the
    /// live site:
    ///
    ///  * **The shard.** The first two characters of the hash are a directory
    ///    — the site fans 50,000 books across 256 of them — so the hash
    ///    appears twice in the path. Without it every URL 404s.
    ///  * **The host.** Images are on `box01`, not the bare domain, which
    ///    answers this path with its 404 page.
    ///  * **`largethumb`, not the `thumbnailUrl` the page states.** The
    ///    listing's own microdata gives a `mediumthumb` URL with no shard in
    ///    it, and that URL is dead — the site is describing a layout it no
    ///    longer serves. Built from the hash rather than read off the page for
    ///    exactly that reason.
    ///
    /// `largethumb` is 200x299 and `mediumthumb` half that. Neither reaches
    /// the 600px `CoverStore` draws at, but the larger is what the site has,
    /// and it is a cover rather than a grey rectangle with a number on it.
    ///
    /// Needs a browser User-Agent — a request without one gets 403 — which is
    /// what `CoverStore` already sends on every cover. No Referer: that is
    /// required for the page images, not for these.
    public static func thumbnailURL(hash: String) -> String {
        "https://box01.comicbookplus.com/viewer/\(shard(of: hash))/\(hash)/largethumb.jpg"
    }

    /// The directory a hash lives under: its first two characters, or the
    /// whole thing if it is somehow shorter.
    static func shard(of hash: String) -> String {
        hash.count >= 2 ? String(hash.prefix(2)) : hash
    }

    /// Where a scan is actually fetched from.
    ///
    /// **Unverified.** The shape is read off one real download link and has
    /// not been exercised, because doing so needs a live session token and one
    /// should not be pasted into a repository or a transcript. Two of the four
    /// parameters are also still open questions:
    ///
    ///  * `f` is the file hash, and the leaf page hands it over for every row.
    ///  * `t` is the format — "cbr" on one book, "cbz" on another — and `n` is
    ///    the stored filename without its extension. Neither appears anywhere
    ///    on a leaf page, so both have to come from the book page. Whether
    ///    they are load-bearing or merely decide the name the file arrives
    ///    under is not known.
    ///  * `session` is the site's `PHPSESSID`, passed in the query string.
    ///
    /// That last one is why this is a function taking a session rather than a
    /// stored string: `PHPSESSID` is a session cookie, so it is replaced
    /// whenever the browser's session rolls over — the login survives on
    /// `SMFCookie350` and the reader never notices, but a download address
    /// captured yesterday is dead. It must be built immediately before use and
    /// **never written to the database**, which is exactly the split
    /// `FileHost.probe` and `FileHost.directLink` already exist for.
    public static func downloadURL(hash: String, format: String,
                                   name: String, session: String) -> String {
        var components = URLComponents(string: "https://box01.comicbookplus.com/dload/")!
        components.queryItems = [
            URLQueryItem(name: "f", value: hash),
            URLQueryItem(name: "t", value: format),
            URLQueryItem(name: "n", value: name),
            URLQueryItem(name: "sess", value: session),
        ]
        return components.url?.absoluteString ?? ""
    }
}
