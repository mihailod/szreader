import Foundation

/// vintageapple.org: scanned Apple-world magazines, books and manuals.
///
/// The other half of the era from BombJack, which is Commodore, Amiga and the
/// 8-bit machines and has almost no Apple magazines — one Softalk issue, no
/// Byte, no Macworld, no MacUser.
///
/// Technically the simplest source in the app: static HTML tables on a plain
/// server, one row per file, carrying a thumbnail, the PDF, a title and a year
/// column. No JavaScript, no index to reconcile, and it serves at roughly
/// 12 MB/s — eight times what Atarimania allows.
public enum VintageApple {

    public static let base = "https://vintageapple.org/"

    /// Which shelf a section belongs on.
    ///
    /// The split is about *what the material is worth*, not about size: at
    /// 1,949 rows the whole site would seed in well under a second. The
    /// magazines are largely already on archive.org — which holds more Byte
    /// than this site does — while the books are about half unavailable
    /// anywhere else and overlap the app's own BombJack shelf by only 11%.
    /// Two switches let a reader take the scarce half without the duplicate
    /// half.
    public enum Group: String, CaseIterable, Sendable {
        case magazines
        case books

        public static let inMenuOrder: [Group] = [.magazines, .books]

        public var display: String {
            switch self {
            case .magazines: return "Magazines"
            case .books:     return "Books & Manuals"
            }
        }

        public var resource: String { "vintageapple-\(rawValue)" }
    }

    /// One section of the site: a directory, what to call it, and which shelf
    /// it belongs on.
    ///
    /// Hand-written because the site states none of it. Every page's `<title>`
    /// is the literal string "Vintage Apple" and there is not one heading tag
    /// on any of them, so the names here come from the index's own link text.
    public struct Section: Equatable, Sendable {
        public let slug: String
        public let name: String
        public let group: Group

        public init(slug: String, name: String, group: Group) {
            self.slug = slug; self.name = name; self.group = group
        }

        /// Where the section's listing lives.
        public var path: String { "\(slug)/" }
    }

    /// Every section worth shipping.
    ///
    /// Three of the site's directories are left out on purpose. `macdrivers`
    /// and `gamba2` are mirrors of other people's sites and hold no PDFs at
    /// all. `lisainfo` holds three, but it is not a listing: it is a free-form
    /// page of centred links with its files at the section root rather than
    /// under `pdf/`, mixed in with a .mov and a .zip. Three files of Lisa
    /// miscellany do not justify a second parser, and a section that yields
    /// nothing is reported by the build rather than passing unnoticed.
    public static let sections: [Section] = [
        .init(slug: "byte",           name: "Byte",                        group: .magazines),
        .init(slug: "macworld",       name: "Macworld",                    group: .magazines),
        .init(slug: "macuser",        name: "MacUser",                     group: .magazines),
        .init(slug: "pcworld",        name: "PC World",                    group: .magazines),
        .init(slug: "softalk",        name: "Softalk",                     group: .magazines),
        .init(slug: "develop",        name: "Apple develop",               group: .magazines),

        .init(slug: "macbooks",       name: "Mac Books",                   group: .books),
        .init(slug: "macprogramming", name: "Mac Programming",             group: .books),
        .init(slug: "apple_ii",       name: "Apple II Books",              group: .books),
        .init(slug: "catalogs",       name: "Mac Catalogs",                group: .books),
        .init(slug: "macmanuals",     name: "Apple Mac Manuals",           group: .books),
        .init(slug: "laserwriter",    name: "LaserWriter",                 group: .books),
        .init(slug: "inside_r",       name: "Inside Macintosh (Revamped)", group: .books),
        .init(slug: "inside_o",       name: "Inside Macintosh (Original)", group: .books),
        .init(slug: "apple_jobs",     name: "Apple & Steve Jobs",          group: .books),
        .init(slug: "applefacts",     name: "Apple Facts",                 group: .books),
    ]

    /// One row of a section's table.
    public struct Entry: Equatable, Sendable {
        /// Path to the scan, relative to the section: "pdf/197509_Byte….pdf".
        public let pdf: String
        /// Path to the thumbnail, relative to the section. Every row on every
        /// section has one.
        public let thumb: String?
        /// What the shelf calls it, cleaned up from the link's own text.
        public let title: String
        public let year: Int?
        public let month: Int?

        public init(pdf: String, thumb: String?, title: String,
                    year: Int?, month: Int?) {
            self.pdf = pdf; self.thumb = thumb; self.title = title
            self.year = year; self.month = month
        }

        /// The filename without its extension. Unique within a section, and
        /// the section is part of the id the catalogue records.
        public var stem: String {
            (pdf as NSString).lastPathComponent
                .replacingOccurrences(of: ".pdf", with: "")
        }
    }

    // MARK: - Parsing a section

