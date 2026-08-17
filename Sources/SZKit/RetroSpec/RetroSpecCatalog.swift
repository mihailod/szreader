import Foundation

/// One magazine as an index page lists it.
///
/// Everything here comes off the page as written. Nothing is corrected or
/// filled in — that is the seed builder's job, which has the `magshow.php`
/// metadata to correct it *with*.
public struct RetroSpecEntry: Equatable, Sendable {
    /// The site's own identifier: "SK_84_10", "Knjige_Mirko".
    public let id: String
    /// Which run it belongs to, taken from the id's prefix.
    public let seriesKey: String
    /// The caption printed under the cover — "1984 - 10", or a book's title.
    ///
    /// **Not** to be trusted as the issue's date. Three cells on
    /// `indexSpecial.html` carry a caption copied from the cell above:
    /// `MCW_91_06` is captioned "1994 - 12" while its id, its zip and the
    /// site's own metadata all say June 1991. Kept because it is the only
    /// place a double issue's second month appears ("1985 - 02/03"), and
    /// because a book has nothing else.
    public let label: String
    /// Absolute URL of the archive.
    public let zipURL: String
    /// Absolute URL of the full-size cover — the issue's own first page.
    public let coverURL: String?
    /// Absolute URL of the 68x93 grid thumbnail.
    public let thumbnailURL: String?
    /// Year of publication, from the id rather than the caption.
    public let year: Int?
    /// Month of publication, from the id. Nil for the books, and for the two
    /// magazines the site dates by year alone.
    public let month: Int?
    /// Whether the id is flagged as a special issue — `RA_88_04S`.
    public let isSpecial: Bool

    public init(id: String, seriesKey: String, label: String, zipURL: String,
                coverURL: String?, thumbnailURL: String?,
                year: Int?, month: Int?, isSpecial: Bool) {
        self.id = id; self.seriesKey = seriesKey; self.label = label
        self.zipURL = zipURL; self.coverURL = coverURL; self.thumbnailURL = thumbnailURL
        self.year = year; self.month = month; self.isSpecial = isSpecial
    }
}

/// What `magshow.php` knows about one issue, which the index page does not.
public struct RetroSpecIssueInfo: Equatable, Sendable {
    /// The run's name as the site's database holds it: "Svet Kompjutera".
    /// For a book, its title.
    public let seriesName: String
    public let year: Int?
    /// The month as printed — "Oktobar", "Julij/Avgust", "Jul-SpecijalniBroj".
    /// Left as text: the site mixes Serbian, Croatian and Slovenian month
    /// names, and some entries are not a month at all.
    public let monthText: String?
    /// The issue's number within its year, which is how the site counts.
    /// Zero marks a special that sits outside the numbering.
    public let numberInYear: Int?
    public let language: Language?
    /// How many scanned pages the archive holds.
    public let pageCount: Int?

    public init(seriesName: String, year: Int?, monthText: String?,
                numberInYear: Int?, language: Language?, pageCount: Int?) {
        self.seriesName = seriesName; self.year = year; self.monthText = monthText
        self.numberInYear = numberInYear; self.language = language; self.pageCount = pageCount
    }
}

/// Reads RetroSpec's static index pages.
///
/// Nothing like the StripZona catalogue, and deliberately not built on it: a
/// forum topic is prose with links buried in it, where the whole problem is
/// guessing which label claims which URL. These pages are a generated table —
/// one cell per issue, each holding an id, an archive, a cover and a
/// thumbnail. There is no attribution to guess, so there is no `LabelStyle`,
/// no coverage measurement and no corpus to learn from.
public enum RetroSpecCatalog {

    /// Where the index pages and everything they link live.
    ///
    /// The pages themselves use relative hrefs, and the copy on disk uses a
    /// long-dead domain in a handful of them, so the base is supplied here
    /// rather than read from the markup.
    public static let base = "https://retrospec.elite.org/pcsux/"

    // MARK: - Decoding

