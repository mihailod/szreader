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

    /// The same `_<number>` convention, on any host.
    ///
    /// StripZona's own scanlations are not on stripovi.com — their art is
    /// posted alongside the topic, e.g. `thumbs/strider/Dzudas/Dzudas_01.jpg`.
    /// The filename still names the issue, which beats inferring it from
    /// position, so this runs before the positional tier rather than after.
    private static let numberedImage =
        Rx(#"(https?://[^"'\s]*?_(\d{1,4})\.(?:jpe?g|png))"#, [.caseInsensitive])

    /// Issue number → cover URL, for the covers referenced by one page.
    ///
    /// Two tiers, in order of confidence:
    ///
    ///  1. the stripovi.com filename, whose trailing number names the issue
    ///     outright — exact, so it always wins;
    ///  2. failing that, the position of the images in the post.
    ///
    /// Tier 2 exists for StripZona's own scanlations. Those are not catalogued
    /// on stripovi.com, so the art is attached to the post itself and its
    /// filename says nothing about which issue it belongs to. All that is left
    /// to go on is where the image sits relative to the titles.
    public static func covers(in html: String) -> [Int: String] {
        var out = numberedCovers(in: html)
        for (number, url) in numberedCovers(in: html, pattern: numberedImage)
        where out[number] == nil {
            out[number] = url
        }
        for (number, url) in positionalCovers(in: html) where out[number] == nil {
            out[number] = url
        }
        return out
    }

    /// Tier 1: the number is in the filename.
    ///
    /// First occurrence wins: the same cover is often repeated further down a
    /// post, and the earliest is the one in the header strip.
    static func numberedCovers(in html: String, pattern: Rx? = nil) -> [Int: String] {
        var out: [Int: String] = [:]
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        (pattern ?? coverImage).re.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let url = Range(match.range(at: 1), in: html).map({ String(html[$0]) }),
                  let numberText = Range(match.range(at: 2), in: html).map({ String(html[$0]) }),
                  let number = Int(numberText) else { return }
            guard isPlausibleCover(url) else { return }
            if out[number] == nil { out[number] = https(url) }
        }
        return out
    }

    /// Forum furniture — avatars, smilies, rank pips, spacers. These outnumber
    /// the real covers on a busy topic, so without this the first thing every
    /// issue gets is an emoticon.
    private static let furniture = [
        "style_emoticons", "style_images", "style_avatars", "avatar", "smilie",
        "emoticon", "spacer", "blank.", "logo", "banner", "icon", "rating",
        "pip.", "bullet", "arrow", "quote", "profile", "signature",
    ]

    /// Covers are photographs; furniture is overwhelmingly GIF.
    private static let coverExtensions = [".jpg", ".jpeg", ".png", ".webp"]

    static func isPlausibleCover(_ url: String) -> Bool {
        let lower = url.lowercased()
        guard coverExtensions.contains(where: { lower.contains($0) }) else { return false }
        return !furniture.contains(where: lower.contains)
    }

    /// Tier 2: match images to issues by position.
    ///
    /// Deliberately direction-agnostic. Posts put the art above the title as
    /// often as below it, and both readings are natural, so an image is taken
    /// by the nearest title on either side rather than by an assumed layout.
    /// A window keeps that from reaching across the whole post: an image with
    /// no title near it belongs to no issue.
    static func positionalCovers(in html: String) -> [Int: String] {
        var out: [Int: String] = [:]
        var unclaimed: String?          // image seen before its title
        var awaiting: Int?              // title still without an image
        var distance = 0
        let window = 4

        for line in HTMLText.plainLines(html, keepingImages: true) {
            if let url = HTMLText.markedImage(line) {
                guard isPlausibleCover(url) else { continue }
                if let number = awaiting, distance <= window, out[number] == nil {
                    out[number] = https(url)    // art below its title
                    awaiting = nil
                } else {
                    unclaimed = url
                    distance = 0
                }
            } else if let number = label(in: line) {
                if out[number] == nil, distance <= window, let url = unclaimed {
                    out[number] = https(url)    // art above its title
                }
                unclaimed = nil
                awaiting = number
                distance = 0
            } else {
                distance += 1
            }
        }
        return out
    }

    private static func label(in line: String) -> Int? {
        if let g = Labels.num.firstGroups(line), let n = Int(g[1]) { return n }
        if let g = Labels.code.firstGroups(line), let n = Int(g[2]) { return n }
        return nil
    }

    /// stripovi.com 301s every http image to https, so an http URL costs two
    /// round-trips per cover — 240 requests for a 120-issue page before
    /// anything appears. Normalise once, here.
    private static func https(_ url: String) -> String {
        url.replacingOccurrences(of: "http://", with: "https://")
    }
}
