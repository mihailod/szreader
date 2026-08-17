import Foundation

/// Where stripovi.com keeps a cover, taken apart.
///
/// The catalogue's artwork is at a path that says exactly what it holds:
///
///     https://www.stripovi.com/naslovnice/AlanFord/TN/TN_TT_SS_305.jpg
///                                        └folder┘     └H┘└E┘└num┘
///
/// A hero code, an edition code and the number that edition files the issue
/// under. The folder is where the file lives and nothing more — it is not the
/// hero: Timothy Tatcher and Johnny Logan are both filed under `AlanFord`,
/// because their runs share a publisher's line rather than a character.
///
/// That split is what makes a cover addressable without searching for it. The
/// encyclopedia page for an issue carries an opaque database id nothing can
/// compute, but the picture beside it does not.
public struct CataloguePath: Hashable, Sendable {
    /// Where the run's covers live, and what they call it. Everything except
    /// which issue this one is — which is what makes it worth learning: one
    /// naming addresses every number in the run.
    public let naming: CatalogueNaming
    /// The number that edition files the issue under.
    public let number: Int

    public init(naming: CatalogueNaming, number: Int) {
        self.naming = naming; self.number = number
    }

    public init(folder: String, hero: String, edition: String, number: Int) {
        self.init(naming: CatalogueNaming(folder: folder, hero: hero, edition: edition),
                  number: number)
    }

    public var folder: String { naming.folder }
    public var hero: String { naming.hero }
    public var edition: String { naming.edition }

    public var url: String { naming.url(number: number) }

    public static let host = "https://www.stripovi.com"

    /// The naming, read back off a URL the catalogue already gave us.
    ///
    /// Tolerates both shapes — with the `TN/TN_` and without — because both
    /// appear in the wild, and ignores any leading `TN_` so the codes come
    /// back the same either way.
    private static let shape = Rx(
        #"(?i)naslovnice/([A-Za-z0-9]+)/(?:TN/)?(?:TN_)?"#
        + #"([A-Za-z0-9]{1,6})_([A-Za-z0-9]{1,6})_(\d{1,5})\.jpe?g"#)

    public static func parse(_ url: String) -> CataloguePath? {
        guard url.contains("stripovi.com"), let g = shape.firstGroups(url),
              let number = Int(g[4]) else { return nil }
        return CataloguePath(folder: g[1], hero: g[2].uppercased(),
                             edition: g[3].uppercased(), number: number)
    }
}

/// How one run's covers are named — the part that is the same for every issue
/// in it, and so the part worth learning from one and using on another.
public struct CatalogueNaming: Hashable, Sendable {
    public let folder: String
    public let hero: String
    public let edition: String

    public init(folder: String, hero: String, edition: String) {
        self.folder = folder; self.hero = hero; self.edition = edition
    }

    /// The thumbnail, which is what the forum's pages hotlink and therefore
    /// what the library already holds fifteen hundred of.
    ///
    /// A full-size copy sits beside it, at the same name without the `TN`, and
    /// is five times the bytes for artwork drawn at 150pt on a shelf. The
    /// thumbnail is the one asked for so that a cover found this way is the
    /// same kind of thing as a cover read off a page.
    public func url(number: Int) -> String {
        "\(CataloguePath.host)/naslovnice/\(folder)/TN/TN_\(hero)_\(edition)_\(number).jpg"
    }
}

/// What the library has already learned about the catalogue's naming.
///
/// Every cover read off a forum page is a worked example: it ties a hero and
/// an edition to a folder and the two codes the filename uses. Fifteen hundred
/// of them across thirteen runs answer, without a single request, questions no
/// rule could — that Kapetan Miki is `MI` and not `KM`, that Zagor Te-Nay is
/// `ZG`, that Druzina od vjesala's covers say `SS` while the row calls its
/// edition "Vjesnik", and that Johnny Logan lives under `AlanFord`.
///
/// Learned rather than written down because a table of hero codes is a table
/// someone has to maintain, and the library is already carrying the answers.
struct CatalogueIndex {

