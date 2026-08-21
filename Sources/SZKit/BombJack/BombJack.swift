import Foundation

/// One downloadable item on a bombjack page: a magazine issue, or a book.
public struct BombJackEntry: Equatable, Sendable {
    /// What the cell calls it. For a magazine, "Issue 01 1984 Jan"; for a
    /// book, its title over as many lines as the cell used.
    public let title: String
    /// The archive itself, absolute.
    public let file: String
    /// Cover thumbnail, absolute. The site puts one inside every link.
    public let cover: String?
    /// Scanned pages, when the cell says.
    public let pages: Int?

    public init(title: String, file: String, cover: String?, pages: Int?) {
        self.title = title; self.file = file; self.cover = cover; self.pages = pages
    }
}

/// DLH's archive, as far as this app is concerned.
///
/// A static tree of hand-written HTML going back two decades, and the shape
/// never varies where it matters: every downloadable thing is a table cell
/// holding its name, a link to the archive, a cover image inside that link,
/// and a page count. Magazines and books differ only in what the name looks
/// like — "Issue 01 / 1984 Jan" against a book title over three lines — so one
/// reader handles both.
///
/// Nothing here runs in the app. The catalogue is built once by
/// `bombjack-build` and shipped, exactly as RetroSpec's is; these rules exist
/// so the builder and the tests agree on what a page says.
public enum BombJack {

    public static let host = "commodore.bombjack.org"

    /// Archives, by extension. The site serves zips of scans throughout, and
    /// PDFs where a contributor supplied one.
    static let archiveExtensions = ["zip", "pdf", "cbz", "cbr", "7z"]

    // MARK: - Entries

