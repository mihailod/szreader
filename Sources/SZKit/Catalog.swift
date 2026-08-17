import Foundation

/// The number another edition files this issue under, mentioned in passing.
///
/// A reprint topic numbers its issues from one and names the original beside
/// each: "01 (SS 173) Johnny Logan 001 - Crni tigrovi" is issue 1 here and
/// Super Strip 173 there. A topic carrying a single issue says it in its own
/// heading: "Timothy Tatcher 02 Hollywood protiv mene (SS 305)".
///
/// Worth keeping rather than reading and dropping, because the catalogue's
/// artwork is named after *this* number — `TT_SS_305.jpg` — while the number
/// the row carries names nothing there.
public struct CatalogueRef: Equatable, Sendable {
    /// The other edition, as the label shouts it: "SS".
    public let code: String
    /// Its number for this issue: 305.
    public let number: Int

    public init(code: String, number: Int) {
        self.code = code; self.number = number
    }
}

/// What a label tells us about an issue. Which fields are populated depends on
/// the convention: `labeledBlock` gives a code and number but no title,
/// the inline styles give a number and title, `nameFirst` adds the series name
/// and may have no title at all ("Alef 01 -").
public struct IssueLabel: Equatable, Sendable {
    public let code: String?      // "MN_LMS_511"
    public let number: Int?
    /// The far end of a double issue — one magazine printed as "121/122".
    /// Nil for the ordinary case.
    public let numberTo: Int?
    public let title: String?
    public let series: String?    // "Kolorka", "Alef"
    /// Where another edition files the same issue, where the label says.
    public let catalogue: CatalogueRef?

    public init(code: String? = nil, number: Int? = nil, numberTo: Int? = nil,
                title: String? = nil, series: String? = nil,
                catalogue: CatalogueRef? = nil) {
        self.code = code; self.number = number; self.numberTo = numberTo
        self.title = title; self.series = series
        self.catalogue = catalogue
    }

    /// The same label, carrying the catalogue reference its own text gives.
    ///
    /// Applied where the label is built rather than inside each parse, because
    /// every style strips the bracket on its way to a title and only the line
    /// it came from still has it.
    func reading(_ text: String) -> IssueLabel {
        guard catalogue == nil, let ref = Labels.catalogueRef(in: text) else { return self }
        return IssueLabel(code: code, number: number, numberTo: numberTo,
                          title: title, series: series, catalogue: ref)
    }

    /// Whether a number is the only thing identifying this issue.
    ///
    /// Such a label says nothing that tells it from the same number in
    /// another topic, and the natural key is exactly those fields — so two
    /// bare-number topics collide row for row. Ken Parker's list runs 1…79
    /// and Erotski Roman's 1…184; imported together the second lost its first
    /// seventy-nine issues without a word, because `INSERT OR IGNORE` found
    /// ('', 1, '', '') already there.
    var isBareNumber: Bool {
        code == nil && title == nil && series == nil && number != nil
    }

    /// The same label with the topic's name standing in for the missing
    /// series, so it has something of its own in the key.
    func qualified(by edition: String?) -> IssueLabel {
        guard isBareNumber, let edition, !edition.isEmpty else { return self }
        return IssueLabel(code: code, number: number, numberTo: numberTo,
                          title: title, series: edition, catalogue: catalogue)
    }
}

/// One download link, and the label it was attributed to.
public struct LinkRecord: Equatable, Sendable {
    public let url: String
    public let style: LabelStyle?     // nil when nothing claimed it
    public let label: IssueLabel?
    public let instance: Int?         // which label occurrence claimed it
}

/// An issue with its mirrors, assembled from the links one label claimed.
public struct ParsedIssue: Equatable, Sendable {
    public let label: IssueLabel
    public let style: LabelStyle
    public let mirrors: [MirrorLink]
}

public struct MirrorLink: Equatable, Sendable {
    public let url: String
    public let host: String
    public let ordinal: Int       // 0 = primary, 1 = "drugi sken", ...
}

