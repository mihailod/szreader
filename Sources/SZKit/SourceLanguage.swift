import Foundation

/// The language the issues on a source are in, as one switch above the
/// sources themselves.
///
/// There are nineteen switches in Settings now, and a reader who reads one
/// language wants most of them off — which today means finding and moving
/// them one at a time. This is not a new kind of setting and stores nothing
/// of its own: each language moves the same per-source flags the list below
/// it shows, so the two can never disagree about what is on.
public enum SourceLanguage: String, CaseIterable, Sendable {
    /// The Serbian and Croatian shelves.
    case exYU
    /// Everything else.
    case english

    /// How the language is spelled in front of a reader. A name rather than
    /// prose, for the same reason `IssueSite.display` is here and the
    /// sentence under the switch is not — see `SourceCopy`.
    public var display: String {
        switch self {
        case .exYU:    return "ex-YU (Serbian, Croatian)"
        case .english: return "English"
        }
    }

    /// The sources this language alone decides.
    ///
    /// English is derived rather than listed, so a source added later belongs
    /// to a language without this file being touched — and a new source can
    /// never end up in neither.
    ///
    /// `sharedSites` is in neither list, deliberately: archive.org holds every
    /// language, so it answers to both switches and to neither's question of
    /// whether *this* language is showing.
    public var sites: [IssueSite] {
        switch self {
        case .exYU:
            return Self.exYUSites
        case .english:
            return IssueSite.allCases.filter {
                !Self.exYUSites.contains($0) && !Self.sharedSites.contains($0)
            }
        }
    }

    private static let exYUSites: [IssueSite] = [.stripzona, .stripovi, .retrospec]

    /// Sources that carry every language, and so stay on for as long as any
    /// language is on.
    public static let sharedSites: [IssueSite] = [.archive]
}
