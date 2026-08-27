import Foundation

/// The PopBoks archive: two ex-Yugoslav music magazines, scanned in full.
///
/// Džuboks (1974-1985) and Ritam (1989-1995), published at popboks.com by
/// Društvo ljubitelja popularne kulture. Between them 208 issues and around
/// 13,600 pages, and the whole of both runs is there — this is the only place
/// either magazine survives in readable form.
///
/// A shipped index like Stripovi's rather than a browser, and for the same
/// reason: the set is fixed and small enough to seed, so switching the source
/// on puts both magazines on the shelf with nothing to find and nothing to
/// import.
///
/// **What makes this source unlike every other one: there are no page files.**
/// The site serves each page as a pyramid of 256-pixel tiles, the way a map
/// server does, and a page only exists once its tiles are put back together —
/// see `PopBoksPage`. Nothing downstream knows that: the fetcher stitches each
/// page and writes one JPEG, so what lands on disk is the same unpacked
/// directory a BatCave or Stripovi download produces.
public enum PopBoks {

    public static let host = "popboks.com"
    public static let base = "https://www.popboks.com/"

    /// One of the two magazines.
    ///
    /// They are two catalogues and two switches rather than one, the way
    /// BombJack's categories are: they are different magazines from different
    /// decades, a reader may well want one and not the other, and every
    /// mechanism the app already has — seed stamps, hiding, the filter menus —
    /// is per-site and needs no new concept to work.
    public enum Magazine: String, CaseIterable, Sendable, Equatable {
        case dzuboks
        case ritam

        /// The magazine's own name, spelled as it is on its masthead.
        public var display: String {
            switch self {
            case .dzuboks: return "Džuboks"
            case .ritam:   return "Ritam"
            }
        }

        /// Where the scans sit, relative to `base`.
        ///
        /// The two are not spelled alike — Džuboks keeps its images under
        /// `dzuboksimages` and Ritam under a plain `images` — which is exactly
        /// the kind of difference that becomes a bug the moment it is inferred
        /// from the magazine's name instead of written down.
        public var directory: String {
            switch self {
            case .dzuboks: return "dzuboks/dzuboksimages"
            case .ritam:   return "ritam/images"
            }
        }

        /// The magazine's own reader, and the referer its tiles are asked for
        /// with.
        public var readerURL: String {
            switch self {
            case .dzuboks: return "\(PopBoks.base)dzuboks/"
            case .ritam:   return "\(PopBoks.base)ritam/"
            }
        }

        /// The script the whole index is read out of.
        ///
        /// Both pages are a stub that loads one file; there is no HTML to
        /// parse and no listing to crawl. See `PopBoksIndex`.
        public var indexScript: String {
            switch self {
            case .dzuboks: return "\(PopBoks.base)dzuboks/js/dzuboks.js"
            case .ritam:   return "\(PopBoks.base)ritam/js/ritam.js"
            }
        }

        /// The catalogue shipped for this magazine.
        public var resource: String {
            switch self {
            case .dzuboks: return "popboks-dzuboks"
            case .ritam:   return "popboks-ritam"
            }
        }

        /// The order the settings list shows them: oldest magazine first,
        /// which is also the order they are published in.
        public static let inMenuOrder: [Magazine] = [.dzuboks, .ritam]
    }
}

/// The shipped index of one PopBoks magazine.
///
/// Its own shape rather than the shared `ShippedCatalog`, for the reason
/// `StripoviCatalog` is: that format is built around `zip`, "the one file that
/// is the issue", and there is no such file here. It is not the shape of
/// `StripoviCatalog` either — that one carries a rule for naming page *files*,
/// and a page here is not a file at all.
///
/// What this format has that neither of the others needs is `firstPage`. Ritam
/// does not always start at page one: issue 142's scan begins at page 3, and
/// an index that assumed 1 would spend its first two requests on tiles that
/// are not there and then refuse to finish the issue.
public struct PopBoksCatalog: Codable, Equatable, Sendable {

