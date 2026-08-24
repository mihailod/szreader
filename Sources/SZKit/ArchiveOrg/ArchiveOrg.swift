import Foundation

/// The Internet Archive, as far as this app is concerned.
///
/// Nothing here is a parser. Unlike RetroSpec — a set of generated HTML pages
/// that have to be read to find out what exists — archive.org publishes each
/// item as JSON at a fixed address, and every file that item holds is at a URL
/// derivable from the item's identifier. So this is the small set of address
/// rules, and `ArchiveOrgItem` is the JSON.
///
/// The app never asks archive.org anything at runtime: the catalogue is built
/// by `archive-build` and shipped. These rules exist so the builder and the
/// tests agree on what a URL looks like.
public enum ArchiveOrg {

    /// Prefix every path in the shipped catalogue hangs off.
    ///
    /// `/download/` redirects to whichever of the archive's servers holds the
    /// item today, which is exactly why it is the form recorded: the node
    /// names in the metadata ("ia803104.us.archive.org") are true this week
    /// and would be baked into the app for years.
    public static let base = "https://archive.org/download/"

    /// Where an item's own file lives, relative to `base`.
    ///
    /// Percent-encoded, because the scans are named as their uploader typed
    /// them — "Amiga Bilten 1.pdf" — and a space in a URL is not a URL.
    public static func path(item: String, file: String) -> String {
        "\(encode(item))/\(encode(file))"
    }

    /// The first page of an item, at print size.
    ///
    /// This is the cover, and asking for it this way is what saves shipping
    /// one: `/page/n0_w1024.jpg` is the archive's own BookReader endpoint, so
    /// the image is served from the item rather than copied into the app.
    /// It answers with the derivative nearest the requested width, which for
    /// these fanzines is the full-size scan at around 1200x1750 — the same
    /// order as RetroSpec's covers, which is what `CoverStore` is sized for.
    public static func firstPagePath(item: String) -> String {
        "\(encode(item))/page/n0_w1024.jpg"
    }

    /// The first page of one *file* inside an item, at print size.
    ///
    /// The same BookReader endpoint, told which of the item's books it is
    /// being asked about: `/download/<id>/<file>/page/n0_w1024.jpg`. Measured
    /// against `retro-gamer-magazine-archive`, where the item's own address
    /// answers with January 2004's cover no matter which of the 393 issues is
    /// meant, and this one answers with each issue's own.
    ///
    /// Nil for a name that cannot be written in a URL this endpoint accepts.
    /// It matches the name almost literally — `%20` is the one escape it
    /// decodes — so `…Apr[ocr]` answers where `…Apr%5Bocr%5D` is a 404, and
    /// `URL(string:)` escapes brackets, accents and everything else outside
    /// `urlPathAllowed` before a request is ever made. There is no third
    /// spelling to try: those issues get no cover address, and the shelf shows
    /// the same placeholder as for an item the archive never scanned, until
    /// the download supplies the real first page.
    public static func firstPagePath(item: String, file: String) -> String? {
        guard file.unicodeScalars.allSatisfy(addressable.contains) else { return nil }
        return "\(encode(item))/\(encodePath(file))/page/n0_w1024.jpg"
    }

