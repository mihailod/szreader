import Foundation

/// Which archive an issue came from.
///
/// The three are nothing alike as sources — one is a forum whose topics are
/// imported by hand and whose links point at third-party file hosts, the other
/// two are static indexes shipped with the app that download from one server
/// each — but they land in the same table on purpose.
///
/// Everything downstream of an issue is keyed on `issue.id` as a globally
/// unique number: the download folder is `comics/<id>`, the captured cover is
/// `covers/<id>.jpg`, `download.issue_id` is a primary key, and the app
/// tracks in-flight work in `Set<Int>` and `[Int: Double]`. Two databases
/// each numbering from one would put two different magazines in the same
/// folder. One table and a column saying where a row came from keeps every
/// one of those call sites correct without touching them.
public enum IssueSite: String, Sendable, CaseIterable, Equatable {
    case stripzona
    case retrospec
    case archive
    case comicbookplus
    // Like StripZona and Comic Book Plus, a source with no shipped index:
    // the site publishes tens of thousands of issues and no catalogue of
    // them, so it arrives a page at a time through the browser. Unlike
    // either, one page is one issue rather than a run — see `BatCavePage`.
    case batcave
    // A shipped index like RetroSpec's, but of loose page images rather than
    // archives: 31 Croatian web comics, none of which is a file. Its
    // catalogue is its own shape for that reason — see `StripoviCatalog`.
    case stripovi
    // A shipped index like RetroSpec's, but assembled rather than scraped:
    // ZXDB stores a URL template per magazine and `spectrum-build` expands it
    // against each issue, then asks archive.org what that item really holds.
    //
    // English only, split by what the material is rather than by the language
    // it is in. Books are the odd one: they are not periodicals and come from
    // a different pair of ZXDB tables. See `Spectrum.Group`, which is where
    // the mapping to a catalogue file lives.
    case spectrumMagazines
    case spectrumFanzines
    case spectrumBooks
    // BombJack ships as seven catalogues rather than one.
    //
    // As a single source it was 18,219 rows: fifteen seconds to seed, which
    // iOS kills an app for during launch, and a noticeable freeze every time
    // the switch moved. Split by what the material *is*, the largest is 3,204
    // and a reader takes only the parts they want. They are separate sites
    // rather than one site with a category column because every mechanism
    // this app already has — seed stamps, hiding, the filter menus, the wall
    // in the natural key — is per-site and needs no new concept to work.
    case bombjackCommodoreMagazines
    case bombjackAmigaMagazines
    case bombjackOtherMagazines
    case bombjackBooks
    case bombjackHardware
    case bombjackGames
    case bombjackOther

    /// How the source is spelled in front of a reader.
    public var display: String {
        switch self {
        case .stripzona:     return "StripZona"
        case .retrospec:     return "RetroSpec"
        case .archive:       return "Archive.org"
        case .comicbookplus: return "ComicBook+"
        case .batcave:       return "BatCave"
        case .stripovi:      return "Stripovi.com"
        case .spectrumMagazines, .spectrumFanzines, .spectrumBooks:
            // "Spectrum Computing: Magazines" rather than "Magazines". Same
            // reason BombJack's categories are spelled in full below: this
            // string is written into the publisher column and the search index
            // of every seeded row, and "Magazines" on its own in a publisher
            // filter names nothing.
            guard let group = spectrumGroup else { return rawValue }
            return "Spectrum Computing: \(group.display)"
        default:
            // "BombJack: Books" rather than "Books". This string is written
            // into the publisher column and the search index of every seeded
            // row, so it has to say where the issue came from — "Books" on its
            // own in a publisher filter names nothing.
            guard let category = bombjackCategory else { return rawValue }
            return "BombJack: \(category.display)"
        }
    }

    /// How the source is spelled on the settings screen.
    ///
    /// `display` everywhere except Comic Book Plus, whose marketing name ends
    /// in a `+`. That reads as a name in a browser title bar or a menu, and
    /// reads as a stray character in a list of switches — so the settings list
    /// spells it as one word instead.
    ///
    /// A second property rather than a literal in the app layer, for two
    /// reasons: `UIWordingTests` lints App for the word "comic", and the two
    /// spellings of one source should sit next to each other where anyone
    /// changing either will see the other.
    public var settingsName: String {
        switch self {
        case .comicbookplus: return "ComicBookPlus"
        default: return display
        }
    }

    /// The catalogue shipped in the bundle for this source, if it has one.
    ///
    /// What makes a source seedable: the app switches one on, hands the name
    /// to `seedCatalogue(for:)` and is done. StripZona has none — its issues
    /// arrive by importing a forum page — and returning nil here is what says
    /// so, rather than a `switch` in the app repeating the same fact.
    /// Comic Book Plus has none, and cannot: it holds around fifty thousand
    /// books and publishes no index of them — its sitemap names its category
    /// pages, not its books. So it works the way StripZona does, a page at a
    /// time, and `Store.importComicBookPlus` is what reads one.
    public var catalogueResource: String? {
        switch self {
        case .stripzona, .comicbookplus, .batcave: return nil
        case .stripovi:                            return "stripovi-catalog"
        case .retrospec:                 return "retrospec-catalog"
        case .archive:                   return "archive-catalog"
        case .spectrumMagazines, .spectrumFanzines, .spectrumBooks:
            return spectrumGroup?.resource
        default:                         return bombjackCategory?.resource
        }
    }

    /// The BombJack category this source carries, or nil if it is not one of
    /// them.
    ///
    /// One place that knows the mapping, so a name, a file and a switch label
    /// cannot drift apart.
    public var bombjackCategory: BombJack.Category? {
        switch self {
        case .bombjackCommodoreMagazines: return .commodoreMagazines
        case .bombjackAmigaMagazines:     return .amigaMagazines
        case .bombjackOtherMagazines:     return .otherMagazines
        case .bombjackBooks:              return .books
        case .bombjackHardware:           return .hardware
        case .bombjackGames:              return .games
        case .bombjackOther:              return .other
        case .stripzona, .retrospec, .archive, .comicbookplus, .batcave, .stripovi,
             .spectrumMagazines, .spectrumFanzines, .spectrumBooks:
            return nil
        }
    }

    /// The ZXDB shelf this source carries, or nil if it is not one of them.
    ///
    /// The counterpart of `bombjackCategory`, and here for the same reason:
    /// one place that knows which case maps to which catalogue file, so a
    /// switch label and a resource name cannot come apart.
    public var spectrumGroup: Spectrum.Group? {
        switch self {
        case .spectrumMagazines: return .magazines
        case .spectrumFanzines:  return .fanzines
        case .spectrumBooks:     return .books
        default:                 return nil
        }
    }

    /// The three that make up the Sinclair archive, in the order the settings
    /// list shows them.
    public static let spectrumSites: [IssueSite] =
        Spectrum.Group.inMenuOrder.compactMap { group in
            IssueSite.allCases.first { $0.spectrumGroup == group }
        }

    /// The seven that make up BombJack, in the order the settings list shows
    /// them. Named `bombjackSites` rather than `bombjack` so it cannot be
    /// mistaken for the single case it replaced — which is exactly what two
    /// call sites did on the first build after the split.
    public static let bombjackSites: [IssueSite] =
        BombJack.Category.inMenuOrder.compactMap { category in
            IssueSite.allCases.first { $0.bombjackCategory == category }
        }

    /// What a row with no recorded source is.
    ///
    /// Every issue predates the column, so the migration backfills them all
    /// to this and new StripZona imports keep writing it.
    public static let `default` = IssueSite.stripzona
}
