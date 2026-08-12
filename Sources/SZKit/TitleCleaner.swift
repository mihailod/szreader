import Foundation

/// A title recovered from a mirror's filename.
public struct ParsedFilename: Equatable, Sendable {
    public let title: String?
    public let edition: String?
    public let number: Int?
}

/// Recovers `(title, edition, number)` from a download filename.
///
/// This is the fallback for `labeledBlock` posts, which carry an issue code but
/// no title — the only source of a name for those issues short of an external
/// database. Measured at 54/54 on a throttled MediaFire sample.
public enum TitleCleaner {

    private static let archiveExt = Rx(#"\.(cbr|cbz|rar|zip|7z|pdf)$"#, [.caseInsensitive])
    private static let trailingTag = Rx(#"[\s_]*[\(\[][^)\]]{1,40}[\)\]][\s_]*$"#)
    private static let separator = Rx(#"\s+[-–]\s+"#)
    private static let editionNum = Rx(#"^\s*([A-Za-zČĆŠŽĐčćšžđ]{1,6})?\s*-?\s*(\d{1,5})\s*$"#)
    private static let bareAlpha = Rx(#"^[A-Za-zČĆŠŽĐčćšžđ]{1,6}$"#)
    private static let digits = Rx(#"^\d{1,5}$"#)

    /// Handles and tags the scanners append to their filenames.
    ///
    /// A list rather than a rule because there is no shape to them: they are
    /// people's names sitting in the same underscore-separated run as the
    /// title, so nothing but recognition separates
    /// "033_Rusilacki_um_papaya_borke_72_LMS_" into a title and its credits.
    /// Trailing digits are ignored when matching, so "borke72", "bora81" and
    /// "dampyr5" are the same handles as "borke", "bora" and "dampyr".
    private static let creditWords: Set<String> = [
        "papaya", "borke", "markoboss", "enwil", "delfin", "dampyr", "drzeko",
        "folpi", "scanturion", "jeremija", "bora", "phantom", "zikateror",
        "quebrasco", "dejko", "unregistred", "rescan", "scan", "sf", "sz", "lms",
    ]

    /// Whether a token is one of those handles.
    private static func isCredit(_ token: String) -> Bool {
        let word = Fold.fold(token).trimmingCharacters(
            in: CharacterSet(charactersIn: "0123456789"))
        return !word.isEmpty && creditWords.contains(word)
    }

    public static func parse(_ filename: String) -> ParsedFilename {
        var name = filename.removingPercentEncoding ?? filename
        name = name.replacingOccurrences(of: "+", with: " ")
        name = archiveExt.replacing(name, with: "").trimmingCharacters(in: .whitespaces)

        // Strip *repeated* trailing tags:
        // "Crno zlato (Ostecene str 3 i 4)(300dpi)(drzeko & folpi)"
        while true {
            let shorter = trailingTag.replacing(name, with: "")
                .trimmingCharacters(in: .whitespaces)
            if shorter == name || shorter.isEmpty { break }
            name = shorter
        }

        var parts = split(name)
        if parts.count < 2 {
            // No " - " separators; underscores may be doing that job instead.
            parts = split(name.replacingOccurrences(of: "_", with: " "))
        }
        guard parts.count >= 2 else { return underscored(name) }

        var edition: String?
        var number: Int?
        var kept: [String] = []
        for part in parts {
            if kept.isEmpty {
                if let g = editionNum.firstGroups(part) {          // "LMS 518" / "518"
                    if !g[1].isEmpty { edition = g[1].uppercased() }
                    number = Int(g[2])
                    continue
                }
                // Bare edition code as its own token: "LMS - 521 - Hero - Title".
                // Guarded by `number == nil` so a short hero name ("Zagor") that
                // follows an already-parsed number is kept, not eaten as an edition.
                if edition == nil, number == nil, bareAlpha.matches(part) {
                    edition = part.uppercased()
                    continue
                }
            }
            kept.append(part)
        }
        // A segment that opens with a scanner's handle is theirs, not the
        // comic's. "079 - Sveti Klaus - papaya jeremija i bora81 SF i SZ"
        // otherwise reads the credits as the title, because they are last.
        let named = kept.filter { !isCredit($0.split(separator: " ").first.map(String.init) ?? "") }
        guard var title = (named.last ?? kept.last)?.trimmingCharacters(in: .whitespaces),
              !title.isEmpty else {
            return ParsedFilename(title: nil, edition: edition, number: number)
        }
        // Scanner credits are also appended with underscores rather than parens:
        // "Strah na Karibima_enwil_borke72" -> "Strah na Karibima"
        if let cut = title.firstIndex(of: "_") {
            title = String(title[..<cut]).trimmingCharacters(in: .whitespaces)
        }
        return ParsedFilename(title: title.isEmpty ? nil : title,
                              edition: edition, number: number)
    }

    /// A filename separated only by underscores, with no " - " anywhere:
    /// "Marti_Misterija_LMS_034_Misterija_i_Anabel_Li".
    ///
    /// The issue number is the landmark. What precedes it is the series and
    /// the edition code in some order, what follows is the title, and what
    /// follows *that* is the scanners — so the title is the run between the
    /// number and the first handle. Segmented names cannot be read this way:
    /// there the hero sits between the number and the title, which is why
    /// they keep their own path.
    private static func underscored(_ name: String) -> ParsedFilename {
        let tokens = name.split(whereSeparator: { $0 == "_" || $0 == " " }).map(String.init)
        guard let numberAt = tokens.firstIndex(where: { digits.matches($0) }) else {
            return ParsedFilename(title: nil, edition: nil, number: nil)
        }
        let number = Int(tokens[numberAt])
        // The token before the number, when it is a short code, is the edition.
        let edition = numberAt > 0 && bareAlpha.matches(tokens[numberAt - 1])
            ? tokens[numberAt - 1].uppercased() : nil

        let rest = tokens[tokens.index(after: numberAt)...]
        let words = Array(rest.prefix(while: { !isCredit($0) }))
        let title = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return ParsedFilename(title: title.isEmpty ? nil : title,
                              edition: edition, number: number)
    }

    private static func split(_ s: String) -> [String] {
        separator.replacing(s, with: "\u{0}")
            .components(separatedBy: "\u{0}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Tidies a title taken from post text rather than a filename.
    ///
    /// Zagor's convention writes `ZS 0418 - ZAGOR - Ulovljeni lovac (Scanturion
    /// & folpi)`, so the captured title carries a shouted hero name in front
    /// and scanner credits behind. Both hurt search and display.
    public static func tidyInline(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespaces)
        while true {
            let shorter = trailingTag.replacing(t, with: "").trimmingCharacters(in: .whitespaces)
            if shorter == t || shorter.isEmpty { break }
            t = shorter
        }
        let parts = split(t)
        // Only a single ALL-CAPS word is treated as a hero prefix. Requiring a
        // single word keeps a genuinely shouted multi-word title intact.
        if parts.count >= 2, let head = parts.first,
           !head.contains(" "), head.count >= 2, head.count <= 20,
           head == head.uppercased(), head.contains(where: \.isLetter) {
            return parts.dropFirst().joined(separator: " - ")
        }
        return t
    }

    /// Evens out the casing of a title taken from a filename.
    ///
    /// Scanners are not consistent: one release names a file
    /// "…- DIJAMANTSKA KLOPKA", the next "…- Sablast doline", so a library
    /// built from filenames shouts at random. The corpus convention is
    /// sentence case, which is what the titled pages already use.
    ///
    /// Only all-caps titles are touched. A title carrying any lowercase is the
    /// author's own casing and is left exactly as it is, so "Grupa TNT" and
    /// "Zagor Te-Nay" survive intact — which matters, because those come from
    /// page labels and are the majority.
    ///
    /// Acronyms inside an all-caps title are lowercased with everything else
    /// ("NAPAD NLO" becomes "Napad nlo"). That is deliberate: no rule
    /// separates "NLO" and "TNT" from "PAS", "SAN" and "ZUB", which are
    /// ordinary three-letter words in this corpus, and guessing wrong is more
    /// visible than being uniformly plain. An all-caps string carries no case
    /// information to preserve in the first place.
    public static func normaliseCase(_ title: String) -> String {
        guard title.contains(where: \.isLetter),
              !title.contains(where: { $0.isLowercase }) else { return title }
        var out = title.lowercased()
        if let i = out.firstIndex(where: \.isLetter) {
            out.replaceSubrange(i...i, with: out[i].uppercased())
        }
        return out
    }

    /// Rejects codes and junk while keeping genuinely short titles ("UFO").
    public static func isPlausible(_ title: String?) -> Bool {
        guard let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return false }
        let letters = t.filter(\.isLetter).count
        guard t.count >= 2, letters >= 2 else { return false }
        guard Double(letters) / Double(t.count) >= 0.5 else { return false }
        if Rx(#"^[A-Za-z]{1,6}\s*\d+$"#).matches(t) { return false }   // "LMS 518"
        let heroes: Set<String> = ["mister no", "zagor", "tex willer", "unknown", "scan"]
        return !heroes.contains(Fold.fold(t))
    }
}
