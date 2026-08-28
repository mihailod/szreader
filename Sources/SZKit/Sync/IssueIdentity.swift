import Foundation

/// What names an issue on every device.
///
/// `issue.id` cannot: it is a SQLite rowid, handed out in the order rows
/// happened to arrive, and two devices that enabled the same sources in a
/// different order number the same magazine differently. Everything local is
/// keyed on it — `comics/<id>`, `covers/<id>.jpg`, `download.issue_id` — which
/// is exactly why nothing that leaves the device may be.
///
/// The terms are `issue_identity_v3`'s, and must stay that way term for term.
/// That index is what the library already treats as "the same issue", so an
/// identity narrower than it would merge two rows the database keeps apart,
/// and one wider would import a duplicate of a row already present.
///
/// The empty string and -1 are the index's own sentinels, not inventions here:
/// it reads `IFNULL(code,'')` and `IFNULL(number,-1)`, so an issue with no code
/// and one whose code is the empty string are already the same issue locally
/// and have to stay the same issue across devices.
public struct IssueIdentity: Hashable, Sendable {
    public let site: IssueSite
    /// "" when the issue has none.
    public let code: String
    /// -1 when the issue has none.
    public let number: Int
    /// The stored `title_folded`, never recomputed — see `SyncedIssue`.
    public let titleFolded: String
    /// "" when the issue has none.
    public let series: String

    public init(site: IssueSite, code: String?, number: Int?,
                titleFolded: String, series: String?) {
        self.site = site
        self.code = code ?? ""
        self.number = number ?? -1
        self.titleFolded = titleFolded
        self.series = series ?? ""
    }

    /// The terms joined by a byte none of them can contain.
    ///
    /// ASCII unit separator, which is what it is for. A printable separator
    /// would be ambiguous against real data: titles hold every kind of
    /// punctuation, and a series called "a|b" beside a title "c" must not
    /// collide with a series "a" and a title "b|c".
    static let separator = "\u{1F}"

    var key: String {
        [site.rawValue, code, String(number), titleFolded, series]
            .joined(separator: Self.separator)
    }

    /// A name for this issue that every device computes identically, without
    /// asking anyone.
    ///
    /// This is what makes the merge deduplicate itself: two devices that
    /// imported the same forum page independently produce the same name for
    /// the same issue, so the second one to arrive is recognised as the issue
    /// already there rather than added beside it. Nothing has to be
    /// coordinated, and no device has to be first.
    ///
    /// Hashed rather than sent as the key itself because the key is unbounded
    /// — a title can be any length — while record names are not, and because
    /// it carries the reader's shelf into a string a server keeps. The digest
    /// is stable across launches and platforms, which `Hasher` is emphatically
    /// not: Swift seeds that randomly per process, and using it would rename
    /// every issue on every launch.
    public var recordName: String { SHA256.hex(Data(key.utf8)) }
}
