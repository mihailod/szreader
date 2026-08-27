import Foundation

/// Reads a PopBoks magazine's index out of the script that draws it.
///
/// Both magazines' pages are a stub: a `<head>`, an empty `<body>` and one
/// script. Everything — which issues exist, what they are called, how many
/// pages each has — is a literal array at the top of that script, which the
/// site walks to build its own front page. So there is no HTML to parse, no
/// listing to page through and no crawl: the whole index is two files.
///
/// The two are not written alike, and neither shape can be read as the other:
///
///   * **Džuboks** is two parallel arrays. `years` gives each year the range
///     of issue numbers it covers; `numbers` gives each issue its page count.
///     The array position *is* the issue number, and eleven entries carry a
///     page count of zero, which is how the archive records an issue it never
///     scanned.
///
///   * **Ritam** is a dictionary keyed by the archive's own folder number,
///     each holding a first page, a last page and a label. Its folder numbers
///     are storage keys with no relation to when an issue came out, and its
///     issue numbers restart at one with each of the magazine's four
///     relaunches — so the label is the only place its real designation and
///     date exist, and `years` is the only place their order does.
public enum PopBoksIndex {

    /// One issue, as the script describes it.
    ///
    /// Everything the catalogue needs except the tile grid, which the script
    /// does not record and the build tool measures — see
    /// `PopBoksCatalog.Issue.rows`.
    public struct Entry: Equatable, Sendable {
        public let id: Int
        public let number: Int
        public let label: String
        public let title: String
        public let year: Int
        public let month: Int?
        public let firstPage: Int
        public let pages: Int
    }

