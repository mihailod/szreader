import Foundation

/// Stripovi.com's free comics, as far as this app is concerned.
///
/// A fixed, small set — 31 Croatian comics, 1442 pages between them — which is
/// what makes this the fourth *shipped index* rather than a fifth browser:
/// switch the source on and the comics are on the shelf, with no page to find
/// and nothing to import.
///
/// Unlike BatCave there is no gate of any kind here. A plain request answers
/// 200, so nothing needs a web view: the pages are fetched by `URLSession`
/// like every other source's file, only one at a time.
public enum Stripovi {

    public static let host = "stripovi.com"
    public static let base = "https://www.stripovi.com/"

    /// Where one comic is read, one page at a time.
    ///
    /// `PageCount` and not `PageNum`, which is the parameter the site's own
    /// links carry and which does nothing: every link on the index ends
    /// `PageNum=0`, and the control that actually turns a page is
    /// `PageCount=n`. Reading the wrong one gives page one, 1442 times.
    ///
    /// Pages are numbered from one, as the site's own dropdown numbers them.
    public static func readerURL(comic id: Int, page: Int) -> String {
        "\(base)index.asp?page=online-comics-single&ComicID=\(id)&PageCount=\(page)"
    }

    /// The comic's own front page.
    public static func comicURL(id: Int) -> String { readerURL(comic: id, page: 1) }
}

/// The shipped index of Stripovi.com.
///
/// Its own file and its own decoder rather than the shared `ShippedCatalog`,
/// deliberately. That format is built around `zip` — "the one file that is the
/// issue" — and this source has no such file: a comic here is loose page
/// images and nothing else. Bending the shared shape to allow that would mean
/// making `zip` optional for the four catalogues that depend on it, which is a
/// change to working, shipped sources in return for saving one small decoder.
public struct StripoviCatalog: Decodable, Equatable, Sendable {

    /// Bumped when the *shape* changes, so an older app refuses a newer file
    /// rather than misreading it.
    public static let currentVersion = 1

    public let version: Int
    public let generated: String
    /// Prefix for every relative path below, stored once.
    public let base: String
    public let comics: [Comic]

    public struct Comic: Decodable, Equatable, Sendable {

        /// The site's `ComicID`, and the whole of its identity here.
        public let id: Int
        /// What the shelf calls it. For an episode of a run this is the
        /// episode's own name — "Snijeg u kolovozu" — with the run named
        /// separately, rather than the site's combined "Martina Mjesec 1: …".
        public let title: String
        /// The run this belongs to, or nil when it stands alone.
        ///
        /// Read from the archive block a comic page carries when it is part of
        /// a series, which is also where the number comes from. Five of the
        /// thirty-one are episodes of *Martina Mjesec*; the rest are singles.
        public let series: String?
        /// Position in the run, or 1 for a comic that stands alone.
        public let number: Int
        /// How many pages, from the site's own page dropdown.
        public let pages: Int
        /// Artwork made by the site for its listing, relative to `base`.
        ///
        /// These comics have no covers of their own — they are web comics, and
        /// the site drew a tile for each. It is the only artwork there is.
        public let cover: String?
        /// Who made it, with their roles: "Darko Macan (scenarij); …".
        public let creators: String?
        public let date: String?
        /// The site's one-line blurb, which is where a series is often
        /// announced before the archive block exists to say so.
        public let lead: String?

        // MARK: - How a page is addressed
        //
        // Every one of the 31 names its pages the same way: a fixed prefix,
        // then the page number padded to a fixed width. 27 pad to two digits
        // and 4 to three — exactly the four comics that run past 99 pages.
        //
        // The rule was fitted from sampled pages and then *checked against a
        // page that was not used to fit it*, for all 31. That check is the
        // only reason it is trusted, and it caught a first attempt that looked
        // perfect and was wrong for 30 of them: pages 1 to 5 are all single
        // digits, so they cannot tell a width of one from a width of two, and
        // the mistake only appears at page 10.
        //
        // It is still a rule inferred from a site that does not promise it.
        // `StripoviPages` is what happens when it stops being true.

        /// The directory the pages sit in, relative to `base`.
        public let dir: String
        public let prefix: String
        public let width: Int
        public let ext: String

        /// Where page `n` should be, if the rule still holds.
        ///
        /// One-based, matching the site. Returns nil outside the known range
        /// rather than a plausible address for a page that does not exist.
        public func pageImage(_ page: Int) -> String? {
            guard page >= 1, page <= pages else { return nil }
            let number = String(page)
            let padded = String(repeating: "0", count: max(0, width - number.count)) + number
            return "\(dir)/\(prefix)\(padded)\(ext)"
        }

        /// Every page, in reading order.
        public var pageImages: [String] {
            (1...max(pages, 1)).compactMap(pageImage)
        }
    }

    /// The shipped file.
    public static func shipped() throws -> StripoviCatalog {
        guard let url = Bundle.module.url(forResource: "stripovi-catalog",
                                          withExtension: "json") else {
            throw SeedError.catalogueMissing(.stripovi)
        }
        return try decode(try Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> StripoviCatalog {
        let file = try JSONDecoder().decode(StripoviCatalog.self, from: data)
        guard file.version <= currentVersion else { throw SeedError.tooNew(file.version) }
        return file
    }

    /// A relative path made absolute.
    ///
    /// Percent-encoding is applied because one of these directories is
    /// `webcomics/lumen&kremen`, and a raw `&` in a path is the kind of
    /// character that survives one URL parser and not the next.
    public func url(_ relative: String) -> String {
        let encoded = relative.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? relative
        return base + encoded
    }
}