    /// Text out of a downloaded page.
    ///
    /// The pages all declare windows-1250 and only some of them mean it:
    /// `indexKnjige`, `indexMMSlo` and `indexRA` are genuinely cp1250, while
    /// `indexGal` and `indexMMHrv` are UTF-8 behind the same meta tag.
    /// Decoding everything as cp1250 turns the UTF-8 pages' diacritics into
    /// mojibake; decoding everything as UTF-8 fails outright on the other
    /// three. UTF-8 first and cp1250 as the fallback gets both right, because
    /// a cp1250 page carrying diacritics is not valid UTF-8 and so cannot be
    /// mistaken for one.
    public static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1250)
    }

    // MARK: - Index pages

    private static let contentOpen = "<!-- CONTENT -->"
    private static let contentClose = "<!-- /CONTENT -->"

    private static let cellOpen = Rx(#"(?i)<td\b[^>]*>"#)
    private static let issueID = Rx(#"magshow\.php\?all=([A-Za-z0-9_.\-]+)"#)
    private static let zipHref = Rx(#"(?i)href="([^"]*/ZIP/[^"]+\.zip)""#)
    private static let coverHref = Rx(#"(?i)href="([^"]*/Covers/[^"]+)""#)
    // Anything but the page furniture under gfx/, which is the frame and the
    // series banners rather than any issue's artwork.
    private static let thumbSrc = Rx(#"(?i)<img[^>]*src="((?!gfx/)[^"]+)""#)
    private static let anchor = Rx(#"(?is)<a\b[^>]*>.*?</a>"#)
    private static let tag = Rx(#"<[^>]+>"#)

    /// Every issue an index page lists, in the order it lists them.
    ///
    /// Cells with no `magshow.php` link are skipped: the grid is a calendar,
    /// twelve columns to a year, and a month with no surviving scan is a cell
    /// holding a "no cover" placeholder and nothing else.
    ///
    /// Deliberately does not de-duplicate. An id identifies one issue and the
    /// cell scan cannot emit one twice, which the tests check across all 653
    /// — so a filter here would only ever hide a parse that had gone wrong,
    /// and the seed's natural key is the honest place to reject a collision.
    public static func entries(in html: String, base: String = base) -> [RetroSpecEntry] {
        var out: [RetroSpecEntry] = []

        for cell in cells(in: contentRegion(of: html)) {
            guard let id = issueID.firstGroups(cell)?.capture(1), !id.isEmpty,
                  let zip = zipHref.firstGroups(cell)?.capture(1), !zip.isEmpty,
                  let series = RetroSpecSeriesTable.series(forIssueID: id) else { continue }

            let date = dateComponents(ofIssueID: id)
            out.append(RetroSpecEntry(
                id: id,
                seriesKey: series.key,
                label: text(of: cell),
                zipURL: absolute(zip, base: base),
                coverURL: coverHref.firstGroups(cell)?.capture(1)
                    .nonEmpty.map { absolute($0, base: base) },
                thumbnailURL: thumbSrc.firstGroups(cell)?.capture(1)
                    .nonEmpty.map { absolute($0, base: base) },
                year: date.year, month: date.month, isSpecial: date.isSpecial))
        }
        return out
    }

    /// The generated table, without the page frame around it.
    ///
    /// Every page marks it, and staying inside the markers keeps the frame's
    /// own nested layout tables out of the cell scan entirely.
    static func contentRegion(of html: String) -> String {
        guard let open = html.range(of: contentOpen),
              let close = html.range(of: contentClose, range: open.upperBound..<html.endIndex)
        else { return html }
        return String(html[open.upperBound..<close.lowerBound])
    }

    /// The innermost content of every table cell.
    ///
    /// A cell ends at whichever comes first, its own `</td>` or the next
    /// `<td>`. Stopping at the next opening tag is what makes an outer cell
    /// that wraps a table collapse to the empty text before its first child,
    /// instead of swallowing every issue inside it.
    static func cells(in html: String) -> [String] {
        let ns = html as NSString
        let whole = NSRange(location: 0, length: ns.length)
        return cellOpen.re.matches(in: html, range: whole).map { match in
            let start = match.range.upperBound
            let rest = NSRange(location: start, length: ns.length - start)
            let close = ns.range(of: "</td>", options: .caseInsensitive, range: rest)
            let next = ns.range(of: "<td", options: .caseInsensitive, range: rest)
            let end = [close.location, next.location]
                .filter { $0 != NSNotFound }.min() ?? ns.length
            return ns.substring(with: NSRange(location: start, length: end - start))
        }
    }

    /// The caption, with the cell's own links thrown away.
    ///
    /// Every cell ends with two links whose text is "zip" and "cover". They
    /// are furniture on every single issue, so leaving them in would make the
    /// caption of an untitled book read "Mirko Tipka Na Radirko zip cover".
    static func text(of cell: String) -> String {
        let withoutLinks = anchor.replacing(cell, with: " ")
        let plain = HTMLText.decodeEntities(tag.replacing(withoutLinks, with: " "))
        return plain.replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// When an issue came out, read from its id.
    ///
    /// The id is the one part of a cell the site generates from its database
    /// rather than typing by hand, which is why the date comes from here and
    /// not from the caption beside it.
    ///
    /// Two-digit years pivot at 70: the oldest issue is Galaksija's March
    /// 1972 and the newest its January 2001, so nothing falls near the seam.
    static func dateComponents(ofIssueID id: String) -> (year: Int?, month: Int?, isSpecial: Bool) {
        let parts = id.split(separator: "_")
        guard parts.count >= 3, let yy = Int(parts[1]), yy >= 0, yy <= 99 else {
            return (nil, nil, false)
        }
        let year = yy >= 70 ? 1900 + yy : 2000 + yy
        // "04S" — a special issue outside the monthly run.
        let raw = parts[2]
        let digits = raw.prefix(while: \.isNumber)
        let month = Int(digits).flatMap { (1...12).contains($0) ? $0 : nil }
        return (year, month, digits.count < raw.count)
    }

    /// A page-relative href against the site it came from.
    static func absolute(_ href: String, base: String = base) -> String {
        href.lowercased().hasPrefix("http") ? href : base + href
    }

    // MARK: - Issue metadata

    private static let infoName = Rx(#"(?is)<font size="5"[^>]*>\s*<b>(.*?)</b>"#)
    private static let infoDate = Rx(#"(?is)<font size="4"[^>]*>(.*?)</font>"#)
    private static let infoLanguage = Rx(#"(?i)Jezik:\s*([^<]+)<"#)
    private static let pageNumber = Rx(#"[?&]page=(\d+)"#)
    // "1984 Oktobar #1", "1985  #1", "1988 Jul-SpecijalniBroj #0".
    private static let dateLine = Rx(#"^(\d{4})\s*(.*?)\s*#(\d+)$"#)

    /// Month names the site's database has lost a character from.
    ///
    /// The same fault as "Ra?unari" in `RetroSpecSeriesTable`: a `?` byte
    /// where a `č` or `ć` belongs, in every encoding the page is served in.
    /// It has clearly been through a conversion that could not represent
    /// them — `ž` and `š` come through intact, which is why "Održavanje" and
    /// "vaš" are fine and only these two are not.
    ///
    /// A closed vocabulary, and complete: of the twelve Croatian month names
    /// only *siječanj* and *veljača* contain either character, and neither
    /// Serbian nor Slovenian month names contain any diacritic at all. Plain
    /// substring replacement rather than whole-token matching, because the
    /// month can be a compound — "Julij/Avgust", "Svibanj-Maj".
    static let lostCharacters = [
        "Sije?anj": "Siječanj",
        "Velja?a": "Veljača",
    ]

    /// The month as it was actually printed, undoing the database's loss.
    static func repaired(_ text: String) -> String {
        guard text.contains("?") else { return text }
        var out = text
        for (broken, whole) in lostCharacters {
            out = out.replacingOccurrences(of: broken, with: whole)
        }
        return out
    }

    /// What one issue's `magshow.php` page says about it.
    ///
    /// This is where the real series names live. The index pages head each
    /// run with a picture of its logo, so the only machine-readable name for
    /// "Svet Kompjutera" anywhere on the site is here.
    public static func info(in html: String) -> RetroSpecIssueInfo? {
        guard let name = infoName.firstGroups(html)?.capture(1),
              case let seriesName = text(of: name), !seriesName.isEmpty else { return nil }

        var year: Int?, monthText: String?, number: Int?
        if let printed = infoDate.firstGroups(html)?.capture(1).nonEmpty.map(text(of:)),
           let parts = dateLine.firstGroups(printed) {
            year = Int(parts.capture(1))
            monthText = parts.capture(2).nonEmpty.map(repaired)
            number = Int(parts.capture(3))
        }

        // Every page of the issue is linked once from the contact sheet, so
        // the highest page number is the page count. Counted as distinct
        // values because the navigation repeats some of them.
        let pages = Set(pageNumber.allGroups(html).compactMap { Int($0.capture(1)) })

        return RetroSpecIssueInfo(
            seriesName: seriesName,
            year: year, monthText: monthText, numberInYear: number,
            language: infoLanguage.firstGroups(html)?.capture(1)
                .nonEmpty.flatMap(Language.init(siteWord:)),
            pageCount: pages.max())
    }
}

private extension String {
    /// Nil rather than "", so an absent capture group reads as absent.
    var nonEmpty: String? { isEmpty ? nil : self }
}
