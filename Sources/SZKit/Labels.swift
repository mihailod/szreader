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
    static let num = Rx(#"^(?:[A-ZČĆŠŽĐ]{2,5}\s+)?(\d{1,4})\s*(?:\([^)]*\))?\s*[-–.]\s*(.+?)\s*$"#)

    // "MN_LMS_511". TN_* are cover thumbnails hotlinked from stripovi.com, not labels.
    static let code = Rx(#"^(?!TN_)([A-ZČĆŠŽĐ][A-Z0-9ČĆŠŽĐ_]*_(\d{1,5}))$"#)

    // Name before number, optional title, trailing (author) (date) groups.
    private static let letter = "A-Za-zČĆŠŽĐčćšžđ"
    // Words may be joined by a dash as well as a space: Alef lists its issues
    // as "Alef - SF magazin 01 (scanners)", and a name that allows only spaces
    // stops at the first hyphen and matches nothing.
    static let nameNum = Rx(
        "^([\(letter)][\(letter)]{1,14}(?:(?:\\s+|\\s*[-–]\\s*)[\(letter)]{2,14}){0,3})"
        + "\\s+(\\d{1,4})\\s*[-–_.:]?\\s*(.*)$")
    static let trailingParens = Rx(#"(?:\s*[\(\[][^)\]]*[\)\]])+\s*$"#)

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
        let title = trailingParens
            .replacing(g[3], with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–_.:"))
        return NameNum(number: g[2], title: title.isEmpty ? nil : title, name: g[1])
    }
}
