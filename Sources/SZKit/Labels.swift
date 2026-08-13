import Foundation

/// The label conventions observed across the corpus.
///
/// Five uploader communities on the same forum, five ways of naming an issue.
/// Each was found by surveying real topic pages; none can be assumed away.
public enum LabelStyle: String, Sendable {
    /// `MN_LMS_511` alone on a line, URLs on following lines. (Mister No)
    case labeledBlock
    /// `MM_LMS_031 - <url>` — code and URL on one line. (Martin Mystere)
    case labeledInline
    /// `013-Nasilje u Darkvudu`, URL on the next line. (Zagor)
    case inlinePrevLine
    /// `001 (SSB 089/001) - Grupa TNT - <url>`. (Alan Ford)
    case inlineSameLine
    /// `Kolorka 2 Title (Author) (Date)` — name before number. (FIBRA, Alef, Asteriks)
    case nameFirst
}

enum Labels {

    // "013-Title" / "ZS 0418 - ZAGOR - Title" / "001 (SSB 089/001) - Title"
    //
    // The optional run before the separator is a hero name and the story's
    // own number, which some reprint topics carry between the collection
    // number and the title: "01 (SS 173) Johnny Logan 001 - Crni tigrovi".
    // It has to end in digits — a bare name there would swallow the first
    // half of any title written "05 (drzeko) Neki naslov - nastavak".
    static let num = Rx(
        #"^(?:[A-ZČĆŠŽĐ]{2,5}\s+)?(\d{1,4})\s*(?:\([^)]*\))?"#
        + #"(?:\s*[A-Za-zČĆŠŽĐčćšžđ][A-Za-zČĆŠŽĐčćšžđ\s]{1,30}?\s+\d{1,4})?"#
        + #"\s*[-–.]\s*(.+?)\s*$"#)

    // "MN_LMS_511", and "ZS_85 - Komadant Mark" where the code is followed by
    // the title. TN_* are cover thumbnails hotlinked from stripovi.com, not
    // labels. The title is group 3; the code and number keep their positions,
    // because callers that only want the number index by them.
    static let code = Rx(
        #"^(?!TN_)([A-ZČĆŠŽĐ][A-Z0-9ČĆŠŽĐ_]*_(\d{1,5}))(?:\s*[-–]\s*(.+?))?\s*$"#)

    // Name before number, optional title, trailing (author) (date) groups.
    private static let letter = "A-Za-zČĆŠŽĐčćšžđ"
    // Words may be joined by a dash as well as a space: Alef lists its issues
    // as "Alef - SF magazin 01 (scanners)", and a name that allows only spaces
    // stops at the first hyphen and matches nothing.
    static let nameNum = Rx(
        "^([\(letter)][\(letter)]{1,14}(?:(?:\\s+|\\s*[-–]\\s*)[\(letter)]{2,14}){0,3})"
        // The number may be introduced by a dash as well as a space: Korto
        // Malteze writes "Corto Maltese - 01 - Mladost", and a separator that
        // allows only whitespace stops at the dash and matches nothing.
        + "(?:\\s+|\\s*[-–]\\s*)(\\d{1,4})\\s*[-–_.:]?\\s*(.*)$")
    static let trailingParens = Rx(#"(?:\s*[\(\[][^)\]]*[\)\]])+\s*$"#)

    /// A trailing archive extension or a size, which describe the file rather
    /// than the comic: "… 24Mb", "… 77.43 MB", "….cbr".
    static let fileNoise = Rx(
        #"(?i)(?:\s*\.(?:cbr|cbz|rar|zip|pdf))?(?:\s*[\(\[]?\s*\d+(?:[.,]\d+)?\s*[MG]B?\s*[\)\]]?)?\s*$"#)

    /// Lines that look like labels but are forum chrome. Without this,
    /// "Posted 06 March 2011 - 09:26 PM" becomes a label and claims every
    /// link that follows it.
    static let furniture: Set<String> = [
        "posted", "edited", "brojevi", "broj", "hvala", "format", "izlazilo",
        "popular", "attached", "quote", "report", "download", "novo",
        "update", "edit", "uploader", "scan", "str", "strana", "page",
    ]

    struct NameNum { let number: String; let title: String?; let name: String }

    static func matchNameFirst(_ line: String) -> NameNum? {
        guard line.count <= 120, !line.lowercased().contains("http"),
              let g = nameNum.firstGroups(line),
              let head = g[1].split(separator: " ").first,
              !furniture.contains(head.lowercased())
        else { return nil }
        // Size and filename first, then trailing parentheses.
        //
        // Order matters: "Etiopljani (boja preklop by fantom).cbr" only has a
        // trailing bracket once the extension is gone. Without this the same
        // comic arrives twice — once plain, once with a size or filename stuck
        // to it — and the two land as separate issues because the title is
        // part of the natural key.
        let title = trailingParens
            .replacing(fileNoise.replacing(g[3], with: ""), with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–_.:"))
        return NameNum(number: g[2], title: title.isEmpty ? nil : title, name: g[1])
    }

    /// A range of issues rather than one: "Sirius 001-116 (pdf)".
    ///
    /// The same topics that label a link after it also post collected
    /// volumes — every issue as one PDF — and those read as an issue with a
    /// title beginning in digits.
    ///
    /// No spaces around the dash, which is what separates a range from a
    /// title that starts with a number: the bundles are written
    /// "Sirius 001-116 (pdf)", while issue 99 is "Sirius 099 - 900 Baka" and
    /// is a real comic that a looser rule throws away.
    private static let numericRange = Rx(#"\d+[-–]\d+"#)

    /// One issue printed as two: "Sirius 121/122 - Euroconski dvoboj".
    ///
    /// Consecutive by definition — that is what tells a double issue from a
    /// collected volume covering a hundred of them.
    static let doubleNumber = Rx(#"^(\d{1,4})\s*[/–-]\s*(\d{1,4})\b"#)

    /// The pair of numbers a double issue carries, if that is what this is.
    static func doubleIssue(in text: String) -> (first: Int, second: Int)? {
        guard let g = doubleNumber.firstGroups(text),
              let first = Int(g[1]), let second = Int(g[2]),
              second == first + 1 else { return nil }
        return (first, second)
    }

    /// A label written after its link.
    ///
    /// Nil for anything that is not clearly one issue: a bundle covering a
    /// range, or text with no number in it at all.
    static func trailingLabel(_ text: String) -> IssueLabel? {
        if let label = doubleTrailingLabel(text) { return label }
        guard !numericRange.matches(text) else { return nil }
        if let g = code.firstGroups(text) {
            let named = g.capture(3).isEmpty ? nil : TitleCleaner.tidyInline(g.capture(3))
            return IssueLabel(code: g[1], number: Int(g[2]), title: named)
        }
        if let g = num.firstGroups(text), g[2].count > 2, !g[2].lowercased().hasPrefix("http") {
            return IssueLabel(number: Int(g[1]), title: TitleCleaner.tidyInline(g[2]))
        }
        if let nn = matchNameFirst(text) {
            return IssueLabel(number: Int(nn.number), title: nn.title, series: nn.name)
        }
        // A special with no number of its own: "YU SIRIUS". Kept only when it
        // reads as a name, so the assorted notes that follow a link — sizes,
        // formats, remarks — do not each become an issue.
        let named = TitleCleaner.tidyInline(text)
        if TitleCleaner.isPlausible(named), named.count <= 40,
           !named.contains(where: \.isNumber), !furniture.contains(Fold.fold(named)) {
            return IssueLabel(title: named)
        }
        return nil
    }

    /// "Sirius 121/122 - Euroconski dvoboj" — the series, both numbers, then
    /// the title.
    ///
    /// The ordinary parse stops at the first number and leaves "/122 - …" as
    /// the title, which is how these arrived: numbered 121, named "/122 -
    /// Euroconski dvoboj", and with no cover, because the catalogue files
    /// them under both numbers at once.
    private static let secondOfPair = Rx(#"^[/–-]\s*(\d{1,4})\b"#)

    private static func doubleTrailingLabel(_ text: String) -> IssueLabel? {
        guard let nn = matchNameFirst(text), let first = Int(nn.number),
              let rest = nn.title,
              let g = secondOfPair.firstGroups(rest), let second = Int(g[1]),
              second == first + 1 else { return nil }

        let title = TitleCleaner.tidyInline(
            secondOfPair.replacing(rest, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–_.:")))
        return IssueLabel(number: first, numberTo: second,
                          title: title.isEmpty ? nil : title, series: nn.name)
    }
}