    /// What a filename may hold and still be asked for by name.
    ///
    /// Everything a URL path carries unescaped, plus the space — which is in
    /// no URL, is in half the filenames on archive.org, and is the one
    /// character this endpoint decodes.
    private static let addressable: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.insert(" ")
        return set
    }()

    /// The square item tile every item has, for a stand-in while the cover
    /// loads. About 180px, and never the whole cover.
    public static func thumbnailPath(item: String) -> String {
        "\(encode(item))/__ia_thumb.jpg"
    }

    /// Where the item's metadata is served, which is the builder's one source
    /// — and, since the reader gained a browser, the app's too.
    public static func metadataURL(item: String) -> String {
        "https://archive.org/metadata/\(encode(item))"
    }

    // MARK: - Browsing

    /// Where the in-app browser opens.
    ///
    /// The search page rather than the front page: nothing on the front page
    /// leads anywhere this app can use in fewer than two taps, and the reader
    /// is here to find one item.
    public static let searchURL = "https://archive.org/search"

    /// Hosts the archive.org browser may visit.
    ///
    /// The bare domain plus everything under it. `web.archive.org` is the
    /// Wayback Machine, and the item servers a download redirects to are
    /// `ia601403.us.archive.org` and the like — all of them subdomains, all of
    /// them the same archive, and none of them somewhere else.
    public static let host = "archive.org"

    /// The item an archive.org address is about, if it is about one.
    ///
    /// This is what tells a page the reader can import from — an item — apart
    /// from the ones they cannot: `/search`, a collection, a profile, the
    /// front page. Everything the archive serves about one item hangs off its
    /// identifier in the second path segment, whichever of the three verbs
    /// comes first, so reading it needs no request and no page.
    ///
    /// Deliberately blind to what the identifier names. `/details/comics` is
    /// shaped exactly like `/details/amiga-bilten-1` and is a collection of
    /// three hundred thousand items; nothing in the URL says so, and the
    /// metadata does. So this answers "there is an item id here", and whether
    /// it is anything worth importing is settled by asking the archive.
    public static func identifier(inURL url: URL) -> String? {
        segments(inURL: url)?.item
    }

    /// Which *file* of an item an address is about, when it names one.
    ///
    /// An item can hold a whole run — `transactor-for-the-amiga` is thirteen
    /// issues of a magazine, one PDF each — and the archive's reader says
    /// which of them you are looking at in the third path segment:
    /// `/details/transactor-for-the-amiga/Transactor_for_the_Amiga_Vol_01_01_1988_Apr[ocr]`.
    ///
    /// Everything after the identifier, joined back up, because an item's
    /// files are not always at its root: `retro-gamer-magazine-archive` files
    /// 393 issues in folders, and the address of one of them is
    /// `/details/retro-gamer-magazine-archive/Retro%20Gamer/2004/2004/01/`.
    /// Read as a single segment that is the magazine's name, matching no
    /// issue, and the reader was asked which of 393 they meant while looking
    /// straight at the answer.
    ///
    /// Returned as the address writes it, extension and all. The details page
    /// drops it and a link to the file itself keeps it; `issue(named:)` knows
    /// both are one issue.
    public static func fileStem(inURL url: URL) -> String? {
        segments(inURL: url)?.file
    }

    /// Words the archive's own reader puts where a filename would go.
    ///
    /// `/details/<id>/page/n0/mode/2up` is a place in the book, not a file in
    /// the item, and reading it as one would look for an issue called "page".
    private static let readerPathWords: Set<String> = [
        "page", "mode", "search", "theater", "fullscreen",
    ]

    /// The item, and the file within it, that an address names.
    static func segments(inURL url: URL) -> (item: String, file: String?)? {
        guard let host = url.host?.lowercased(),
              host == Self.host || host.hasSuffix("." + Self.host) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2,
              ["details", "download", "metadata", "stream"].contains(parts[0].lowercased())
        else { return nil }
        let identifier = parts[1].removingPercentEncoding ?? parts[1]
        // "@someone" is a member's profile, which sits at the same address
        // shape as an item and is not one.
        guard !identifier.isEmpty, !identifier.hasPrefix("@") else { return nil }

        // Up to the point where the archive's own reader takes over the
        // address: `…/<file>/page/n0/mode/2up` is a place in that file, and
        // the words after it are not folders.
        let named = parts.dropFirst(2)
            .prefix { !readerPathWords.contains($0.lowercased()) }
            .map { $0.removingPercentEncoding ?? $0 }
        let file = named.isEmpty ? nil : named.joined(separator: "/")
        return (identifier, file)
    }

    // MARK: - Scandata

    private static let leafCount = Rx(#"(?i)<leafCount>\s*(\d+)\s*</leafCount>"#)
    private static let pageElement = Rx(#"(?i)<page\b"#)

    /// How many pages a scan has, out of the scanner's own record of it.
    ///
    /// `<leafCount>` is the file's own answer and is what this takes. The
    /// `<page>` elements are counted as the fallback, because the count is
    /// stated once and the elements are the thing being counted — a file that
    /// disagreed with itself would be a scan half-recorded, and the pages are
    /// what actually exist.
    public static func pageCount(inScandata xml: String) -> Int? {
        if let stated = leafCount.firstGroups(xml).flatMap({ Int($0.capture(1)) }),
           stated > 0 {
            return stated
        }
        let counted = pageElement.allGroups(xml).count
        return counted > 0 ? counted : nil
    }

    /// Escapes a path inside an item, keeping its folders as folders.
    ///
    /// An item's files are not always at its root — the Retro Gamer archive
    /// files every issue under `Retro Gamer/<year>/…` — and those slashes are
    /// slashes in the address too, where the ones inside a single name are
    /// not. So the path is escaped a segment at a time.
    static func encodePath(_ path: String) -> String {
        path.split(separator: "/").map { encode(String($0)) }.joined(separator: "/")
    }

    /// Escapes one path segment.
    ///
    /// `urlPathAllowed` leaves "/" alone, which would let a filename split
    /// itself across segments, so it is removed from the allowed set.
    static func encode(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}
