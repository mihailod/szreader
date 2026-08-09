import Foundation

/// One download link, and the label it was attributed to.
public struct LinkRecord: Equatable, Sendable {
    public let url: String
    public let style: LabelStyle?     // nil when nothing claimed it
    public let label: String?
    public let instance: Int?         // which label occurrence claimed it
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
        var pendingNum: (title: String, instance: Int)?
        var pendingCode: (code: String, instance: Int)?
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
                                         label: g[1], instance: instance))
                    } else if !before.isEmpty, let g = Labels.num.firstGroups(before) {
                        instance += 1
                        out.append(.init(url: u, style: .inlineSameLine,
                                         label: g[2], instance: instance))
                    } else if let p = pendingNum {
                        out.append(.init(url: u, style: .inlinePrevLine,
                                         label: p.title, instance: p.instance))
                    } else if let p = pendingCode {
                        out.append(.init(url: u, style: .labeledBlock,
                                         label: p.code, instance: p.instance))
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
                pendingCode = (g[1], instance); pendingNum = nil
                continue
            }
            if let g = Labels.num.firstGroups(line),
               g[2].count > 2, !g[2].lowercased().hasPrefix("http") {
                instance += 1
                pendingNum = (g[2], instance); pendingCode = nil
                continue
            }
            if let nn = Labels.matchNameFirst(line) {
                instance += 1
                pendingNum = (nn.title ?? "\(nn.name) \(nn.number)", instance)
                pendingCode = nil
            }
        }
        return out
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
