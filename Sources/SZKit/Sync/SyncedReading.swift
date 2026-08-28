import Foundation

/// Where the reader got to, as it travels between devices.
///
/// Separate from `SyncedIssue`, and not for tidiness. It applies to issues
/// that type never carries: nine rows in ten come from a catalogue shipped
/// inside the app, are rebuilt on the other device by a switch, and are
/// exactly the issues somebody is part-way through. Reading state keyed by
/// identity attaches to whichever local row matches, catalogue or imported,
/// without either having to be sent.
///
/// It also merges by a different rule. A pointer merges by union — two devices
/// that each know something about an issue both turn out to be right. Where
/// somebody got to has one answer, and the newest one is it.
public struct SyncedReading: Equatable, Sendable {
    public let identity: IssueIdentity
    /// When the reader marked it read. Nil means not read, and that is a
    /// position rather than an absence of information.
    public let readAt: Date?
    /// When reading first got past the cover.
    public let startedAt: Date?
    /// When it was last on screen.
    public let openedAt: Date?
    /// Furthest page reached, zero-based.
    public let lastPage: Int?
    /// When any of the above last moved on the device that sent it.
    ///
    /// The whole merge turns on this, which is why it is stored rather than
    /// derived. Unmarking an issue *clears* `readAt` and `startedAt`, so
    /// "latest of the timestamps above" would run backwards — and a device
    /// still holding the old values would win every merge and put the mark
    /// back, for ever.
    public let modifiedAt: Date

    public init(identity: IssueIdentity, readAt: Date?, startedAt: Date?,
                openedAt: Date?, lastPage: Int?, modifiedAt: Date) {
        self.identity = identity
        self.readAt = readAt
        self.startedAt = startedAt
        self.openedAt = openedAt
        self.lastPage = lastPage
        self.modifiedAt = modifiedAt
    }

    /// Distinct from the issue's own record name: both live in one zone, and a
    /// zone holds one record per name whatever its type.
    public var recordName: String { "reading-" + identity.recordName }

    /// Whether this says anything at all. An issue nobody has touched has no
    /// reading state to carry, and sending one would be a record per issue in
    /// the library for no information.
    public var isEmpty: Bool {
        readAt == nil && startedAt == nil && openedAt == nil && lastPage == nil
    }
}

extension Store {

    /// Reading positions this device has that the account may not.
    ///
    /// - Parameter since: only what has moved since this moment. A timestamp
    ///   rather than a rowid, because reading state moves on rows that are
    ///   years old — which is the normal case, not the exception.
    public func exportableReading(since: Date? = nil) throws -> [SyncedReading] {
        var out: [SyncedReading] = []
        try db.query("""
            SELECT site, code, number, title_folded, series,
                   read_at, started_at, opened_at, last_page, read_state_at
            FROM issue
            WHERE read_state_at IS NOT NULL AND read_state_at > ?
            ORDER BY read_state_at
            """, [.double(since?.timeIntervalSince1970 ?? 0)]) { row in
            guard let site = IssueSite(rawValue: row.string(0) ?? ""),
                  let folded = row.string(3),
                  let modified = row.double(9) else { return }
            out.append(SyncedReading(
                identity: IssueIdentity(site: site, code: row.string(1),
                                        number: row.int(2), titleFolded: folded,
                                        series: row.string(4)),
                readAt: row.double(5).map(Date.init(timeIntervalSince1970:)),
                startedAt: row.double(6).map(Date.init(timeIntervalSince1970:)),
                openedAt: row.double(7).map(Date.init(timeIntervalSince1970:)),
                lastPage: row.int(8),
                modifiedAt: Date(timeIntervalSince1970: modified)))
        }
        return out
    }

    /// The newest reading state this device has recorded, so the next export
    /// can ask for what has moved since.
    public func latestReadingChange() throws -> Date? {
        var out: Date?
        try db.query("SELECT MAX(read_state_at) FROM issue") { row in
            out = row.double(0).map(Date.init(timeIntervalSince1970:))
        }
        return out
    }

    /// Takes in reading positions from the reader's other devices.
    ///
    /// Newest wins, whole. Not field by field, which is the tempting version:
    /// three of these four are monotonic, so taking the maximum of each looks
    /// safe and is not. Unmarking an issue clears two of them at once, and a
    /// per-field maximum would restore both from the other device's older copy
    /// — leaving an issue that cannot be unmarked while a second device
    /// exists.
    ///
    /// An issue the account knows about and this device does not is skipped,
    /// not created. Reading state is about a row, not a row in itself: the
    /// pointer arrives through `merge`, or the catalogue rebuilds it when its
    /// switch is thrown, and the state is applied whenever the row turns up.
    @discardableResult
    public func mergeReading(_ states: [SyncedReading]) throws -> Int {
        var applied = 0
        for chunk in stride(from: 0, to: states.count, by: 400).map({
            Array(states[$0..<min($0 + 400, states.count)])
        }) {
            try db.transaction {
                for state in chunk where try apply(state) { applied += 1 }
            }
        }
        return applied
    }

    private func apply(_ state: SyncedReading) throws -> Bool {
        guard let id = try issueID(matching: state.identity) else { return false }

        // Older than what is here already: nothing to do. This is most of what
        // arrives once two devices are in step, and it is also what stops a
        // device that has been away for a month from undoing a month of
        // reading the moment it comes back.
        var here: Double?
        try db.query("SELECT read_state_at FROM issue WHERE id = ?", [.int(id)]) { row in
            here = row.double(0)
        }
        if let here, here >= state.modifiedAt.timeIntervalSince1970 { return false }

        try db.run("""
            UPDATE issue SET read_at = ?, started_at = ?, opened_at = ?,
                             last_page = ?, read_state_at = ?
            WHERE id = ?
            """, [state.readAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
                  state.startedAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
                  state.openedAt.map { SQLValue.double($0.timeIntervalSince1970) } ?? .null,
                  SQLValue(state.lastPage),
                  .double(state.modifiedAt.timeIntervalSince1970), .int(id)])
        return true
    }

    /// How far the account has been told about reading, kept beside the other
    /// sync marks.
    public func readingMark() throws -> Date? {
        var out: Double?
        try db.query("SELECT value FROM meta WHERE key = 'sync_pushed_reading'") { row in
            out = row.string(0).flatMap(Double.init)
        }
        return out.map(Date.init(timeIntervalSince1970:))
    }

    public func setReadingMark(_ date: Date?) throws {
        guard let date else {
            try db.run("DELETE FROM meta WHERE key = 'sync_pushed_reading'")
            return
        }
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES ('sync_pushed_reading', ?)",
                   [.text(String(date.timeIntervalSince1970))])
    }
}
