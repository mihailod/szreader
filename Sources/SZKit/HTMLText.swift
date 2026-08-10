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
    /// Marks an image's place in the line sequence. A sentinel rather than a
    /// separate pass, because what matters about a scanlation's cover art is
    /// *where it sits relative to the titles around it* — extract the images
    /// separately and that ordering is exactly what you throw away.
    static let imageMarker = "\u{1}IMG:"

    /// Quote-aware, because IPB writes `onload='... indexOf("x") > 0'` — a
    /// literal `>` inside an attribute value. A plain `[^>]*` ends the tag
    /// there, before ever reaching `src`, and silently finds no images at all.
    private static let imgTag =
        Rx(#"(?is)<img(?:[^>"']|"[^"]*"|'[^']*')*>"#)

    /// `src` on the tag itself. `this.src="..."` inside the onerror handler is
    /// preceded by a dot rather than whitespace, so it is not mistaken for it.
    private static let srcAttr = Rx(#"(?is)\ssrc\s*=\s*(["'])(.*?)\1"#)

    /// Rewrites each `<img>` to a marker line carrying its src, dropping tags
    /// that have no usable src.
    private static func replaceImages(in html: String) -> String {
        let ns = html as NSString
        var out = ""
        var cursor = 0
        for m in imgTag.re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let tag = ns.substring(with: m.range)
            if let g = srcAttr.firstGroups(tag) {
                out += "\n" + imageMarker + g[2] + "\n"
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// The image URL a marker line carries, or nil for an ordinary line.
    static func markedImage(_ line: String) -> String? {
        line.hasPrefix(imageMarker) ? String(line.dropFirst(imageMarker.count)) : nil
    }

    public static func plainLines(_ html: String) -> [String] {
        plainLines(html, keepingImages: false)
    }

    static func plainLines(_ html: String, keepingImages: Bool) -> [String] {
        var s = scriptStyle.replacing(html, with: " ")
        if keepingImages {
            // Before the tag strippers run, so the src survives as plain text
            // on its own line and keeps its position among the titles.
            s = replaceImages(in: s)
        }
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