    /// Bumped when the *shape* changes, so an older app refuses a newer file
    /// rather than misreading it.
    public static let currentVersion = 1

    public let version: Int
    public let generated: String
    /// Prefix for every relative path below, stored once.
    public let base: String
    /// Which magazine this is, as `PopBoks.Magazine`'s raw value.
    public let magazine: String
    public let issues: [Issue]

    public struct Issue: Codable, Equatable, Sendable {

        /// The archive's own folder number, and the whole of this issue's
        /// identity. For Džuboks it is also the issue number; for Ritam it is
        /// a storage key and nothing more — Ritam's folders run 140 to 166 in
        /// an order that has no relation to when the issues came out.
        public let id: Int

        /// Position in the run, counted chronologically from one.
        ///
        /// For Džuboks this is the issue's real number, which is chronological
        /// already. For Ritam it is this app's own counting and appears
        /// nowhere on the site: the magazine restarted its numbering with each
        /// of its four relaunches, so its own numbers put four different
        /// issues at "1" and would shuffle the shelf into nonsense.
        public let number: Int

        /// The issue's own designation, as the archive gives it: "50" for a
        /// Džuboks, "6/7" for a Ritam double, "Godišnjak" for the yearbook.
        ///
        /// Kept beside `title` because it is the part a reader looking for a
        /// particular issue actually knows.
        public let label: String

        /// What the shelf calls it — "Džuboks 50", "Ritam 6/7".
        public let title: String

        public let year: Int
        /// The month it came out, where the archive says. Ritam's own labels
        /// carry one; Džuboks's index records only the year.
        public let month: Int?

        /// The first page the scan actually has.
        ///
        /// One almost everywhere, and 3 for the one Ritam whose scan starts
        /// part-way in. Reading position 1 is this page, not page 1.
        public let firstPage: Int

        /// How many pages the scan holds, from the archive's own page menu.
        public let pages: Int

        /// The **largest** tile grid any page of this issue uses, measured at
        /// build time.
        ///
        /// An upper bound rather than a fact about every page, and the
        /// distinction is worth the word: the grid belongs to the page, and
        /// nothing promises that every page of an issue was scanned alike.
        ///
        /// Every page of both magazines measured so far is 5 columns, and 7
        /// rows but for the two Ritam issues that are 8 — the ones the
        /// archive's own reader crops. No genuinely shorter page has been
        /// found. Two issues looked like they had one, and did not: Džuboks
        /// 34 and 60 are ordinary seven-row pages each *missing a single
        /// tile*, at 0,3 and 0,4, and a measurement that walked down column 0
        /// stopped at the hole and called them three and four rows tall. The
        /// build tool measures down two columns now for exactly that reason.
        ///
        /// The download still treats this as a ceiling rather than gospel:
        /// whole trailing rows the archive answers `403` for shrink the page,
        /// a hole anywhere else is drawn blank, and — because a ceiling set
        /// too low would crop in silence — every page asks whether the archive
        /// has anything past the recorded edge and refuses loudly if it does.
        /// See `PopBoksFetcher`.
        public let columns: Int
        public let rows: Int

        /// Tiles one page of this issue costs.
        public var tilesPerPage: Int { columns * rows }

        public init(id: Int, number: Int, label: String, title: String,
                    year: Int, month: Int?, firstPage: Int, pages: Int,
                    columns: Int, rows: Int) {
            self.id = id; self.number = number; self.label = label
            self.title = title; self.year = year; self.month = month
            self.firstPage = firstPage; self.pages = pages
            self.columns = columns; self.rows = rows
        }

        /// The page number on the site for reading position `n`.
        ///
        /// One-based on both sides. The shelf, the reader and the file names
        /// on disk all count a comic's pages from one; the archive counts from
        /// wherever its scan begins.
        public func sourcePage(at position: Int) -> Int? {
            guard position >= 1, position <= pages else { return nil }
            return firstPage + position - 1
        }
    }