/// Coverage of one page. `attributed` deliberately excludes `suspect`.
public struct Coverage: Equatable, Sendable {
    public let total: Int
    public let attributed: Int
    public let unattributed: Int
    public let suspect: Int
}

public enum Catalog {

    /// Page furniture, not comic downloads.
    static let noise = [
        "stripzona.com", "stripovi.com", "invisionpower.com", "ibskin.com",
        "gravatar.com", "schema.org", "data-vocabulary.org", "googlesyndication",
        "google-analytics", "facebook.com", "twitter.com", "youtube.com",
        "doubleclick", "adsbygoogle", "w3.org", "mozilla.org",
    ]

    /// Inline cover/preview images posted in the body. Counting these as
    /// downloads inflated the corpus and faked "new conventions".
    static let imageHosts = [
        "postimg.cc", "postimg.org", "tinypic.com", "imageshack.us",
        "imgur.com", "imagevenue", "imagebam", "servimg.com",
        "photobucket", "ibb.co", "picpaste", "slika.rs",
    ]

    /// A URL, allowing balanced parentheses inside it.
    ///
    /// Scanners put their handles in the filename — ".../LMS+0144+-+Veliki+
    /// Blek+-Tragican+lov(enwil-rescan_2014)-SZ.cbr" — and a pattern that
    /// simply excludes ")" stops at the closing bracket. That left the link
    /// truncated and, worse, handed the remainder ")-SZ.cbr" to the trailing
    /// label reader, which made an issue of it: a row with no number called
    /// ")-SZ.cbr" holding the two links it stole.
    ///
    /// A lone ")" still ends the URL, because the alternation only accepts a
    /// bracket that opens a group — so "(see https://example.com)" is
    /// unaffected.
    static let url = Rx(#"https?://(?:[^\s"'<>\]()]|\([^\s"'<>()]*\))+"#)

    /// A label instance claiming more than this many URLs is stale, not
    /// successful — the signature of an unrecognised convention, where one
    /// label silently swallows the rest of the post.
    public static let maxClaim = 4

    /// A post offering a replacement link for something already listed.
    ///
    /// "Novi link za obradu: SSB 494 - Timothy Tatcher 02 - Hollywood protiv
    /// mene" — a re-upload of an issue the topic has already published, added
    /// months later when the original died. It names the issue by its Super
    /// Strip Biblioteka number, so the parser read 494 as an issue of its own
    /// and invented one: a third Timothy Tatcher on a topic that has two, with
    /// a dead link and a number belonging to another edition entirely.
    ///
    /// Dropped whole, the URL with it. Attributing the link to the issue it
    /// actually replaces would be better, but that means resolving "SSB 494"
    /// against an issue this topic numbers 02 — and a wrong guess there hands
    /// a working comic somebody else's download.
    private static let reupload = Rx(#"(?i)^\s*novi\s+link\b"#)

    /// Everything a re-upload announcement covers: the notice, the line naming
    /// what it replaces, and the link itself.
    ///
    /// Three lines, because that is how the post is written and how
    /// `plainLines` hands it over — filtering the notice alone leaves the
    /// name behind, which is the line that became an issue.
    ///
    /// Anchored to the start of the line so the phrase has to be the post's
    /// opening claim. It appears mid-sentence elsewhere on this very page —
    /// someone asking a colleague to post a new link — and that is prose, not
    /// an announcement.
    static func withoutReuploads(_ lines: [String]) -> [String] {
        var kept: [String] = []
        var index = 0
        while index < lines.count {
            guard reupload.matches(lines[index]) else {
                kept.append(lines[index]); index += 1; continue
            }
            index += 1                                   // the notice
            if index < lines.count { index += 1 }        // what it replaces
            // Its links. More than one is a split archive, and dropping half
            // of one is worse than dropping all of it.
            while index < lines.count, url.matches(lines[index]) { index += 1 }
        }
        return kept
    }

    public static func links(in html: String) -> [LinkRecord] {
        classify(withoutReuploads(HTMLText.plainLines(html)))
    }

    /// Attribute each download link to the label that owns it.
    ///
    /// Rule: a label owns every URL until the *next* label appears. Line
    /// distance is a bad proxy — three lines is too strict for labeled-block
    /// posts and too loose for dense lists.
    static func classify(_ lines: [String]) -> [LinkRecord] {
        var out: [LinkRecord] = []
        // Only one of these is ever non-nil; they are kept apart because the
        // style recorded on the link differs (prev-line vs labeled block).
        var pendingNum: (label: IssueLabel, instance: Int)?
        var pendingCode: (label: IssueLabel, instance: Int)?
        var instance = 0
        let trimSet = CharacterSet(charactersIn: " -–|.")

        for line in lines {
            var urls = url.allMatches(line).filter { u in
                !noise.contains(where: u.contains) && !imageHosts.contains(where: u.contains)
            }
            urls = Array(NSOrderedSet(array: urls)) as? [String] ?? urls

            if !urls.isEmpty {
                // One label for the whole line, taken from the text in front
                // of the *first* link.
                //
                // A line often carries several links for one issue: "01. Bob
                // Moran: <a> [181 MB] + <b> [143 MB]". Reading the text before
                // each link in turn made the second one's label "Bob Moran:
                // http://…[181.20 MB] +" — a different title for the same
                // number, so the issue was imported twice.
                let before = line.components(separatedBy: urls[0]).first?
                    .trimmingCharacters(in: trimSet) ?? ""

                // Some topics write the label after the link instead:
                // "http://…?7wdy… - Sirius 001 - Ne ubijte Rulla". Only when
                // nothing precedes the first link, so a line that labels
                // itself in front — and may carry sizes after its links —
                // keeps reading the way it always did.
                let after = before.isEmpty
                    ? line.components(separatedBy: urls[urls.count - 1]).last?
                        .trimmingCharacters(in: trimSet) ?? ""
                    : ""

                let style: LabelStyle?
                let label: IssueLabel?
                let stamp: Int?
                // "MM_LMS_031 - http://..." puts code and URL on one line.
                // `code` anchors to end-of-line, so without this check the
                // previous label stays pending and swallows the block.
                if !before.isEmpty, let g = Labels.code.firstGroups(before) {
                    instance += 1
                    let named = g.capture(3).isEmpty ? nil : TitleCleaner.tidyInline(g.capture(3))
                    style = .labeledInline
                    label = IssueLabel(code: g[1], number: Int(g[2]), title: named)
                        .reading(before)
                    stamp = instance
                } else if !before.isEmpty, let g = Labels.num.firstGroups(before) {
                    instance += 1
                    style = .inlineSameLine
                    label = IssueLabel(number: Int(g[1]), title: TitleCleaner.tidyInline(g[2]))
                        .reading(before)
                    stamp = instance
                } else if !before.isEmpty, let g = Labels.bareNumber.firstGroups(before),
                          let n = Int(g[1]), n > 0 {
                    // "01 <url>" — the number is the whole label.
                    instance += 1
                    style = .inlineSameLine
                    label = IssueLabel(number: n, title: nil)
                    stamp = instance
                } else if !after.isEmpty, let trailing = Labels.trailingLabel(after),
                          // A trailing label with no number of its own is the
                          // weakest thing here: it is whatever words followed
                          // the link. It must not displace a numbered label
                          // still waiting from the line above — "LMS 349 -
                          // Okovani Blek" lost its issue to the note "cijeli
                          // strip" written after its link, so 349 vanished and
                          // an issue called "cijeli strip" took its download.
                          trailing.number != nil || (pendingNum == nil && pendingCode == nil) {
                    instance += 1
                    style = .inlineSameLine
                    label = trailing
                    stamp = instance
                } else if let p = pendingNum {
                    style = .inlinePrevLine
                    label = p.label
                    stamp = p.instance
                } else if let p = pendingCode {
                    style = .labeledBlock
                    label = p.label
                    stamp = p.instance
                } else {
                    style = nil
                    label = nil
                    stamp = nil
                }

                // Every link on the line is a way of getting the same issue.
                for u in urls {
                    out.append(.init(url: u, style: style, label: label, instance: stamp))
                }
                continue
            }

            // Attribute soup leaking from IPB onerror handlers is never a label.
            if line.contains("src=") || line.contains(".jpg") || line.contains("this.src") {
                continue
            }
            if let g = Labels.code.firstGroups(line) {
                instance += 1
                // Some topics write the title beside the code rather than
                // leaving the issue nameless: "ZS_85 - Komadant Mark".
                let named = g.capture(3).isEmpty ? nil : TitleCleaner.tidyInline(g.capture(3))
                pendingCode = (IssueLabel(code: g[1], number: Int(g[2]), title: named)
                                .reading(line), instance)
                pendingNum = nil
                continue
            }
            // A run of issues named as a range is a summary, not a label:
            // Erotski Roman closes each post with "151.-160.", which read as
            // issue 151 titled "-160." and then claimed the next link it
            // found — the bundle covering all ten — so issue 151 appeared
            // twice, once with its own scan and once with the whole decade.
            if Labels.isNumericRange(line) { continue }
            if let g = Labels.num.firstGroups(line),
               g[2].count > 2, !g[2].lowercased().hasPrefix("http") {
                instance += 1
                pendingNum = (IssueLabel(number: Int(g[1]),
                                         title: TitleCleaner.tidyInline(g[2]))
                                .reading(line), instance)
                pendingCode = nil
                continue
            }
            if let nn = Labels.matchNameFirst(line) {
                instance += 1
                pendingNum = (IssueLabel(number: Int(nn.number), title: nn.title,
                                         series: nn.name).reading(line), instance)
                pendingCode = nil
            }
        }
        return out
    }

    /// Issues with their mirrors, ready to store.
    ///
    /// Deliberately drops both unattributed links and any label instance that
    /// claimed more than `maxClaim` mirrors. A stale label produces plausible
    /// but *wrong* titles, and a wrong title in the library is worse than a
    /// missing one — you tap "Zagorova pravda" and get a different comic.
    public static func issues(in html: String) -> [ParsedIssue] {
        let records = links(in: html)
        var claims: [Int: Int] = [:]
        for r in records { if let i = r.instance { claims[i, default: 0] += 1 } }

        var order: [Int] = []
        var grouped: [Int: [LinkRecord]] = [:]
        for r in records {
            guard let i = r.instance, (claims[i] ?? 0) <= maxClaim, r.label != nil else { continue }
            if grouped[i] == nil { order.append(i) }
            grouped[i, default: []].append(r)
        }

        return order.compactMap { i in
            guard let group = grouped[i], let first = group.first,
                  let label = first.label, let style = first.style else { return nil }
            let mirrors = group.enumerated().map { idx, r in
                MirrorLink(url: r.url, host: host(of: r.url), ordinal: idx)
            }
            return ParsedIssue(label: label, style: style, mirrors: mirrors)
        }
    }

    static func host(of url: String) -> String {
        guard let h = URL(string: url)?.host?.lowercased() else { return "?" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    public static func coverage(_ records: [LinkRecord]) -> Coverage {
        var claims: [Int: Int] = [:]
        for r in records { if let i = r.instance { claims[i, default: 0] += 1 } }
        let suspect = records.filter { ($0.instance.map { claims[$0] ?? 0 } ?? 0) > maxClaim }.count
        let none = records.filter { $0.style == nil }.count
        return Coverage(total: records.count,
                        attributed: records.count - none - suspect,
                        unattributed: none,
                        suspect: suspect)
    }
}
