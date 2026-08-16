import Foundation

/// Which archive an issue came from.
///
/// The two are nothing alike as sources — one is a forum whose topics are
/// imported by hand and whose links point at third-party file hosts, the
/// other a static index shipped with the app that downloads from one server —
/// but they land in the same table on purpose.
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

    /// How the source is spelled in front of a reader.
    public var display: String {
        switch self {
        case .stripzona: return "StripZona"
        case .retrospec: return "RetroSpec"
        }
    }

    /// What a row with no recorded source is.
    ///
    /// Every issue predates the column, so the migration backfills them all
    /// to this and new StripZona imports keep writing it.
    public static let `default` = IssueSite.stripzona
}
