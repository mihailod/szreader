import Foundation

/// Flattens forum HTML into the visible lines the parsers work on.
public enum HTMLText {

    // Matches a tag even when an attribute value contains '>' — IPB's onerror
    // handlers do (`onerror='...indexOf(x)>-1...'`), and a naive <[^>]+> splits
    // mid-tag, leaking attribute soup into the text.
    private static let tag = Rx(#"<[a-zA-Z/!][^>"']*(?:"[^"]*"[^>"']*|'[^']*'[^>"']*)*>"#)
    private static let scriptStyle = Rx(#"<(script|style)[\s\S]*?</\1>"#, [.caseInsensitive])
    private static let inlineTag = Rx(
        #"</?(?:a|b|strong|i|em|u|span|font|small|big|sub|sup|code|tt|s|strike|mark|abbr)(?:\s[^>]*?)?>"#,
        [.caseInsensitive])
    private static let anchor = Rx(
        #"<a\s[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, [.caseInsensitive])

    /// Visible lines, in document order.
    ///
    /// Two steps are load-bearing and were each found the hard way:
    ///
    /// * **Entity unescaping.** IPB writes `http&#58;//www.mediafire.com/...`,
    ///   so a URL regex over the raw source matches nothing at all.
    /// * **Inline tags are deleted, block tags become newlines.** Turning every
    ///   tag into a newline shreds `<b>Orka specijal 1</b> - <i>Eternaut</i>`
    ///   into four "lines" and destroys the label-to-title relationship.
    public static func plainLines(_ html: String) -> [String] {
        var s = scriptStyle.replacing(html, with: " ")
        // Anchors first, as insurance: if a post ever hyperlinks a title rather
        // than pasting a bare URL, dropping <a> with the other inline tags would
        // lose the href. Unproven on the current corpus — every download link
        // observed so far is bare text — but it costs nothing.
        s = anchor.replacing(s, with: " $2 $1 ")
        s = inlineTag.replacing(s, with: "")
        s = tag.replacing(s, with: "\n")
        return decodeEntities(s)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "hellip": "…", "ndash": "–", "mdash": "—",
        "lsquo": "'", "rsquo": "'", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            rest = rest[amp...]
            // An entity is short; scanning further means it was a bare '&'.
            guard let semi = rest.prefix(12).firstIndex(of: ";") else {
                out.append("&")
                rest = rest.dropFirst()
                continue
            }
            let body = rest[rest.index(after: amp)..<semi]
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let scalar: UInt32? = digits.hasPrefix("x") || digits.hasPrefix("X")
                    ? UInt32(digits.dropFirst(), radix: 16)
                    : UInt32(digits, radix: 10)
                if let v = scalar, let u = Unicode.Scalar(v) {
                    out.unicodeScalars.append(u)
                } else {
                    out += "&\(body);"
                }
            } else if let rep = named[String(body).lowercased()] {
                out += rep
            } else {
                out += "&\(body);"
            }
            rest = rest[rest.index(after: semi)...]
        }
        out += rest
        return out
    }
}