    public init(version: Int, generated: String, base: String,
                magazine: String, issues: [Issue]) {
        self.version = version; self.generated = generated; self.base = base
        self.magazine = magazine; self.issues = issues
    }

    /// Decoder and encoder agree on key order, so a rebuild that changed
    /// nothing produces a byte-identical file and a rebuild that changed
    /// something produces a readable diff.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The shipped file for one magazine.
    public static func shipped(_ magazine: PopBoks.Magazine) throws -> PopBoksCatalog {
        guard let url = Bundle.module.url(forResource: magazine.resource,
                                          withExtension: "json") else {
            throw SeedError.catalogueMissing(magazine.site)
        }
        return try decode(try Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> PopBoksCatalog {
        let file = try JSONDecoder().decode(PopBoksCatalog.self, from: data)
        guard file.version <= currentVersion else { throw SeedError.tooNew(file.version) }
        return file
    }

    /// Which magazine this catalogue holds.
    public var kind: PopBoks.Magazine? { PopBoks.Magazine(rawValue: magazine) }

    // MARK: - Addresses
    //
    // Every address here is arithmetic on the issue's folder number and the
    // page number — there is nothing inferred and nothing to go stale, which
    // is what makes this source's addressing the most dependable in the app
    // even though it is by far the most verbose.

    /// The issue's listing thumbnail: the only artwork the archive publishes.
    public func coverURL(_ issue: Issue) -> String? {
        kind?.coverURL(issue: issue.id, base: base)
    }

    /// Where the issue lives on the archive — the folder holding its pages.
    public func folderURL(_ issue: Issue) -> String? {
        kind?.folderURL(issue: issue.id, base: base)
    }

    /// One tile of one page.
    ///
    /// - Parameter page: the site's own page number, from `sourcePage(at:)`.
    public func tileURL(_ issue: Issue, page: Int, column: Int, row: Int) -> String? {
        kind?.tileURL(issue: issue.id, page: page, column: column, row: row, base: base)
    }
}

public extension PopBoks.Magazine {

    // MARK: - Addresses
    //
    // On the magazine rather than only on the catalogue, because the build
    // tool needs them *before* a catalogue exists: it measures each issue's
    // tile grid by asking for tiles, and the grid is part of what it is
    // building. One implementation either way, so a path the tool probed and a
    // path the app fetches cannot come apart.

    /// The issue's listing thumbnail: the only artwork the archive publishes.
    ///
    /// Always under page `1`, even for the issue whose scan starts at page 3 —
    /// the site's own index builds this address the same way for every issue,
    /// and its cover is there where its first scanned page is not.
    func coverURL(issue: Int, base: String = PopBoks.base) -> String {
        "\(base)\(directory)/\(issue)/1/icon.jpg"
    }

    /// One tile of one page. `page` is the archive's own page number.
    func tileURL(issue: Int, page: Int, column: Int, row: Int,
                 base: String = PopBoks.base) -> String {
        "\(base)\(directory)/\(issue)/\(page)/\(PopBoksPage.level)_\(column)_\(row).jpg"
    }

    /// Where one issue lives on the archive: the folder every page and every
    /// tile of it sits under.
    ///
    /// This is the issue's address, and it is what the shelf records as its
    /// mirror. Not a file, because this archive has none — an issue here is
    /// some thousands of tiles below this prefix — but it is the true and
    /// unique answer to "where did this come from", which is the question the
    /// info panel is asking.
    func folderURL(issue: Int, base: String = PopBoks.base) -> String {
        "\(base)\(directory)/\(issue)/"
    }

    /// The source this magazine is filed under.
    ///
    /// Here rather than only on `IssueSite` so that the mapping is one
    /// question with one answer, in the direction each caller needs it.
    var site: IssueSite {
        switch self {
        case .dzuboks: return .popboksDzuboks
        case .ritam:   return .popboksRitam
        }
    }
}
