import Foundation

/// One run of a magazine on archive.org, and the items that are its issues.
///
/// Nothing like `RetroSpecSeries`, which keys off a prefix the site puts in
/// every id. archive.org has no such thing: an identifier is whatever its
/// uploader typed, and the two runs here are spelled
/// "a-profy-yugoslav-amiga-fanzine-1-july-1990" and "amiga-bilten-1". So the
/// grouping is stated rather than derived, and stating it is also what picks
/// which of the archive's millions of items this app ships.
public struct ArchiveOrgSeries: Equatable, Sendable {
    /// Key for the shipped catalogue, and nothing a reader sees.
    public let key: String
    /// How the run reads on the shelf and in the filter menu.
    public let name: String
    /// Short form for the shelf mark.
    public let code: String
    /// What it was published in — which is what its months are named in.
    public let language: Language
    /// Its issues, oldest first. The order is the issue numbering: these are
    /// short runs picked by hand, so the person adding one puts it where it
    /// belongs rather than leaving a sort to infer it from dates that
    /// archive.org states to varying precision.
    public let items: [String]

    public init(key: String, name: String, code: String,
                language: Language, items: [String]) {
        self.key = key; self.name = name; self.code = code
        self.language = language; self.items = items
    }
}

/// What the app ships from archive.org.
///
/// A hand-picked list, and meant to stay one. The archive holds millions of
/// items and no index of "ex-Yugoslav computer magazines" to walk, so what
/// belongs here is a judgement rather than a crawl — which is why adding a run
/// is an edit to this table plus `swift run archive-build`, and needs no code.
public enum ArchiveOrgLibrary {

    public static let series: [ArchiveOrgSeries] = [
        // Two issues, July and August 1990, and the whole run: the fanzine
        // folded after the second.
        ArchiveOrgSeries(
            key: "a-profy", name: "A-Profy", code: "AP", language: .serbian,
            items: ["a-profy-yugoslav-amiga-fanzine-1-july-1990",
                    "a-profy-yugoslav-amiga-fanzine-2-august-1990"]),
        // Likewise: September and October 1988, out of Tuzla, and that was
        // the lot.
        ArchiveOrgSeries(
            key: "amiga-bilten", name: "Amiga Bilten", code: "AB", language: .bosnian,
            items: ["amiga-bilten-1", "amiga-bilten-2"]),
    ]

    /// Every identifier the catalogue is built from, in one list.
    public static var items: [String] { series.flatMap(\.items) }

    /// Which run an item belongs to.
    public static func series(forItem identifier: String) -> ArchiveOrgSeries? {
        series.first { $0.items.contains(identifier) }
    }

    // MARK: - Titles

    /// What the shelf calls an issue: "Septembar 1988".
    ///
    /// The same shape RetroSpec's issues carry, so a shelf showing both reads
    /// as one shelf. RetroSpec takes the month name off the site; archive.org
    /// states the date as digits, so the name comes from the run's language
    /// and the table below.
    ///
    /// A year with no month is titled by the year alone, which is what
    /// RetroSpec does with the two magazines it dates that way.
    public static func title(year: Int?, month: Int?, language: Language) -> String? {
        guard let year else { return nil }
        guard let month, let name = monthName(month, in: language) else { return String(year) }
        return "\(name) \(year)"
    }

    /// Month names, in the languages the shipped runs are actually published
    /// in.
    ///
    /// Serbian and Bosnian name the months identically — both took the Latin
    /// set, unlike Croatian's *siječanj, veljača, ožujak* — so one table
    /// serves both, and the two are listed separately anyway because a run
    /// records the language it was published in, not the table it uses.
    ///
    /// Croatian and Slovenian are absent, and should stay absent until
    /// something ships in them: RetroSpec's issues, which are in all four
    /// languages, take their month names off the site itself and would never
    /// consult this. A table nothing reads is a table nothing catches errors
    /// in.
    static func monthName(_ month: Int, in language: Language) -> String? {
        guard (1...12).contains(month) else { return nil }
        switch language {
        case .serbian, .bosnian:
            return ["Januar", "Februar", "Mart", "April", "Maj", "Jun",
                    "Jul", "Avgust", "Septembar", "Oktobar", "Novembar",
                    "Decembar"][month - 1]
        case .croatian, .slovenian:
            return nil
        }
    }
}
