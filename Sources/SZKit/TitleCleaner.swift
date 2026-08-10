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
    private static let trailingTag = Rx(#"\s*[\(\[][^)\]]{1,40}[\)\]]\s*$"#)
    private static let separator = Rx(#"\s+[-–]\s+"#)
    private static let editionNum = Rx(#"^\s*([A-Za-zČĆŠŽĐčćšžđ]{1,6})?\s*-?\s*(\d{1,5})\s*$"#)
    private static let bareAlpha = Rx(#"^[A-Za-zČĆŠŽĐčćšžđ]{1,6}$"#)

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
        guard parts.count >= 2 else { return ParsedFilename(title: nil, edition: nil, number: nil) }

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
        guard var title = kept.last?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
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
