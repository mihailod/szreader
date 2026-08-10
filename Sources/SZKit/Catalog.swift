import Foundation

/// What a label tells us about an issue. Which fields are populated depends on
/// the convention: `labeledBlock` gives a code and number but no title,
/// the inline styles give a number and title, `nameFirst` adds the series name
/// and may have no title at all ("Alef 01 -").
public struct IssueLabel: Equatable, Sendable {
    public let code: String?      // "MN_LMS_511"
    public let number: Int?
    public let title: String?
    public let series: String?    // "Kolorka", "Alef"

    public init(code: String? = nil, number: Int? = nil,
                title: String? = nil, series: String? = nil) {
        self.code = code; self.number = number
        self.title = title; self.series = series
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

    static let url = Rx(#"https?://[^\s"'<>\]\)]+"#)

    /// A label instance claiming more than this many URLs is stale, not
    /// successful — the signature of an unrecognised convention, where one
    /// label silently swallows the rest of the post.
    public static let maxClaim = 4

    public static func links(in html: String) -> [LinkRecord] {
        classify(HTMLText.plainLines(html))
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
                for u in urls {
                    let before = line.components(separatedBy: u).first?
                        .trimmingCharacters(in: trimSet) ?? ""
                    // "MM_LMS_031 - http://..." puts code and URL on one line.
                    // `code` anchors to end-of-line, so without this check the
                    // previous label stays pending and swallows the block.
                    if !before.isEmpty, let g = Labels.code.firstGroups(before) {
                        instance += 1
                        out.append(.init(url: u, style: .labeledInline,
                                         label: IssueLabel(code: g[1], number: Int(g[2])),
                                         instance: instance))
                    } else if !before.isEmpty, let g = Labels.num.firstGroups(before) {
                        instance += 1
                        out.append(.init(url: u, style: .inlineSameLine,
                                         label: IssueLabel(number: Int(g[1]),
                                                           title: TitleCleaner.tidyInline(g[2])),
                                         instance: instance))
                    } else if let p = pendingNum {
                        out.append(.init(url: u, style: .inlinePrevLine,
                                         label: p.label, instance: p.instance))
                    } else if let p = pendingCode {
                        out.append(.init(url: u, style: .labeledBlock,
                                         label: p.label, instance: p.instance))
                    } else {
                        out.append(.init(url: u, style: nil, label: nil, instance: nil))
                    }
                }
                continue
            }

            // Attribute soup leaking from IPB onerror handlers is never a label.
            if line.contains("src=") || line.contains(".jpg") || line.contains("this.src") {
                continue
            }
            if let g = Labels.code.firstGroups(line) {
                instance += 1
                pendingCode = (IssueLabel(code: g[1], number: Int(g[2])), instance)
                pendingNum = nil
                continue
            }
            if let g = Labels.num.firstGroups(line),
               g[2].count > 2, !g[2].lowercased().hasPrefix("http") {
                instance += 1
                pendingNum = (IssueLabel(number: Int(g[1]),
                                         title: TitleCleaner.tidyInline(g[2])), instance)
                pendingCode = nil
                continue
            }
            if let nn = Labels.matchNameFirst(line) {
                instance += 1
                pendingNum = (IssueLabel(number: Int(nn.number), title: nn.title,
                                         series: nn.name), instance)
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
