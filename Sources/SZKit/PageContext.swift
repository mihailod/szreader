import Foundation

/// Where a topic sits in the forum, which is where the publisher, hero and
/// edition actually live.
///
/// None of this is in the post body — it is in the page title and the
/// breadcrumb trail, both of which the parser previously threw away. Without
/// it you can only search issue titles, so "zagor", "bonelli", "zlatna serija"
/// and "fibra" all find nothing.
///
///     <title>   Zagor - ZLATNA SERIJA - ZS i LMS - Stripzona
///     crumbs    Stripzona > STRIPOVI NA EX-YU JEZICIMA > BONELLI
///                         > Zagor Te-Nay > ZS i LMS
public struct PageContext: Equatable, Sendable {
    /// Topic name, e.g. "Zagor - ZLATNA SERIJA".
    public let topic: String?
    /// Forum path from the site root downwards, site name dropped.
    public let trail: [String]

    public init(topic: String?, trail: [String]) {
        self.topic = topic
        self.trail = trail
    }

    /// Everything, for the search index.
    public var searchableText: String {
        ([topic].compactMap { $0 } + trail).joined(separator: " ")
    }

    /// Best guess at the hero/series forum — the last crumb before the leaf is
    /// usually the character ("Zagor Te-Nay", "Alan Ford").
    public var hero: String? {
        trail.count >= 2 ? trail[trail.count - 2] : trail.last
    }

    /// Best guess at the publisher grouping ("BONELLI", "Magnus - Bunker").
    public var publisher: String? {
        trail.count >= 3 ? trail[trail.count - 3] : nil
    }

    public static let empty = PageContext(topic: nil, trail: [])
}

extension Catalog {

    private static let titleTag = Rx(#"(?is)<title>(.*?)</title>"#)
    // IPB 3.4 marks breadcrumb entries with data-vocabulary's itemprop="title".
    private static let crumb = Rx(#"itemprop=['"]title['"][^>]*>([^<]{1,60})<"#)
    private static let crumbFallback = Rx(#"(?is)<span itemprop=["']name["']>([^<]{1,60})</span>"#)

    /// Site name, and the section header every topic sits under — present on
    /// every page, so they add nothing but noise to the index.
    ///
    /// Stored pre-folded, because that is what they are compared against:
    /// `Fold` turns "EX-YU" into "ex yu", so a hyphenated literal here would
    /// silently never match.
    private static let ignoredCrumbs: Set<String> = [
        "stripzona", "stripovi na ex yu jezicima", "forums", "forum",
    ].map(Fold.fold).reduce(into: Set<String>()) { $0.insert($1) }

    public static func pageContext(in html: String) -> PageContext {
        var topic: String?
        if let g = titleTag.firstGroups(html) {
            var t = HTMLText.decodeEntities(g[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Titles end "... - <Forum> - Stripzona"; the trail covers the rest.
            for suffix in [" - Stripzona", " – Stripzona"] where t.hasSuffix(suffix) {
                t = String(t.dropLast(suffix.count))
            }
            topic = t.isEmpty ? nil : t
        }

        var raw = crumb.allMatches(html, group: 1)
        if raw.isEmpty { raw = crumbFallback.allMatches(html, group: 1) }
        let trail = raw
            .map { HTMLText.decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !ignoredCrumbs.contains(Fold.fold($0)) }

        return PageContext(topic: topic, trail: trail)
    }
}

extension Catalog {

    // Topic pages hotlink cover thumbnails from stripovi.com, named
    // TN_<HERO>_<EDITION>_<NUMBER>.jpg — so the trailing number ties a cover to
    // an issue without any extra lookup.
    private static let coverImage =
        Rx(#"(https?://[^"'\s]*naslovnice/[^"'\s]*?_(\d{1,4})\.jpe?g)"#, [.caseInsensitive])

    /// Issue number → cover URL, for the covers referenced by one page.
    ///
    /// First occurrence wins: the same cover is often repeated further down a
    /// post, and the earliest is the one in the header strip.
    public static func covers(in html: String) -> [Int: String] {
        var out: [Int: String] = [:]
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        coverImage.re.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let url = Range(match.range(at: 1), in: html).map({ String(html[$0]) }),
                  let numberText = Range(match.range(at: 2), in: html).map({ String(html[$0]) }),
                  let number = Int(numberText) else { return }
            if out[number] == nil { out[number] = url }
        }
        return out
    }
}