    public enum IndexError: Error, CustomStringConvertible {
        case arrayMissing(String)
        case empty(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .arrayMissing(let name): return "no `\(name)` array in the script"
            case .empty(let what):        return "\(what) came out empty"
            case .unreadable(let what):   return "could not read \(what)"
            }
        }
    }

    // MARK: - Džuboks

    /// The Džuboks run: 194 issue slots from 1974 to 1985.
    ///
    /// Issues the archive never scanned are dropped rather than listed. They
    /// carry a page count of zero, and — unlike RetroSpec's dead issues, which
    /// keep their covers and their metadata and may yet come back — there is
    /// nothing behind them at all: their cover thumbnails 403 along with their
    /// tiles. A row for one would be a shelf entry that can never show
    /// anything or open.
    public static func dzuboks(_ script: String) throws -> [Entry] {
        let source = stripComments(script)
        guard let yearsArray = array(named: "years", in: source, opening: "[") else {
            throw IndexError.arrayMissing("years")
        }
        guard let numbersArray = array(named: "numbers", in: source, opening: "[") else {
            throw IndexError.arrayMissing("numbers")
        }

        // [[74, [1, 3]], [75, [4, 19]], ...] — a two-digit year, then the
        // first and last issue numbers it covers.
        var yearOf: [Int: Int] = [:]
        for groups in Rx(#"\[\s*(\d+)\s*,\s*\[\s*(\d+)\s*,\s*(\d+)\s*\]\s*\]"#)
            .allGroups(yearsArray) {
            guard let shortYear = Int(groups[1]),
                  let first = Int(groups[2]), let last = Int(groups[3]),
                  first <= last else { continue }
            // Every issue of this magazine is 19xx; it ceased in 1985.
            for issue in first...last { yearOf[issue] = 1900 + shortYear }
        }
        guard !yearOf.isEmpty else { throw IndexError.empty("the Džuboks year ranges") }

        // [[1,52],[2,52],...] — issue number, page count, and sometimes a
        // third number. That third is the site's own tile-height hint for its
        // viewer; it is deliberately ignored here, because the tiles say what
        // shape a page is and a table cannot go stale.
        var entries: [Entry] = []
        for groups in Rx(#"\[\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*\d+\s*)?\]"#)
            .allGroups(numbersArray) {
            guard let number = Int(groups[1]), let pages = Int(groups[2]) else { continue }
            guard pages > 0 else { continue }          // never scanned
            guard let year = yearOf[number] else { continue }
            entries.append(Entry(
                id: number,
                // The issue number is chronological already, and is the number
                // printed on the cover — so it is both the identity and the
                // ordering, unlike Ritam below.
                number: number,
                label: String(number),
                title: "\(PopBoks.Magazine.dzuboks.display) \(number)",
                year: year,
                // The index records only which year a run of issues falls in.
                month: nil,
                firstPage: 1,
                pages: pages))
        }
        guard !entries.isEmpty else { throw IndexError.empty("the Džuboks issue list") }
        return entries.sorted { $0.number < $1.number }
    }

    // MARK: - Ritam

    /// The Ritam run: 25 issues across four relaunches, 1989 to 1995.
    public static func ritam(_ script: String) throws -> [Entry] {
        let source = stripComments(script)
        guard let yearsArray = array(named: "years", in: source, opening: "[") else {
            throw IndexError.arrayMissing("years")
        }
        guard let numbersDict = array(named: "numbers", in: source, opening: "{") else {
            throw IndexError.arrayMissing("numbers")
        }

        // {140:[1,84,"2 - Okt '90."], 142:[3,83,"4 / 5 - Jan-Feb '91.",4], ...}
        // The fourth element is the viewer's tile-height hint, ignored here
        // for the same reason Džuboks's third is.
        struct Raw { let first: Int; let last: Int; let label: String }
        var raw: [Int: Raw] = [:]
        for groups in Rx(#"(\d+)\s*:\s*\[\s*(\d+)\s*,\s*(\d+)\s*,\s*"([^"]*)""#)
            .allGroups(numbersDict) {
            guard let id = Int(groups[1]),
                  let first = Int(groups[2]), let last = Int(groups[3]),
                  first <= last else { continue }
            raw[id] = Raw(first: first, last: last, label: groups[4])
        }
        guard !raw.isEmpty else { throw IndexError.empty("the Ritam issue list") }

        // [[1, [155, 156, ...]], [2, [145, 140, ...]], ...] — the four runs,
        // each listing its issues. This is the only statement of what order
        // these issues came out in: the folder numbers say nothing, and the
        // magazine's own numbering restarts at 1 in each run.
        var ordered: [Int] = []
        for groups in Rx(#"\[\s*(\d+)\s*,\s*\[([\d,\s]+)\]\s*\]"#).allGroups(yearsArray) {
            for id in groups[2].split(separator: ",").compactMap({
                Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }) where raw[id] != nil {
                // Guarded because a run listing an id twice would otherwise
                // put one issue on the shelf twice.
                if !ordered.contains(id) { ordered.append(id) }
            }
        }
        guard !ordered.isEmpty else { throw IndexError.empty("the Ritam running order") }

        return ordered.enumerated().compactMap { position, id in
            guard let entry = raw[id] else { return nil }
            let parsed = RitamLabel(entry.label)
            return Entry(
                id: id,
                // This app's own counting, and it appears nowhere on the site.
                // The magazine's own numbers put four different issues at "1",
                // so they cannot order a shelf; the archive's running order
                // can, and this is it.
                number: position + 1,
                label: parsed.label,
                title: "\(PopBoks.Magazine.ritam.display) \(parsed.label)",
                year: parsed.year ?? 0,
                month: parsed.month,
                firstPage: entry.first,
                // Inclusive of both ends: a scan running pages 3 to 83 is 81
                // pages, not 80.
                pages: entry.last - entry.first + 1)
        }
    }

    /// What one Ritam label says.
    ///
    /// The labels are written for a human reading a drop-down, in half a dozen
    /// shapes:
    ///
    ///     "1 - Feb '89."               a plain issue
    ///     "6 / 7 - Jul-Avg '89."       a double, one month range
    ///     "10 / 11 - Dec '89-Jan '90." a double spanning the new year
    ///     "Godišnjak '93."             the yearbook, which has no number
    ///
    /// The first month and the first year are taken, so a double issue is
    /// filed under the month it began — which is where a reader looking for
    /// it would expect it, and which keeps the run in order.
    struct RitamLabel {
        let label: String
        let year: Int?
        let month: Int?

        /// The magazine's own abbreviations. Serbian, and not all three-letter
        /// English: "Maj", "Avg" and "Okt" are the ones that differ.
        static let months = ["jan", "feb", "mar", "apr", "maj", "jun",
                             "jul", "avg", "sep", "okt", "nov", "dec"]

        init(_ raw: String) {
            let text = raw.trimmingCharacters(in: .whitespaces)

            // Two digits after an apostrophe, and the run never leaves the
            // twentieth century — it ended in 1995.
            if let groups = Rx(#"'(\d{2})"#).firstGroups(text), let yy = Int(groups[1]) {
                year = 1900 + yy
            } else {
                year = nil
            }

            let lowered = text.lowercased()
            month = Self.months.enumerated()
                // Where each month name first appears, if it does.
                .compactMap { index, name in
                    lowered.range(of: name).map { (offset: $0.lowerBound, month: index + 1) }
                }
                // The earliest one in the string, so "Dec '89-Jan '90" is
                // December and not January.
                .min { $0.offset < $1.offset }?
                .month

            // Everything before the " - " is the issue's designation. Without
            // one — the yearbook — the designation is what precedes the year.
            let head: String
            if let dash = text.range(of: " - ") {
                head = String(text[..<dash.lowerBound])
            } else if let quote = text.range(of: "'") {
                head = String(text[..<quote.lowerBound])
            } else {
                head = text
            }
            // "6 / 7" is one designation, and reads better closed up.
            label = head
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " / ", with: "/")
        }
    }

    // MARK: - Reading the script

    /// Drops whole-line `//` comments.
    ///
    /// Not cosmetic, and not optional: `ritam.js` opens with commented-out
    /// copies of *Džuboks's* `years` and `numbers` arrays, plus a superseded
    /// version of its own `numbers`. A pattern looking for `var numbers`
    /// finds the dead one first and builds a catalogue of the wrong magazine
    /// — which decodes cleanly, seeds without complaint, and is wrong.
    ///
    /// Whole lines only. Trimming from `//` anywhere would cut every `https://`
    /// in the file in half.
    ///
    /// Split on `isNewline` rather than on `"\n"`, and that is not a
    /// refinement. Both scripts are served with CRLF endings, and Swift counts
    /// `\r\n` as a *single* `Character` — so splitting on `"\n"` finds no
    /// separator at all and hands back the whole file as one line. That line
    /// begins `//`, because the first thing in each script is a commented-out
    /// array, so the filter then discarded all 23 KB and the parse failed with
    /// "no `years` array". Džuboks survived the same bug only by luck: its
    /// live array is on line one, so the stripping that never happened was not
    /// needed. `isNewline` is true for `\r\n`, `\r`, `\n` and the Unicode
    /// separators alike.
    static func stripComments(_ script: String) -> String {
        script
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The literal assigned to `var <name>`, brackets included.
    ///
    /// Non-greedy up to the closing bracket that a `;` follows, which is the
    /// end of the statement: these literals hold plenty of nested brackets but
    /// the semicolon appears only once, at the end.
    static func array(named name: String, in source: String, opening: String) -> String? {
        let closing = opening == "[" ? "]" : "}"
        let pattern = #"var\s+"# + NSRegularExpression.escapedPattern(for: name)
                    + #"\s*=\s*("# + NSRegularExpression.escapedPattern(for: opening)
                    + #".*?"# + NSRegularExpression.escapedPattern(for: closing)
                    + #")\s*;"#
        return Rx(pattern, [.dotMatchesLineSeparators]).firstGroups(source)?[1]
    }
}
