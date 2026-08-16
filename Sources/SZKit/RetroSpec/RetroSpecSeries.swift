import Foundation

/// What language an issue was published in.
///
/// Worth carrying because it is the only thing separating two of the series:
/// Moj Mikro ran in Slovenian and in Serbo-Croatian, and the site files them
/// as two independent runs, each numbering from one.
public enum RetroSpecLanguage: String, Equatable, Sendable, CaseIterable {
    case serbian, croatian, slovenian

    /// The word the site prints on `magshow.php`, which is what a parse of
    /// that page has to match.
    init?(siteWord: String) {
        switch siteWord.trimmingCharacters(in: .whitespaces).lowercased() {
        case "srpski":                 self = .serbian
        case "hrvatski", "srbohrvaški": self = .croatian
        case "slovenski", "slovenščina": self = .slovenian
        default: return nil
        }
    }

    public var display: String {
        switch self {
        case .serbian:   return "Serbian"
        case .croatian:  return "Croatian"
        case .slovenian: return "Slovenian"
        }
    }
}

/// One magazine run on RetroSpec.
///
/// The site has no series field: what identifies a run is the prefix of the
/// per-issue id — `SK_84_10` is Svet Kompjutera, `MMH_85_01` is the
/// Serbo-Croatian Moj Mikro. That prefix is the only reliable key, because a
/// single index page can carry several runs (`indexSpecial.html` holds five)
/// and the headings separating them are sometimes a GIF, sometimes plain
/// text, and sometimes absent.
public struct RetroSpecSeries: Equatable, Sendable {
    /// The id prefix, exactly as the site writes it.
    public let key: String
    /// How the series should read on screen and in the filter menu.
    public let name: String
    /// Short form for the shelf mark, in place of initials.
    public let code: String
    /// Nil for the books, which are not a periodical and carry no language
    /// on their pages.
    public let language: RetroSpecLanguage?

    public init(key: String, name: String, code: String, language: RetroSpecLanguage?) {
        self.key = key; self.name = name; self.code = code; self.language = language
    }
}

public enum RetroSpecSeriesTable {

    /// Every run the site publishes, keyed by id prefix.
    ///
    /// The names are the ones `magshow.php` gives, with two corrections. The
    /// site's own database has lost a character in "Računari" and "Mala
    /// Računala" — it serves a literal `?` byte where the `č` belongs, in
    /// every encoding — so those two are spelled correctly here rather than
    /// reproducing a database fault on the shelf.
    ///
    /// Moj Mikro is the one run the site names ambiguously: both editions are
    /// "Moj Mikro", distinguished only by a `[Hrv]` suffix on one. Naming
    /// them for their language makes the two filter entries tell each other
    /// apart, which is the whole reason they are separate series.
    public static let all: [RetroSpecSeries] = [
        RetroSpecSeries(key: "SK",     name: "Svet Kompjutera", code: "SK",   language: .serbian),
        RetroSpecSeries(key: "RA",     name: "Računari",        code: "RA",   language: .serbian),
        RetroSpecSeries(key: "MMS",    name: "Moj Mikro (SLO)", code: "MMS",  language: .slovenian),
        RetroSpecSeries(key: "GAL",    name: "Galaksija",       code: "GAL",  language: .serbian),
        RetroSpecSeries(key: "MMH",    name: "Moj Mikro (HR)",  code: "MMH",  language: .croatian),
        RetroSpecSeries(key: "MG",     name: "Megazin",         code: "MG",   language: .slovenian),
        RetroSpecSeries(key: "BIT",    name: "BIT",             code: "BIT",  language: .slovenian),
        RetroSpecSeries(key: "SI",     name: "Svet Igara",      code: "SI",   language: .serbian),
        RetroSpecSeries(key: "CN",     name: "Club Nintendo",   code: "CN",   language: .slovenian),
        RetroSpecSeries(key: "AmSt",   name: "Amiga Style",     code: "AS",   language: .serbian),
        RetroSpecSeries(key: "PV",     name: "Pilot Video",     code: "PV",   language: .croatian),
        RetroSpecSeries(key: "Warp",   name: "Warp",            code: "WARP", language: .croatian),
        RetroSpecSeries(key: "MR",     name: "Mala Računala",   code: "MR",   language: .croatian),
        RetroSpecSeries(key: "AmSv",   name: "Amiga Svet",      code: "ASv",  language: .serbian),
        RetroSpecSeries(key: "KOM",    name: "Kompjuter",       code: "KOM",  language: .serbian),
        RetroSpecSeries(key: "MA",     name: "Master",          code: "MA",   language: .croatian),
        RetroSpecSeries(key: "MCW",    name: "Micro Computer",  code: "MCW",  language: .serbian),
        RetroSpecSeries(key: "PJ",     name: "PlayJoy",         code: "PJ",   language: .serbian),
        // Not a magazine run: a dozen computer books, each a single volume.
        // They share a prefix on the site and belong together on the shelf,
        // so they are one "series" whose issues are titled rather than dated.
        RetroSpecSeries(key: "Knjige", name: "Knjige",          code: "KNJ",  language: nil),
    ]

    private static let byKey: [String: RetroSpecSeries] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    public static func series(forKey key: String) -> RetroSpecSeries? { byKey[key] }

    /// The run an issue id belongs to.
    ///
    /// Split on the first underscore: every id is `<prefix>_<rest>`, whether
    /// the rest is a date (`SK_84_10`) or a book's short name
    /// (`Knjige_Mirko`).
    public static func series(forIssueID id: String) -> RetroSpecSeries? {
        guard let prefix = id.split(separator: "_", maxSplits: 1).first else { return nil }
        return byKey[String(prefix)]
    }
}