    /// A table cell holding a link to an archive.
    ///
    /// Anchored on the cell rather than the link because everything else the
    /// entry needs — the title above, the page count below — is in the cell
    /// and nowhere else. `[^<]` runs are matched loosely: these pages are
    /// twenty years of hand-edited FrontPage output, with fonts and spans
    /// nested three deep around every word.
    private static let cell = Rx(#"<td[^>]*>[\s\S]*?</td>"#, [.caseInsensitive])

    private static let anchor = Rx(
        #"<a[^>]+href\s*=\s*["']?([^"'\s>]+\.(?:zip|pdf|cbz|cbr|7z))["']?[^>]*>([\s\S]*?)</a>"#,
        [.caseInsensitive])

    private static let img = Rx(#"<img[^>]+src\s*=\s*["']?([^"'\s>]+)["']?"#, [.caseInsensitive])
    private static let pageCount = Rx(#"(\d+)\s*pages?"#, [.caseInsensitive])

    /// Everything downloadable on one page.
    ///
    /// `pageURL` is needed because almost every path here is relative, and
    /// relative to the page rather than to the site root — the covers on
    /// `commodore/books.htm` live under `books/thumbnails/`.
    /// Directories the site's own authoring tool left behind.
    ///
    /// FrontPage writes a `_vti_cnf` folder beside every real one, holding a
    /// bookkeeping stub per file, and the server lists them like any other
    /// directory. They are not content — they are the tool's notes about
    /// content — and reading them put 839 phantom entries on the shelf, each
    /// named after a real book and pointing at a stub.
    static let toolDirectories = ["_vti_cnf", "_vti_pvt", "_vti_bin", "_vti_txt", "_private"]

    static func isToolPath(_ url: String) -> Bool {
        let lowered = url.lowercased()
        return toolDirectories.contains { lowered.contains("/\($0)/") || lowered.hasSuffix("/\($0)") }
    }

    public static func entries(in html: String, pageURL: String) -> [BombJackEntry] {
        guard !isToolPath(pageURL) else { return [] }
        var found: [BombJackEntry] = []
        var seen: Set<String> = []

        for cellHTML in cell.allMatches(html) {
            guard let link = anchor.firstGroups(cellHTML),
                  let file = absolute(link[1], from: pageURL),
                  !isToolPath(file) else { continue }
            // One entry per archive. A cell occasionally links the same file
            // twice — from the cover and from a "download" word beside it.
            guard seen.insert(file).inserted else { continue }

            // The title is what the cell says before the link. Everything
            // after it is the page count and the size.
            let beforeLink = String(cellHTML.prefix(upTo:
                cellHTML.range(of: link[0])?.lowerBound ?? cellHTML.endIndex))

            // Curated pages put the name above the link and the cover inside
            // it. Directory listings — which is how whole platforms are served
            // — put the file name *inside* the link and nothing above it at
            // all, so a title taken only from what precedes the link is empty
            // and the entry was being dropped. That is why Epson HX-20,
            // Aquarius, Oric-1 and the rest came back with nothing: not
            // because the walk never arrived, but because it read their pages
            // and found nothing it recognised.
            // The link's own text is deliberately not consulted. On a curated
            // page it is empty — the link wraps the cover image — and on a
            // listing it is the raw file name, which `name(ofFile:)` gives
            // back in a form fit to read.
            let title = [text(beforeLink), name(ofFile: file)]
                .first { !$0.isEmpty } ?? ""
            guard !title.isEmpty else { continue }

            let afterLink = String(cellHTML.suffix(from:
                cellHTML.range(of: link[0])?.upperBound ?? cellHTML.startIndex))

            found.append(BombJackEntry(
                title: title,
                file: file,
                cover: img.firstGroups(link[2]).flatMap { absolute($0[1], from: pageURL) },
                pages: pageCount.firstGroups(afterLink).flatMap { Int($0[1]) }))
        }
        return found
    }

    // MARK: - Crawling

    private static let hrefs = Rx(#"<a[^>]+href\s*=\s*["']?([^"'\s>]+)["']?"#, [.caseInsensitive])

    /// The pages worth following from here.
    ///
    /// Same host, and pages only — the archives themselves are what the entries
    /// point at and must never be walked into. Directory URLs are kept because
    /// much of the tree is served as Apache listings with no index file named.
    public static func pageLinks(in html: String, pageURL: String) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for match in hrefs.allGroups(html) {
            let raw = match[1]
            guard !raw.hasPrefix("#"), !raw.lowercased().hasPrefix("mailto:"),
                  let resolved = absolute(raw, from: pageURL),
                  let url = URL(string: resolved),
                  url.host?.lowercased() == host
            else { continue }

            let ext = url.pathExtension.lowercased()
            guard ext.isEmpty || ext == "htm" || ext == "html" else { continue }
            // Not worth a request: these hold one stub per real file, so a
            // walk that follows them roughly doubles its own size for nothing.
            guard !isToolPath(resolved) else { continue }

            // Query and fragment are dropped, not kept.
            //
            // The fragment is obvious — it is the same page. The query is the
            // one that matters: much of this tree is served as Apache
            // directory listings, and every listing carries its own sort links
            // — `?C=N;O=D`, `?C=M;O=A`, `?C=S;O=A`, `?C=D;O=A`. Each is a
            // different URL with byte-identical content, and each listing
            // links to the sorted forms of the listings inside it.
            //
            // Left in, that multiplies without end. A walk that followed them
            // fetched one directory thirty-eight times and had spent 62% of
            // its requests re-downloading pages it already had. Nothing in
            // this archive is behind a query string: it is static HTML, and
            // the sort order is a view of a page rather than a page.
            var bare = resolved.components(separatedBy: "#")[0]
            bare = bare.components(separatedBy: "?")[0]
            if seen.insert(bare).inserted { out.append(bare) }
        }
        return out
    }

    // MARK: - Bits

    /// An archive's file name as something to put on a shelf.
    ///
    /// The last resort for a title, and what a directory listing effectively
    /// offers: "Epson_HX-20_Technical_Manual.pdf" reads perfectly well as
    /// "Epson HX-20 Technical Manual" and is what the file is called.
    static func name(ofFile url: String) -> String {
        guard let last = URL(string: url)?.deletingPathExtension().lastPathComponent,
              !last.isEmpty else { return "" }
        let decoded = last.removingPercentEncoding ?? last
        return decoded.replacingOccurrences(of: "_", with: " ")
                      .replacingOccurrences(of: "  ", with: " ")
                      .trimmingCharacters(in: .whitespaces)
    }

    /// Resolves a possibly-relative path against the page it was found on.
    static func absolute(_ path: String, from pageURL: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let base = URL(string: pageURL),
              let resolved = URL(string: trimmed, relativeTo: base) else { return nil }
        return resolved.absoluteURL.absoluteString
    }

    /// A fragment of markup as the one line a reader would see.
    ///
    /// `<br>` becomes a space rather than a newline: a book's title is spread
    /// over three of them purely to fit the cell, and the shelf wants it back
    /// as one line.
    public static func text(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: " ",
                                          options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ",
                                   options: .regularExpression)
        s = HTMLText.decodeEntities(s)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Categories

    /// What kind of thing an archive is, from where it sits in the tree.
    ///
    /// The catalogue is eighteen thousand items and shipping it as one switch
    /// meant one seed of that size — slow to load, slow to leave, and nothing
    /// anybody wanted all of. Split by category it is eight, each of a size
    /// the app handles without noticing, and a reader takes the ones they
    /// care about.
    ///
    /// Category rather than platform, because platform is hopelessly lopsided
    /// here: Commodore alone is nine thousand of it while thirty of the
    /// forty-six platforms have fewer than thirty items each. Category cuts
    /// the same material evenly, and is also what somebody would actually
    /// choose by.
    public enum Category: String, CaseIterable, Sendable {
        case commodoreMagazines, amigaMagazines, otherMagazines
        case books, hardware, games, other

        /// The order the settings list shows them in.
        public static let inMenuOrder: [Category] =
            [.commodoreMagazines, .amigaMagazines, .otherMagazines,
             .books, .hardware, .games, .other]

        /// What the switch is called.
        public var display: String {
            switch self {
            case .commodoreMagazines: return "Commodore Magazines"
            case .amigaMagazines:     return "Amiga Magazines"
            case .otherMagazines:     return "Other Magazines"
            case .books:              return "Books"
            case .hardware:           return "Hardware Manuals"
            case .games:              return "Video Games-related"
            case .other:              return "Other"
            }
        }

        /// The file this category ships as.
        public var resource: String { "bombjack-\(rawValue)" }
    }

    /// Commodore's 8-bit line, as this archive spells it — the same machine
    /// appears under several directory names, and `-other` is a second folder
    /// for one of them rather than a different computer.
    static let commodoreDirectories: Set<String> = [
        "commodore", "commodore-other", "vic-20", "vic20", "vic-20-other",
        "vic20-other", "c16-plus4", "c16-plus4-other", "kim-pet", "kim-pet-other",
    ]

    static let amigaDirectories: Set<String> = ["amiga", "amiga-other"]

    /// Which category an archive belongs to.
    ///
    /// Read off the path, which is how this archive is organised — the tree
    /// says `/commodore/magazines/ahoy/`, and the words in it are the answer.
    ///
    /// The order is the classification, and two steps of it were each got
    /// wrong once. Newsletters are tested before hardware because a newsletter
    /// lives at `/commodore/newsletters/sprite/` and that path carries the
    /// word "commodore" too — after it, 1,444 newsletters filed as hardware.
    /// Applications are tested *after* hardware for the mirror reason: a
    /// manual at `/commodore/applications/` is a manual, and pulling that word
    /// forward moved 1,475 of them out.
    public static func category(of url: String) -> Category {
        // Decoded, and split on spaces as well as slashes.
        //
        // Joystik lives on another host under "Magazines%20and%20Books", so
        // its path segment is neither `magazines` nor anything else this looks
        // for — ten magazines filed as "Other". Decoding turns it into
        // "magazines and books", and splitting on the space makes the word
        // itself a segment, which is all the rules below ever wanted.
        let decoded = (url.removingPercentEncoding ?? url).lowercased()
        let parts = Set(decoded.split(whereSeparator: { $0 == "/" || $0 == " " })
                               .map(String.init))
        if parts.contains("magazines") {
            if !parts.isDisjoint(with: commodoreDirectories) { return .commodoreMagazines }
            if !parts.isDisjoint(with: amigaDirectories) { return .amigaMagazines }
            return .otherMagazines
        }
        if parts.contains("newsletters") { return .other }
        if !parts.isDisjoint(with: ["books", "books-other"]) { return .books }
        if !parts.isDisjoint(with: ["games", "games-cassette", "games-disk"]) { return .games }
        if !parts.isDisjoint(with: ["hardware", "commodore", "amiga-commodore",
                                    "amiga-other", "commodore-other"]) { return .hardware }
        return .other
    }
}
