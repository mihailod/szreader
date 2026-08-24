import Foundation

/// Atarimania's magazine archive: 85 titles of scanned Atari press, served as
/// ordinary PDFs.
///
/// The whole Atari 8-bit press lives here and nowhere else the app already
/// reaches — Antic, Page 6, STart, Atari User — alongside the ST magazines and
/// a long run of US user-group newsletters. BombJack's Atari holdings are nine
/// ST titles; archive.org has the ANALOG/SoftSide side but almost none of the
/// 8-bit magazines.
///
/// Shape is RetroSpec's: an index page naming every title, a page per title
/// listing its issues, and one direct PDF per issue. What it does *not* have
/// is a derivable filename — Antic files issue 1 as `Antic_Vol_1_No_1.pdf` and
/// ANALOG files its own as `analog_no_01.pdf` — so the build reads each href
/// rather than generating it.
public enum Atarimania {

    /// Everything below hangs off this. Stored once in the catalogue.
    public static let base = "https://www.atarimania.com/"

    /// The index of titles.
    public static let indexPath = "magazines"

    /// One issue, as its title's page describes it.
    public struct Entry: Equatable, Sendable {
        /// Path to the scan, relative to `base`: "mags/pdf/Antic_Vol_1_No_1.pdf".
        public let pdf: String
        /// Path to the cover thumbnail, relative to `base`. The site shows one
        /// per issue and it is the only artwork available — there is no
        /// full-size cover to hotlink.
        public let cover: String?
        /// How the page labels it: "Vol. 1 - No. 01", "Issue 01", or "01".
        public let label: String
        public let year: Int?
        public let month: Int?

        public init(pdf: String, cover: String?, label: String,
                    year: Int?, month: Int?) {
            self.pdf = pdf; self.cover = cover; self.label = label
            self.year = year; self.month = month
        }

        /// The filename without extension, which is the only thing about an
        /// issue that is unique across the whole site — two magazines both
        /// have an "Issue 01".
        public var stem: String {
            (pdf as NSString).lastPathComponent
                .replacingOccurrences(of: ".pdf", with: "")
        }
    }

    // MARK: - The index

    private static let magazineHref = Rx(#"(?i)href="[^"]*/magazines/(\d+)""#)

    /// Every title's id, in the order the index lists them.
    public static func magazineIDs(in html: String) -> [Int] {
        var seen: Set<Int> = []
        var out: [Int] = []
        for groups in magazineHref.allGroups(html) {
            guard groups.count > 1, let id = Int(groups[1]), seen.insert(id).inserted
            else { continue }
            out.append(id)
        }
        return out
    }

    // MARK: - One title

    private static let heading = Rx(#"(?is)<h1[^>]*>(.*?)</h1>"#)
    private static let tag = Rx(#"<[^>]+>"#)

    /// What the title's page calls it.
    public static func name(in html: String) -> String? {
        guard let groups = heading.firstGroups(html), groups.count > 1 else { return nil }
        let text = tag.replacing(groups[1], with: " ")
        let clean = HTMLText.decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private static let pdfHref = Rx(#"(?i)href="[^"]*/mags/pdf/([^"]+\.pdf)""#)
    private static let coverSrc = Rx(#"(?i)src="[^"]*/mags/low_res/([^"?]+)"#)
    private static let paragraph = Rx(#"(?is)<p[^>]*>(.*?)</p>"#)

    /// Every issue on one title's page.
    ///
    /// Split on `<li` rather than on the class the site happens to put there.
    /// This is a rendered React page whose class names are Tailwind soup
    /// (`class="flex flex-col"`), and anchoring a parse to those is anchoring
    /// it to a redesign. The list item, the PDF href and the order of the two
    /// captions are the parts that mean something.
    public static func issues(in html: String) -> [Entry] {
        var out: [Entry] = []
        for chunk in html.components(separatedBy: "<li").dropFirst() {
            guard let pdfGroups = pdfHref.firstGroups(chunk), pdfGroups.count > 1
            else { continue }

            // Two captions in order: the issue's label, then its date. Read by
            // position because that is what the page guarantees; the classes
            // that currently distinguish them are presentation.
            let captions = paragraph.allGroups(chunk).compactMap { groups -> String? in
                guard groups.count > 1 else { return nil }
                let text = HTMLText.decodeEntities(tag.replacing(groups[1], with: " "))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            let cover = coverSrc.firstGroups(chunk).flatMap { $0.count > 1 ? $0[1] : nil }
            let (year, month) = date(in: captions.count > 1 ? captions[1] : "")

            out.append(Entry(pdf: "mags/pdf/" + pdfGroups[1],
                             cover: cover.map { "mags/low_res/" + $0 },
                             label: captions.first ?? "",
                             year: year, month: month))
        }
        return out
    }

    // MARK: - Dates

    static let monthNames = ["january", "february", "march", "april", "may", "june",
                             "july", "august", "september", "october", "november",
                             "december"]

    private static let year4 = Rx(#"(\d{4})"#)

    /// The year and month a caption states.
    ///
    /// Three shapes, all of them real: "April - 1982", "January / February -
    /// 1981" for a bi-monthly, and a bare "1983" where the scanner recorded no
    /// month. A double month keeps the first — that is the issue's own cover
    /// date, and it is what sorts a run correctly.
    public static func date(in caption: String) -> (year: Int?, month: Int?) {
        let lower = caption.lowercased()
        let year = year4.firstGroups(lower).flatMap { $0.count > 1 ? Int($0[1]) : nil }

        // Earliest-appearing month name wins, so "December / January" is
        // December rather than whichever the table happens to list first.
        var best: (Int, Int)?
        for (index, name) in monthNames.enumerated() {
            guard let found = lower.range(of: name) else { continue }
            let at = lower.distance(from: lower.startIndex, to: found.lowerBound)
            if best == nil || at < best!.0 { best = (at, index + 1) }
        }
        return (year, best?.1)
    }
}
