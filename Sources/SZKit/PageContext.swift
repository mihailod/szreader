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

    /// The character the topic sits under — the *last* crumb.
    ///
    /// This used to take the crumb before the leaf, which returns "BONELLI"
    /// for Mister No: the publisher, not the hero. Checked against every saved
    /// page: the leaf is "Mister No", "Kit Teler", "Dzudas", "Alan Ford".
    /// Registered names nobody uses when talking about the comic.
    ///
    /// Applied only when a hero is *shown*. The forum's own spelling is what
    /// gets stored and indexed, so searching "te-nay" still finds Zagor and
    /// nothing is lost by preferring the short form on screen.
    /// Keyed on the folded form so punctuation and case cannot miss.
    private static let heroAliases: [String: String] = [
        "zagor te nay": "Zagor",
    ]

    /// How a hero should read on screen.
    public static func displayName(forHero name: String) -> String {
        heroAliases[Fold.fold(name)] ?? name
    }

    /// The trail crumb identified as the hero, exactly as the forum spells it.
    ///
    /// Kept separate from `hero` because `publisher` locates itself relative to
    /// this crumb *in the trail* — and an aliased name ("Zagor") no longer
    /// appears there, so looking that up finds nothing.
    var heroCrumb: String? {
        // The topic names the hero first: "Mister No - LUNOV MAGNUS STRIP".
        // Matched against the breadcrumb so the fuller forum spelling wins —
        // "Zagor" in the topic, "Zagor Te-Nay" in the trail — and because the
        // leaf crumb is sometimes a section ("ZS i LMS") rather than a hero.
        guard let key = topicParts.first, !key.isEmpty else { return trail.last }
        let folded = Fold.fold(key)
        // No match means the topic is not about a character at all. The forum
        // indexes its heroes as breadcrumbs, so a first part that appears
        // nowhere in the trail — "Kolorka", "Orka Specijal", "Alef" — is a
        // publication in its own right, and nil here routes `edition` to treat
        // it as one.
        return trail.first {
            let crumb = Fold.fold($0)
            return crumb.hasPrefix(folded) || folded.hasPrefix(crumb)
        }
    }

    public var hero: String? { heroCrumb }

    /// Topic split on " - ", with bracketed asides removed.
    private var topicParts: [String] {
        guard let topic else { return [] }
        var cleaned = topic
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#] {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: " ",
                                                   options: .regularExpression)
        }
        return cleaned.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The grouping directly above the hero ("BONELLI", "Magnus - Bunker").
    ///
    /// Found relative to the hero rather than at a fixed depth: some topics
    /// carry an extra section crumb below it ("ZS i LMS"), which shifts every
    /// fixed offset by one.
    public var publisher: String? {
        // Character topics: the crumb above the hero.
        if let crumb = heroCrumb, let index = trail.firstIndex(of: crumb), index > 0 {
            return trail[index - 1]
        }
        // Magazine topics: the shouted part of the title is the imprint.
        guard heroCrumb == nil else { return nil }
        return topicParts.dropFirst().first { part in
            part.contains(where: \.isLetter) && !part.contains(where: { $0.isLowercase })
        }
    }

    /// The edition a topic collects, e.g. "LUNOV MAGNUS STRIP".
    ///
    /// Topics are titled "<hero> - <EDITION>", so the edition is whichever part
    /// is not the hero. Alan Ford writes it as one run —
    /// "Alan Ford Super Strip Biblioteka [425] [Vjesnik] - Alan Ford" — so the
    /// hero is also stripped from the front of the remainder, and bracketed
    /// asides (issue counts, publisher tags) are dropped first.
    public var edition: String? {
        // A magazine names itself first and its publisher second: "Kolorka -
        // FIBRA - …". Taking the shouted part would file Orka, Kolorka and
        // both Specijals under one "FIBRA", which is the publisher they share
        // rather than the series that tells them apart.
        //
        // Requires a trail to be present: "no crumb matches" only means
        // "not a character" when there were crumbs to check. With none at all
        // there is no evidence either way, and the shouted part is the better
        // guess — that is what every character topic uses.
        if !trail.isEmpty, heroCrumb == nil,
           let own = topicParts.first, !own.isEmpty { return own }

        let heroFolded = hero.map(Fold.fold)
        let parts = topicParts.filter { Fold.fold($0) != heroFolded }

        // Editions are shouted on this forum — "LUNOV MAGNUS STRIP",
        // "ZLATNA SERIJA", "FIBRA" — which separates them from the hero and
        // from descriptive asides far more reliably than position does.
        if let shouted = parts.first(where: { part in
            part.contains(where: \.isLetter) && !part.contains(where: \.isLowercase)
        }) { return shouted }

        guard var candidate = parts.last else { return nil }

        // "Alan Ford Super Strip Biblioteka" -> "Super Strip Biblioteka"
        if let hero, Fold.fold(candidate).hasPrefix(Fold.fold(hero)),
           candidate.count > hero.count {
            candidate = String(candidate.dropFirst(hero.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return candidate.isEmpty ? nil : candidate
    }

    /// Editions whose initials are not what readers call them.
    ///
    /// "Stripzona Scanlation" reduces to "SS", which says nothing. It is also
    /// not an edition in the sense the others are — no publisher printed it;
    /// it is a fan scanlation that exists only here — so it is spelled out
    /// rather than abbreviated, and reads as the odd one out on a shelf of
    /// LMS and ZS precisely because it is.
    ///
    /// Keyed on the folded form so case and punctuation cannot miss.
    private static let editionCodes: [String: String] = [
        "stripzona scanlation": "SZScanlation",
    ]

    /// Short form of an edition, for the shelf: an alias where one exists,
    /// otherwise initials when it is several words ("Lunov Magnus Strip" ->
    /// "LMS") and the word itself when it is one ("Vjesnik", "FIBRA").
    ///
    /// The single definition both `PageContext` and `StoredIssue` use — they
    /// had a copy each, which is two places for the next alias to be forgotten.
    public static func code(forEdition edition: String) -> String? {
        if let alias = editionCodes[Fold.fold(edition)] { return alias }
        let words = edition.split(whereSeparator: { $0 == " " || $0 == "-" })
            .filter { $0.contains(where: \.isLetter) }
        guard !words.isEmpty else { return nil }
        if words.count == 1 { return String(words[0]) }
        return words.compactMap { $0.first?.uppercased() }.joined()
    }

    public var editionCode: String? { edition.flatMap(Self.code(forEdition:)) }

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
