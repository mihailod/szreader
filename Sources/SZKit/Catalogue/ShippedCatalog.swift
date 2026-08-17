import Foundation

/// A catalogue that ships inside the app: everything one source holds, minus
/// the scans themselves.
///
/// One shape for every such source — `retrospec-catalog.json` built by
/// `retrospec-build`, `archive-catalog.json` built by `archive-build` — read
/// by one seed, so a generator and the consumer cannot drift apart and a third
/// source is a file rather than a code path. JSON rather than a prebuilt
/// SQLite file: it diffs in git, so a rebuild shows exactly which issues the
/// source gained or lost, and it carries no coupling to the SQLite version the
/// phone happens to have.
///
/// The whole file is metadata — names, dates, sizes and URLs. No artwork and
/// no scans are shipped; the covers are hotlinked and the archives are
/// downloaded on request, which is what keeps the app free of content it has
/// no right to redistribute.
public struct ShippedCatalog: Codable, Equatable, Sendable {

    /// Bumped when the *shape* of this file changes, so a seed written for an
    /// older layout refuses a newer file instead of misreading it.
    public static let currentVersion = 1

    public let version: Int
    /// When the catalogue was built, for the settings screen and for judging
    /// how stale a shipped file has become.
    public let generated: String
    /// Prefix for every relative path below. Stored once rather than repeated
    /// 653 times, and it means the archive moving host is a one-line change.
    public let base: String
    public let series: [Series]
    public let issues: [Issue]

    public struct Series: Codable, Equatable, Sendable {
        public let key: String
        public let name: String
        public let code: String
        public let language: String?

        public init(key: String, name: String, code: String, language: String?) {
            self.key = key; self.name = name; self.code = code; self.language = language
        }
    }

    public struct Issue: Codable, Equatable, Sendable {
        /// The source's own id — "SK_84_10", or an archive.org identifier.
        /// Half of the natural key.
        public let id: String
        /// Which run it belongs to; the other half.
        public let series: String
        /// Position in the run, counted chronologically from one.
        public let number: Int
        /// What the shelf calls it: "Oktobar 1984", or a book's title.
        public let title: String
        public let year: Int?
        public let month: Int?
        /// The one file that is the issue, relative to `base`.
        ///
        /// Named for what RetroSpec serves, which is a zip of scans. It is
        /// whatever container the source publishes — archive.org's items are a
        /// single PDF — and nothing downstream cares: the download sniffs the
        /// magic bytes and the reader opens what it finds.
        public let zip: String
        public let cover: String?
        /// A small stand-in for the cover: RetroSpec's 68x93 grid thumbnail,
        /// archive.org's item tile. Unused today — covers are hotlinked at
        /// full size — but recorded so that showing something instantly while
        /// the real cover loads stays a UI change rather than a rebuild.
        public let thumb: String?
        /// Size of the archive, from the site's own headers at build time.
        /// Nil when the archive is gone.
        public let bytes: Int64?
        /// Scanned pages in the archive.
        public let pages: Int?
        /// Set only when the archive 404s. Absent means alive — the eight
        /// dead issues are still listed, because their covers and metadata
        /// are real and the site may restore the files.
        public let dead: Bool?

        public init(id: String, series: String, number: Int, title: String,
                    year: Int?, month: Int?, zip: String, cover: String?,
                    thumb: String?, bytes: Int64?, pages: Int?, dead: Bool?) {
            self.id = id; self.series = series; self.number = number; self.title = title
            self.year = year; self.month = month; self.zip = zip; self.cover = cover
            self.thumb = thumb; self.bytes = bytes; self.pages = pages; self.dead = dead
        }

        /// Absolute URL of the archive.
        public func zipURL(base: String) -> String { base + zip }
        /// Absolute URL of the cover, if the site has one.
        public func coverURL(base: String) -> String? { cover.map { base + $0 } }
    }

    public init(version: Int, generated: String, base: String,
                series: [Series], issues: [Issue]) {
        self.version = version; self.generated = generated; self.base = base
        self.series = series; self.issues = issues
    }

    // MARK: - Reading

    /// Decoder and encoder agree on key order so a rebuild that changed
    /// nothing produces a byte-identical file, and a rebuild that changed
    /// something produces a readable diff.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decode(_ data: Data) throws -> ShippedCatalog {
        try JSONDecoder().decode(ShippedCatalog.self, from: data)
    }
}
