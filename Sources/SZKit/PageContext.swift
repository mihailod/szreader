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
            .filter { !$0.isEmpty && !Self.pageMarker.matches($0) }
    }

    /// The forum's own pagination, which rides along in the title of every
    /// topic past the first screen: "Veliki Blek - Lunov Magnus Strip - Page 2".
    ///
    /// Never an edition. Zagor survived it only by accident — "ZLATNA SERIJA"
    /// is shouted, so the shouted-part rule reached it first — while Veliki
    /// Blek's "Lunov Magnus Strip" is title case, so the edition fell through
    /// to the last part and pages 2 and 3 became series called "Page 2" and
    /// "Page 3", each with its own hundred issues.
    private static let pageMarker = Rx(#"^Page\s*\d+$"#, [.caseInsensitive])

    /// The grouping directly above the hero ("BONELLI", "Magnus - Bunker").
    ///
    /// Found relative to the hero rather than at a fixed depth: some topics
    /// carry an extra section crumb below it ("ZS i LMS"), which shifts every
    /// fixed offset by one.
    /// Houses that appear in this corpus by name in a topic's own title.
    ///
    /// A list, because nothing in the text separates a publisher from a city:
    /// "Kriminal, Bookglobe, Zagreb" and "Roto Biblioteka X-100 SF, Naučna
    /// fantastika X-100, Dnevnik" have the same shape, and only knowing what
    /// these words are says which part is the house.
    ///
    /// Folded, so spelling and case cannot miss.
    private static let publishers: Set<String> = [
        "dnevnik", "vjesnik", "politika", "decje novine", "bookglobe",
        "slobodna dalmacija", "libellus", "fibra", "marketprint", "system comics",
    ]

    /// The publisher a topic names in its own title, when the edition has not
    /// already taken it.
    ///
    /// Most comma topics are "<name>, <house>, <city>", and `edition` picks
    /// the house up as the series — that is what makes it searchable, and
    /// nothing more is needed. Roto Biblioteka is the exception: its comma run
    /// leads with a genre ("… X-100 SF, Naučna fantastika X-100, Dnevnik"), so
    /// the edition became "SF" and the house went nowhere.
    private var namedPublisher: String? {
        guard let topic else { return nil }
        let editionFolded = edition.map(Fold.fold)
        // Split on both separators. The house is the last comma part, but the
        // topic carries the forum section after a dash — "…, Dnevnik - Roto
        // Biblioteka X-100" — so a comma split alone leaves the two joined.
        return topic
            .components(separatedBy: ",")
            .flatMap { $0.components(separatedBy: " - ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { part in
                Self.publishers.contains(Fold.fold(part)) && Fold.fold(part) != editionFolded
            }
    }

    public var publisher: String? {
        // A house the topic names itself, where the series did not already
        // become it. More specific than the crumb above, which for a novel
        // series is a section — "Pisani romani" — rather than anyone who
        // published anything.
        if let named = namedPublisher { return named }
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
           let own = topicParts.first, !own.isEmpty { return Self.named(own) }

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

            // What is left is an edition only if it reads like the name of
            // one. A topic can just as easily name a single story — "Timothy
            // Tatcher 02 Hollywood protiv mene (SS 305)" — and stripping the
            // hero from that leaves "02 Hollywood protiv mene", which is one
            // issue, not a run. Filed as an edition it became its own shelf
            // heading, initialled "HPM", with that topic's issues alone under
            // it.
            //
            // The number in front is the tell: an edition is not numbered, an
            // issue is. Where the topic names an issue there is no edition in
            // it to find, and the character it belongs to is the truest thing
            // the title says.
            if candidate.first?.isNumber == true { return hero }
        }
        candidate = Self.named(candidate)
        return candidate.isEmpty ? nil : candidate
    }

    /// The name out of a comma-qualified run.
    ///
    /// Topics describe themselves as well as naming themselves: "Sirius, SF
    /// časopis", "Asteriks, Politika, 1995-1999, cirilica", "Johnny Logan,
    /// Vjesnik, 1980-1984". The edition is the first part that is a name
    /// rather than a span of years, and no edition in the corpus has a comma
    /// in it — the descriptions are searchable through the page context
    /// either way.
    private static func named(_ run: String) -> String {
        let trimmed = run.trimmingCharacters(in: CharacterSet(charactersIn: " ,-–"))
        guard trimmed.contains(",") else { return trimmed }
        let parts = trimmed.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.first { $0.contains(where: \.isLetter) && Int($0) == nil } ?? trimmed
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

    /// The same trailing-number convention, on any host and with or without a
    /// separator: `TN_ZG_ZS_13.jpg`, `Dzudas_01.jpg`, `alef-SF01.jpg`.
    ///
    /// A cache-busting suffix after the number is tolerated too — Photobucket
    /// rewrites covers as `AS_PZAL_1_zps96t63e0n.jpg`, which is the number in
    /// the middle rather than at the end.
    ///
    /// The digits must be introduced by a separator, or be at least two long
    /// after a letter. Without that guard a random imgur id like
    /// `wW7QGs8.jpg` reads as issue 8 — and because this tier runs before
    /// positional matching, that false reading takes the slot from the cover
    /// actually sitting beside issue 8.
    ///
    /// StripZona's own scanlations are not on stripovi.com — their art is
    /// posted alongside the topic, e.g. `thumbs/strider/Dzudas/Dzudas_01.jpg`.
    /// The filename still names the issue, which beats inferring it from
    /// position, so this runs before the positional tier rather than after.
    private static let numberedImage =
        Rx(#"(https?://[^"'\s]*?(?:[-_ ]|[A-Za-z](?=\d{2}))(\d{1,4})"#
           + #"(?:_[A-Za-z0-9]{4,})?\.(?:jpe?g|png))"#, [.caseInsensitive])

    /// A filename that opens with the series and its issue number, and then
    /// runs on into the scanners' credits:
    /// `Galaksija-097-drazen23-Mick-RC-Mad-Mate-1.jpg`.
    ///
    /// Read from the front, not the back. The trailing tier above takes the
    /// *last* number in the name, which on these is the credit run's own
    /// "-1" — so a whole magazine's art collapsed onto issue 1 and the rest
    /// fell through to position, which then filed `Galaksija-020.jpg` under
    /// issue 11.
    ///
    /// Anchored to the start of the last path component, so the random id
    /// postimg puts in the directory above cannot be read as a number. Across
    /// the corpus this fires on six pages, and on every one the leading word
    /// is the series' own name with a dense run of issues behind it — there
    /// is no page where it finds something else. Where those pages already
    /// had covers from a tier that was right (Dzudas, Gigant, Sirius) it
    /// reproduces them exactly; every case where it disagrees is one of the
    /// misfilings above.
    static let leadingNumberedImage = Rx(
        #"(https?://[^\s"'<>]+/([A-Za-zČĆŠŽĐčćšžđ]{3,})[-_ ](\d{1,4})"#
        + #"(?:[-_ ][^/\s"'<>]*)?\.(?:jpe?g|png|webp))"#, [.caseInsensitive])

    /// Tier 1c: the number at the head of the filename.
    static func leadingNumberedCovers(in html: String) -> [Int: String] {
        var out: [Int: String] = [:]
        for match in leadingNumberedImage.allGroups(html) where isPlausibleCover(match[1]) {
            guard let number = Int(match[3]) else { continue }
            // A four-digit number in that slot is a year, not an issue:
            // no magazine here runs past a few hundred.
            if match[3].count == 4, (1900...2099).contains(number) { continue }
            if out[number] == nil { out[number] = https(match[1]) }
        }
        return out
    }

    /// Issue number → cover URL, for the covers referenced by one page.
    ///
    /// Tiers, in order of confidence:
    ///
    ///  1. the stripovi.com filename, whose trailing number names the issue
    ///     outright — exact, so it always wins;
    ///  1c. a filename that opens with the series and its number;
    ///  2. a second number the label itself gives, when the filenames are
    ///     numbered by that instead;
    ///  3. failing both, the position of the images in the post.
    ///
    /// Tier 2 exists for StripZona's own scanlations. Those are not catalogued
    /// on stripovi.com, so the art is attached to the post itself and its
    /// filename says nothing about which issue it belongs to. All that is left
    /// to go on is where the image sits relative to the titles.
    public static func covers(in html: String) -> [Int: String] {
        var out = numberedCovers(in: html)
        // Ahead of the trailing reading, which on these filenames finds the
        // credit run's number rather than the issue's.
        for (number, url) in leadingNumberedCovers(in: html) where out[number] == nil {
            out[number] = url
        }
        for (number, url) in numberedCovers(in: html, pattern: numberedImage)
        where out[number] == nil {
            out[number] = url
        }
        for (number, url) in crossReferencedCovers(in: html, byNumber: out) where out[number] == nil {
            out[number] = url
        }
        // Tier 3 only where there is no catalogue to go on.
        //
        // Position is a guess, and on a page whose covers are named after
        // their issues there is nothing left for it to guess at correctly:
        // what it finds are the strips of three or six covers posted to
        // illustrate a group of issues, which it then hands to whichever
        // issue happens to sit next to them. On Veliki Blek that put a
        // six-up strip on two issues and issue 197's cover on issue 188.
        //
        // The threshold rather than "any at all": one stray catalogued cover
        // on a scanlation page must not switch off the only tier that page
        // has.
        // A magazine printed as one issue over two numbers is filed under
        // both: "Sirius_121_122.jpg". The ordinary reading takes the trailing
        // number, files it under 122 — an issue that does not exist — and
        // leaves 121-122 with nothing.
        for (number, url) in doubleNumberedCovers(in: html) where out[number] == nil {
            out[number] = url
        }
        // Worked out now but spent last, so the tiers in between see the page
        // as they always did. What is needed here is only *which* images are
        // sheets: one sits in a run like any other image, and the run reading
        // below would hand a whole grid of six to a single issue — which is
        // how issue 137 came to be showing all of 128…137.
        //
        // Only the *names* are taken now. Which issues the tiles go to is
        // worked out again at the end, against the finished map, so every
        // tier in between behaves exactly as it did before this existed.
        let grids = Set(contactSheetCovers(in: html, claimed: out).values
            .compactMap { CoverTile(reference: $0)?.sheet })

        // Runs of art beside runs of issues, where the ones already spoken
        // for prove the two line up.
        for (number, url) in anchoredRunCovers(in: html, claimed: out, skipping: grids)
        where out[number] == nil {
            out[number] = url
        }
        if out.count < Self.catalogued {
            for (number, url) in positionalCovers(in: html) where out[number] == nil {
                out[number] = url
            }
        }
        for (number, url) in contactSheetCovers(in: html, claimed: out)
        where out[number] == nil {
            out[number] = url
        }
        return out
    }

    /// How many images in a run must already be spoken for before the rest of
    /// that run may be trusted.
    ///
    /// Two, not one: a single agreement between an image and the issue beside
    /// it is as likely to be luck as alignment.
    private static let anchorsNeeded = 2

    /// Covers posted as a run of images, then the run of issues they belong
    /// to, matched position for position.
    ///
    /// Veliki Blek posts six covers and then lists six issues:
    ///
    ///     TN_VB_LMS_176  TN_VB_LMS_177  TN_VB_LMS_180  RalRsSZ  KxQxofS  TN_..185
    ///            176            177            180       181      184      185
    ///
    /// Four of those images name their issue in the filename and are already
    /// claimed; the other two are bare imgur ids that no tier can read. They
    /// are 181 and 184, and the run says so — but only because the four
    /// claimed images each sit opposite their own issue.
    ///
    /// That agreement is the whole point. Pairing runs on position alone is
    /// guesswork, and it was tried: it moved covers on two other pages and
    /// fixed nothing. Here the page proves the alignment before anything is
    /// inferred from it, and a single image landing opposite the wrong issue
    /// throws the whole run away.
    /// `skipping` names images that are grids of covers rather than one
    /// cover, so a run containing a contact sheet still lines up — that slot
    /// simply goes unfilled here and the sheet is shared out into tiles later.
    static func anchoredRunCovers(in html: String, claimed: [Int: String],
                                  skipping grids: Set<String> = []) -> [Int: String] {
        var owner: [String: Int] = [:]
        for (number, url) in claimed { owner[url] = number }

        var out: [Int: String] = [:]
        var images: [String] = []
        var labels: [Int] = []

        func settle() {
            defer { images = []; labels = [] }
            guard images.count == labels.count, images.count >= anchorsNeeded else { return }

            var anchors = 0
            for (index, url) in images.enumerated() {
                guard let number = owner[url] else { continue }
                // One image opposite an issue that is not its own means these
                // two runs are not the same list.
                guard number == labels[index] else { return }
                anchors += 1
            }
            guard anchors >= anchorsNeeded else { return }

            for (index, url) in images.enumerated()
            where owner[url] == nil && !grids.contains(url) && claimed[labels[index]] == nil {
                out[labels[index]] = url
            }
        }

        for line in HTMLText.plainLines(html, keepingImages: true) {
            if let url = HTMLText.markedImage(line), isPlausibleCover(url) {
                if !labels.isEmpty { settle() }
                images.append(https(url))
            } else if let number = label(in: line) {
                labels.append(number)
            }
        }
        settle()
        return out
    }

    /// Grids a contact sheet is posted in: three across, one or two down.
    private static let sheetSizes = [3, 6]

    /// Covers posted as one image holding a grid of them.
    ///
    /// Veliki Blek illustrates a group of six issues with a single JPEG of
    /// six covers, three across and two down, and then lists those six issues
    /// underneath. No tier can use that image, because it is not any one
    /// issue's cover — and handing the whole sheet to whichever issue sits
    /// nearest is the mistake the positional tier was stopped from making.
    ///
    /// But the relationship is not a guess: one image, then exactly six
    /// labels, in reading order. Tile *k* belongs to label *k*. Each issue
    /// gets a reference naming its tile, and the crop happens once, when the
    /// image is decoded.
    ///
    /// Only for an image nothing else claimed, and only for issues that have
    /// no cover — an issue with art of its own keeps it, so a sheet whose
    /// issues are already covered contributes nothing but the gaps.
    static func contactSheetCovers(in html: String, claimed: [Int: String]) -> [Int: String] {
        let used = Set(claimed.values)
        var out: [Int: String] = [:]
        var sheet: String?
        var following: [Int] = []

        func spend() {
            defer { following = [] }
            guard let url = sheet.map(https), !used.contains(url),
                  sheetSizes.contains(following.count) else { return }
            for (tile, number) in following.enumerated() where claimed[number] == nil {
                out[number] = CoverTile.reference(url, tile: tile, of: following.count)
            }
        }

        for line in HTMLText.plainLines(html, keepingImages: true) {
            if let url = HTMLText.markedImage(line), isPlausibleCover(url) {
                spend()
                sheet = url
            } else if let number = label(in: line) {
                following.append(number)
            }
        }
        spend()
        return out
    }

    /// How many covers named after their issues make a page a catalogued one.
    ///
    /// Every page in the corpus is emphatically one or the other — hundreds
    /// of catalogued covers, or none at all — so this only has to fall
    /// between "a stray link" and "a catalogue".
    static let catalogued = 5

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
        // Member avatars are named "av-68.jpg". Now that a cover need not have
        // an underscore before its number, one of those would otherwise claim
        // to be issue 68 — and on a page that has an issue 68, silently take
        // its cover.
        "/uploads/av-", "sharelinks",
        // The forum's own "picture missing" graphic. Every bbc_img carries it
        // in an onerror handler, and an onload handler swaps it in for dead
        // photobucket images — which updates the src attribute, so a page
        // imported from the live DOM has it as a real src where the saved
        // copy still shows the original link. Taking it as artwork is worse
        // than having none: it looks deliberate, and it blocks the fallback
        // that would otherwise use the comic's own first page.
        "picturemissing",
    ]

    /// Covers are photographs; furniture is overwhelmingly GIF.
    private static let coverExtensions = [".jpg", ".jpeg", ".png", ".webp"]

    static func isPlausibleCover(_ url: String) -> Bool {
        let lower = url.lowercased()
        guard coverExtensions.contains(where: { lower.contains($0) }) else { return false }
        return !furniture.contains(where: lower.contains)
    }

    /// A label that gives the issue's number in another series as well as its
    /// own: "01 (SS 173) Johnny Logan 001 - Crni tigrovi".
    ///
    /// The letters are required, and no slash is allowed inside the brackets,
    /// so this reads "(SS 173)" but not "(SSB 089/001)" — a compound
    /// reference names no single cover and its leading number would pick one
    /// at random.
    private static let crossReference = Rx(
        #"^\s*(\d{1,4})\s*\(\s*[A-ZČĆŠŽĐ]{2,5}\s+(\d{1,5})\s*\)"#)

    /// Tier 1b: covers filed under that other number.
    ///
    /// A reprint topic numbers its issues 1…21 while the covers are named for
    /// the original series — TN_JL_SS_173.jpg for issue 1 — so tier 1 files
    /// all of them under numbers no issue claims, and position then hands out
    /// the wrong art: every group's last cover went to its first issue.
    private static func crossReferencedCovers(in html: String,
                                              byNumber: [Int: String]) -> [Int: String] {
        var out: [Int: String] = [:]
        for line in HTMLText.plainLines(html) {
            guard let groups = crossReference.firstGroups(line),
                  let issue = Int(groups[1]), let other = Int(groups[2]),
                  issue != other, let url = byNumber[other] else { continue }
            if out[issue] == nil { out[issue] = url }
        }
        return out
    }

    /// Covers named after both numbers of a double issue, filed under the
    /// first — which is the number the issue itself carries.
    static let doubleCoverImage = Rx(
        #"(https?://[^\s"'<>]+?_(\d{1,4})_(\d{1,4})\.(?:jpe?g|png|webp))"#, [.caseInsensitive])

    static func doubleNumberedCovers(in html: String) -> [Int: String] {
        var out: [Int: String] = [:]
        for match in doubleCoverImage.allGroups(html) {
            guard let first = Int(match[2]), let second = Int(match[3]),
                  second == first + 1, isPlausibleCover(match[1]) else { continue }
            if out[first] == nil { out[first] = https(match[1]) }
        }
        return out
    }

    /// Covers named after something other than a number: "Sirius_YU.jpg" for
    /// the special that closes the run.
    ///
    /// Keyed on that word, folded, so an issue with no number of its own can
    /// still be matched by what it is called.
    static let namedCoverImage = Rx(
        #"(https?://[^\s"'<>]+?[_-]([A-Za-zČĆŠŽĐčćšžđ]{2,12})\.(?:jpe?g|png|webp))"#,
        [.caseInsensitive])

    public static func namedCovers(in html: String) -> [String: String] {
        var out: [String: String] = [:]
        for match in namedCoverImage.allGroups(html) where isPlausibleCover(match[1]) {
            let key = Fold.fold(match[2])
            if out[key] == nil { out[key] = https(match[1]) }
        }
        return out
    }

    /// Tier 2: match images to issues by position.
    ///
    /// Which side the art sits on is decided once for the whole page rather
    /// than per image. Posts put the cover above the title as often as below,
    /// and guessing per image goes wrong on a topic that opens with an index:
    /// the last index entry sits there waiting, claims the first real cover,
    /// and every issue after it is off by one — wrong covers throughout, which
    /// is worse than none.
    static func positionalCovers(in html: String) -> [Int: String] {
        let events = pageEvents(in: html)
        guard !events.isEmpty else { return [:] }

        var out: [Int: String] = [:]
        let imageFirst = leans(toImageFirst: events)
        for (index, event) in events.enumerated() {
            guard case .label(let number) = event.kind, out[number] == nil else { continue }
            let neighbour = imageFirst ? index - 1 : index + 1
            guard events.indices.contains(neighbour),
                  case .image(let url) = events[neighbour].kind else { continue }
            // An image with no title near it belongs to no issue.
            guard abs(events[neighbour].line - event.line) <= window else { continue }
            out[number] = https(url)
        }
        return out
    }

    private static let window = 4

    private enum PageEvent { case image(String), label(Int) }
    private struct Positioned { let kind: PageEvent; let line: Int }

    /// Images and labels in document order, with the line each sits on so the
    /// distance between them can be judged.
    private static func pageEvents(in html: String) -> [Positioned] {
        var events: [Positioned] = []
        for (number, line) in HTMLText.plainLines(html, keepingImages: true).enumerated() {
            if let url = HTMLText.markedImage(line) {
                guard isPlausibleCover(url) else { continue }
                events.append(Positioned(kind: .image(url), line: number))
            } else if let issue = label(in: line) {
                events.append(Positioned(kind: .label(issue), line: number))
            }
        }
        return events
    }

    /// Whether this page puts the cover before its title, by counting which
    /// way round adjacent pairs actually run.
    private static func leans(toImageFirst events: [Positioned]) -> Bool {
        var before = 0, after = 0
        for (index, event) in events.enumerated() where index + 1 < events.count {
            let next = events[index + 1]
            guard next.line - event.line <= window else { continue }
            switch (event.kind, next.kind) {
            case (.image, .label): before += 1
            case (.label, .image): after += 1
            default: break
            }
        }
        return before >= after
    }

    private static func label(in line: String) -> Int? {
        if let g = Labels.num.firstGroups(line), let n = Int(g[1]) { return n }
        if let g = Labels.code.firstGroups(line), let n = Int(g[2]) { return n }
        // Name-first labels count too. Without this a topic written as
        // "Corto Maltese - 01 - Mladost" has no labels as far as cover
        // matching is concerned, so no image can ever be attached to one.
        if let match = Labels.matchNameFirst(line), let n = Int(match.number) { return n }
        return nil
    }

    /// stripovi.com 301s every http image to https, so an http URL costs two
    /// round-trips per cover — 240 requests for a 120-issue page before
    /// anything appears. Normalise once, here.
    private static func https(_ url: String) -> String {
        url.replacingOccurrences(of: "http://", with: "https://")
    }
}

extension Catalog {
    /// The covers whose own filename says which issue they belong to.
    ///
    /// The subset of `covers(in:)` that carries evidence rather than
    /// inference, which is what makes it safe to apply to issues listed on a
    /// different page than the art.
    public static func exactCovers(in html: String) -> [Int: String] {
        var out = numberedCovers(in: html)
        for (number, url) in leadingNumberedCovers(in: html) where out[number] == nil {
            out[number] = url
        }
        for (number, url) in doubleNumberedCovers(in: html) where out[number] == nil {
            out[number] = url
        }
        return out
    }
}
