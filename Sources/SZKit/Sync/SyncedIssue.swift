import Foundation

/// One download link, as it travels between devices.
///
/// `Codable` here rather than in an extension beside the transport: synthesis
/// only happens in the file that declares the type, and the alternative is
/// writing the coding by hand for four fields that need no help.
public struct SyncedMirror: Equatable, Sendable, Codable {
    public let url: String
    public let host: String
    public let ordinal: Int
    /// What the host said the file is called, and how big, where anyone has
    /// asked. Carried rather than left to be rediscovered: finding out costs a
    /// request to a third-party host that rate-limits, and the answer is the
    /// same on every device.
    public let filename: String?
    public let size: Int64?

    public init(url: String, host: String, ordinal: Int,
                filename: String? = nil, size: Int64? = nil) {
        self.url = url; self.host = host; self.ordinal = ordinal
        self.filename = filename; self.size = size
    }
}

/// An issue and its links, in the form that crosses between devices.
///
/// A pointer, not a comic. Everything here is a few hundred bytes of text
/// describing where an issue can be got and how it should read on the shelf.
/// The archive itself never travels: those are third-party files, they are
/// excluded from backup on purpose, and a library of them is measured in
/// gigabytes.
///
/// **Only issues no catalogue can rebuild belong here.** Nine rows in ten come
/// from an index shipped inside the app and are recreated in seconds by
/// throwing the source's switch — which already follows the reader between
/// devices. Sending those would be tens of thousands of records to reconstruct
/// something a boolean reconstructs, and would race the seeder writing the
/// same rows. See `Store.exportableIssues`.
public struct SyncedIssue: Equatable, Sendable {
    public let site: IssueSite
    public let code: String?
    public let number: Int?
    public let numberTo: Int?
    public let title: String?
    /// Carried verbatim rather than recomputed from `title`.
    ///
    /// It is part of the identity, so it has to match byte for byte, and it is
    /// not simply the folded title: the import folds `title ?? code ?? ""`, so
    /// an issue with no title folds its code instead. Recomputing from `title`
    /// alone would give "" for exactly those rows and quietly invent a second
    /// identity for an issue that already has one.
    public let titleFolded: String
    public let series: String?
    public let style: LabelStyle
    /// Where the row came from, kept so provenance survives the crossing.
    public let source: String?
    public let context: String?
    public let coverURL: String?
    public let hero: String?
    public let edition: String?
    public let publisher: String?
    public let pageCount: Int?
    public let catalogueCode: String?
    public let catalogueNumber: Int?
    public let mirrors: [SyncedMirror]

    /// Deliberately absent: `read_at`, `started_at`, `opened_at`, `last_page`,
    /// and everything about downloads.
    ///
    /// Where the reader got to is a different question from what is on the
    /// shelf, it applies to catalogue rows this type never carries, and it
    /// merges by a different rule — the newest answer wins, where a pointer
    /// merges by union. It travels separately, or an issue could not gain a
    /// reading position without its whole row being rewritten.
    public init(site: IssueSite, code: String?, number: Int?, numberTo: Int?,
                title: String?, titleFolded: String, series: String?,
                style: LabelStyle, source: String?, context: String?,
                coverURL: String?, hero: String?, edition: String?,
                publisher: String?, pageCount: Int?,
                catalogueCode: String?, catalogueNumber: Int?,
                mirrors: [SyncedMirror]) {
        self.site = site; self.code = code; self.number = number
        self.numberTo = numberTo; self.title = title; self.titleFolded = titleFolded
        self.series = series; self.style = style; self.source = source
        self.context = context; self.coverURL = coverURL; self.hero = hero
        self.edition = edition; self.publisher = publisher
        self.pageCount = pageCount; self.catalogueCode = catalogueCode
        self.catalogueNumber = catalogueNumber; self.mirrors = mirrors
    }

    public var identity: IssueIdentity {
        IssueIdentity(site: site, code: code, number: number,
                      titleFolded: titleFolded, series: series)
    }

    public var recordName: String { identity.recordName }
}

/// What one merge did.
public struct SyncMergeReport: Equatable, Sendable {
    /// Issues this device had never seen.
    public var added = 0
    /// Issues already here that gained a field they were missing.
    public var enriched = 0
    /// Links added, whether to a new issue or an old one.
    public var mirrors = 0
    /// Offered and declined — a catalogue row, or one of the reader's own
    /// files. Counted rather than ignored, because a number above zero means
    /// some other device is exporting things it should not.
    public var declined = 0

    public init() {}

    public var isEmpty: Bool { added == 0 && enriched == 0 && mirrors == 0 }
}