    private static let pdfHref = Rx(#"(?i)href="(pdf/[^"]+\.pdf)"[^>]*>(.*?)</a>"#)
    private static let thumbSrc = Rx(#"(?i)src="(thumb/[^"]+)""#)
    private static let cell = Rx(#"(?is)<td[^>]*>(.*?)</td>"#)
    /// The date column, which is `1975` on some sections and `1984-04` on
    /// others. Anchored at both ends so the *scanned* column beside it —
    /// `2016-02-29` — cannot match: a scan date is not a cover date, and
    /// reading one as the other would file every Macworld under 2016.
    private static let dateCell = Rx(#"^((?:19|20)\d{2})(?:-(\d{2}))?$"#)
    private static let tag = Rx(#"<[^>]+>"#)

    /// Every file a section's table lists.
    ///
    /// Split on `<tr`, which is what one row is. The site's markup is
    /// hand-written and its cells carry one presentational class; the row, the
    /// `pdf/` href and the year cell are the parts that carry meaning.
    public static func entries(in html: String) -> [Entry] {
        var out: [Entry] = []
        for chunk in html.components(separatedBy: "<tr").dropFirst() {
            guard let link = pdfHref.firstGroups(chunk), link.count > 2 else { continue }
            let pdf = link[1]
            let text = HTMLText.decodeEntities(tag.replacing(link[2], with: " "))

            // The date has its own column, and on most sections it states
            // the month as well. Taking it from the table rather than from the
            // filename is what lets one parser read all seventeen sections:
            // only Byte's files are named `YYYYMM_`.
            var year: Int?
            var tabledMonth: Int?
            for groups in cell.allGroups(chunk) where groups.count > 1 {
                let value = HTMLText.decodeEntities(tag.replacing(groups[1], with: ""))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parts = dateCell.firstGroups(value), parts.count > 1,
                      let n = Int(parts[1]) else { continue }
                year = n
                if parts.count > 2, let m = Int(parts[2]), (1...12).contains(m) {
                    tabledMonth = m
                }
                break
            }

            let thumb = thumbSrc.firstGroups(chunk).flatMap { $0.count > 1 ? $0[1] : nil }
            out.append(Entry(pdf: pdf,
                             thumb: thumb,
                             title: title(fromLinkText: text, stem: pdf),
                             year: year,
                             // The table wins where it speaks; the filename
                             // is only consulted for the sections that state a
                             // year alone.
                             month: tabledMonth ?? month(inFilename: pdf, year: year)))
        }
        return out
    }

    /// What to call a row on the shelf.
    ///
    /// The link's text is the filename with underscores turned to spaces, so
    /// it already reads as a title once the extension and any leading date
    /// stamp are gone: "197509 Byte Magazine Vol 00-01 The Worlds Greatest
    /// Toy.pdf" becomes "Byte Magazine Vol 00-01 The Worlds Greatest Toy".
    static func title(fromLinkText text: String, stem: String) -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = (stem as NSString).lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
        }
        if name.lowercased().hasSuffix(".pdf") { name = String(name.dropLast(4)) }
        name = name.replacingOccurrences(of: "_", with: " ")
        // A leading date stamp is not a title; the row carries year and month
        // of its own.
        name = leadingStamp.replacing(name, with: "")
        return name.split(separator: " ").joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let leadingStamp = Rx(#"^\s*(19|20)\d{4}\s+"#)

    // MARK: - Months

    static let monthNames = ["january", "february", "march", "april", "may", "june",
                             "july", "august", "september", "october", "november",
                             "december"]

    private static let sixDigit = Rx(#"(?:^|[/_])((?:19|20)\d{2})(\d{2})(?:[_.]|$)"#)
    private static let fourDigit = Rx(#"[_\-](\d{2})(\d{2})(?=[_.])"#)

    /// The month a filename encodes, checked against the year the table states.
    ///
    /// Three conventions, one per publisher, and no section uses two: Byte
    /// stamps `197509_`, Macworld and MacUser and PC World and Softalk and
    /// develop all use a two-digit `_8404_`, and the book sections state no
    /// month at all.
    ///
    /// The year is what makes the short form safe to read. `PC_World_8303_V1N1`
    /// also contains "1" and "1", and a rule that simply hunted for four digits
    /// would find plenty; requiring that the pair agree with the year column —
    /// 83 against 1983 — is what tells a date from a volume number.
    public static func month(inFilename path: String, year: Int?) -> Int? {
        let name = (path as NSString).lastPathComponent

        if let groups = sixDigit.firstGroups(name), groups.count > 2,
           let stamped = Int(groups[1]), let month = Int(groups[2]),
           (1...12).contains(month), year == nil || stamped == year {
            return month
        }
        if let year {
            for groups in fourDigit.allGroups(name) where groups.count > 2 {
                guard let yy = Int(groups[1]), let month = Int(groups[2]),
                      (1...12).contains(month) else { continue }
                if 1900 + yy == year || 2000 + yy == year { return month }
            }
        }
        // Some are spelled out — "MacWorld_8405_May-June_1984". Only consulted
        // when the digits said nothing, and the earliest name wins for the
        // same reason it does elsewhere: a double month is one issue, dated by
        // the first of them.
        let lower = name.lowercased()
        var best: (Int, Int)?
        for (index, month) in monthNames.enumerated() {
            guard let found = lower.range(of: month) else { continue }
            let at = lower.distance(from: lower.startIndex, to: found.lowerBound)
            if best == nil || at < best!.0 { best = (at, index + 1) }
        }
        return best?.1
    }
}