    /// Folded hero → the namings its covers use, commonest first.
    private var byHero: [String: [CatalogueNaming]] = [:]
    /// Folded hero + edition → the same, for a hero with runs in two editions.
    private var byHeroEdition: [String: [CatalogueNaming]] = [:]
    /// Edition code → folders known to hold that edition, commonest first.
    private var foldersByEdition: [String: [String]] = [:]
    /// Hero code → the folded hero it is known to belong to.
    private var heroByCode: [String: String] = [:]

    /// Built from rows the library already holds: a hero, an edition, and a
    /// cover URL that came from the catalogue.
    init(rows: [(hero: String?, edition: String?, url: String)]) {
        var heroNamings: [String: [CatalogueNaming: Int]] = [:]
        var heroEditionNamings: [String: [CatalogueNaming: Int]] = [:]
        var editionFolders: [String: [String: Int]] = [:]
        var codeHeroes: [String: [String: Int]] = [:]

        for row in rows {
            guard let path = CataloguePath.parse(row.url) else { continue }
            // Where an edition keeps its covers is a fact about the URL alone,
            // so it is learned from every catalogued cover — including the
            // ones on pages with no breadcrumb, whose rows have no hero to
            // attribute anything else to.
            editionFolders[path.edition, default: [:]][path.folder, default: 0] += 1

            guard let hero = row.hero, !hero.isEmpty else { continue }
            let key = Fold.fold(hero)
            // Counted per naming, not per cover: a run of three hundred is
            // three hundred numbers sharing one naming, and counting the paths
            // would make every issue a rival of its own neighbours.
            heroNamings[key, default: [:]][path.naming, default: 0] += 1
            heroEditionNamings[Self.key(hero: hero, edition: row.edition),
                               default: [:]][path.naming, default: 0] += 1
            codeHeroes[path.hero, default: [:]][key, default: 0] += 1
        }

        // Commonest first throughout. One page in the corpus hotlinks a
        // neighbour's cover among its own — Kit Teler's run carries a single
        // `TexWiller/TX_LMS` among three hundred `KitTeller/KT_LMS` — and a
        // naming taken from whichever row came back first would follow it.
        byHero = heroNamings.mapValues { Self.ranked($0) }
        byHeroEdition = heroEditionNamings.mapValues { Self.ranked($0) }
        foldersByEdition = editionFolders.mapValues { counts in
            counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        }
        heroByCode = codeHeroes.compactMapValues { counts in
            counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }
    }

    private static func ranked(_ counts: [CatalogueNaming: Int]) -> [CatalogueNaming] {
        counts.sorted { ($0.value, $1.key.folder) > ($1.value, $0.key.folder) }.map(\.key)
    }

    private static func key(hero: String, edition: String?) -> String {
        Fold.fold(hero) + "|" + Fold.fold(edition ?? "")
    }

    /// How this hero's covers are named, preferring what the same edition
    /// used: Kit Teler is `KT` in both, but the folder and edition code differ
    /// between his Lunov Magnus Strip and Zlatna Serija runs.
    func naming(hero: String?, edition: String?) -> [CatalogueNaming] {
        guard let hero, !hero.isEmpty else { return [] }
        let exact = byHeroEdition[Self.key(hero: hero, edition: edition)] ?? []
        let any = byHero[Fold.fold(hero)] ?? []
        return exact + any.filter { !exact.contains($0) }
    }

    /// Folders known to hold an edition, for a hero the library has never seen
    /// artwork for. Super Strip's covers are under `AlanFord` and
    /// `DruzinaOdVjesala`; one of them is where a new Super Strip issue is.
    func folders(hostingEdition code: String) -> [String] {
        foldersByEdition[code.uppercased()] ?? []
    }

    /// Whether a code is already spoken for by somebody else.
    ///
    /// The guard on guessing a code from initials. "Kapetan Miki" initials to
    /// `KM`, which is Komandant Mark — and both run in Zlatna Serija, so
    /// `KM_ZS_100` exists, returns an image, and is the wrong comic. A wrong
    /// folder merely misses; a wrong hero code can hit.
    func codeIsTaken(_ code: String, byOtherThan hero: String) -> Bool {
        guard let owner = heroByCode[code.uppercased()] else { return false }
        return owner != Fold.fold(hero)
    }
}
