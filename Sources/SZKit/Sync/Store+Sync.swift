import Foundation

extension Store {

    /// Issues this device could actually lose.
    ///
    /// Everything the reader brought in by hand and nothing else. A forum page
    /// costs a Like to import and exists nowhere but here; a catalogue row
    /// costs a switch and exists inside the app. On a real library that is
    /// 2,854 rows out of 29,747 — so the exclusion is not a tidiness, it is
    /// the difference between a sync that carries a megabyte and one that
    /// carries thirty thousand records to rebuild what a boolean rebuilds.
    ///
    /// Local Files are excluded too, and for a stronger reason than size:
    /// their row *is* the file being on the device, `reconcileLocalFiles`
    /// deletes any row whose file is not in the folder, and a row synced from
    /// another device would therefore be created and destroyed on the next
    /// scan. Two mechanisms, two rules, and the folder always wins.
    /// - Parameters:
    ///   - afterIssue: only issues added since this rowid.
    ///   - afterMirror: and issues that have gained a link since this one.
    ///
    /// Both default to nothing, which is the whole exportable library — what
    /// the first sync sends. Afterwards they are the high-water marks of what
    /// has already been sent, and rowids are what makes that work: SQLite
    /// hands them out in arrival order, so "greater than the last one sent" is
    /// exactly "arrived since".
    ///
    /// Links are asked about separately because they are the other thing an
    /// import produces. Re-importing a page that has gained an alternate scan
    /// adds a mirror to an issue that is years old and whose rowid moves for
    /// nobody — and that alternate is precisely what the reader will need when
    /// the first link rots.
    ///
    /// What this does *not* catch is a field changing on an issue already
    /// sent: a cover found later by the backfill, say. That waits for a full
    /// resync. Worth knowing, and worth not solving with a dirty flag on every
    /// write path until something actually needs it.
    public func exportableIssues(afterIssue: Int = 0,
                                 afterMirror: Int = 0) throws -> [SyncedIssue] {
        var rows: [(id: Int, issue: SyncedIssue)] = []
        try db.query("""
            SELECT i.id, i.site, i.code, i.number, i.number_to, i.title,
                   i.title_folded, i.series, i.style, i.source, i.context,
                   i.cover_url, i.hero, i.edition, i.publisher, i.page_count,
                   i.catalogue_code, i.catalogue_number
            FROM issue i
            WHERE i.site <> ?
              AND IFNULL(i.source, '') <> (i.site || ' catalogue')
              AND (i.id > ? OR EXISTS (SELECT 1 FROM mirror m
                                       WHERE m.issue_id = i.id AND m.id > ?))
            ORDER BY i.id
            """, [.text(IssueSite.local.rawValue), .int(Int64(afterIssue)),
                  .int(Int64(afterMirror))]) { row in
            guard let id = row.int(0),
                  let site = IssueSite(rawValue: row.string(1) ?? ""),
                  let folded = row.string(6) else { return }
            rows.append((id, SyncedIssue(
                site: site,
                code: row.string(2), number: row.int(3), numberTo: row.int(4),
                title: row.string(5), titleFolded: folded, series: row.string(7),
                style: LabelStyle(rawValue: row.string(8) ?? "") ?? .labeledBlock,
                source: row.string(9), context: row.string(10),
                coverURL: row.string(11), hero: row.string(12),
                edition: row.string(13), publisher: row.string(14),
                pageCount: row.int(15), catalogueCode: row.string(16),
                catalogueNumber: row.int(17), mirrors: [])))
        }

        // The links, in one pass rather than a statement per issue: this runs
        // over the whole exportable library, and a few thousand round trips
        // through the connection lock is a visible pause for an answer that is
        // one scan of a table with an index on `issue_id`.
        var byIssue: [Int: [SyncedMirror]] = [:]
        try db.query("""
            SELECT m.issue_id, m.url, m.host, m.ordinal, m.filename, m.size
            FROM mirror m JOIN issue i ON i.id = m.issue_id
            WHERE i.site <> ?
              AND IFNULL(i.source, '') <> (i.site || ' catalogue')
              AND (i.id > ? OR EXISTS (SELECT 1 FROM mirror m2
                                       WHERE m2.issue_id = i.id AND m2.id > ?))
            ORDER BY m.issue_id, m.ordinal
            """, [.text(IssueSite.local.rawValue), .int(Int64(afterIssue)),
                  .int(Int64(afterMirror))]) { row in
            guard let id = row.int(0), let url = row.string(1) else { return }
            byIssue[id, default: []].append(
                SyncedMirror(url: url, host: row.string(2) ?? "?",
                             ordinal: row.int(3) ?? 0, filename: row.string(4),
                             size: row.int(5).map(Int64.init)))
        }

        return rows.map { row in
            guard let mirrors = byIssue[row.id] else { return row.issue }
            return SyncedIssue(
                site: row.issue.site, code: row.issue.code, number: row.issue.number,
                numberTo: row.issue.numberTo, title: row.issue.title,
                titleFolded: row.issue.titleFolded, series: row.issue.series,
                style: row.issue.style, source: row.issue.source,
                context: row.issue.context, coverURL: row.issue.coverURL,
                hero: row.issue.hero, edition: row.issue.edition,
                publisher: row.issue.publisher, pageCount: row.issue.pageCount,
                catalogueCode: row.issue.catalogueCode,
                catalogueNumber: row.issue.catalogueNumber, mirrors: mirrors)
        }
    }

    /// Takes in issues from the reader's other devices.
    ///
    /// Additive, and deliberately so. This is the merge that runs when sync is
    /// switched on, where each device holds a set the others have never seen
    /// and the only acceptable outcome is that nobody loses anything: an issue
    /// missing here is added, an issue already here keeps every value it has
    /// and fills in only the blanks, and links are pooled.
    ///
    /// **Union is right for this merge and wrong as a standing rule.** Once
    /// every device holds the same set, "add whatever the other one has" turns
    /// a deletion into a round trip — remove an issue here, and the next merge
    /// brings it back from a device that had not heard. That needs deletions
    /// carried as their own fact rather than inferred from absence, which is a
    /// later piece of work; this one cannot lose data, which is what the first
    /// merge has to guarantee.
    @discardableResult
    public func merge(_ issues: [SyncedIssue]) throws -> SyncMergeReport {
        var report = SyncMergeReport()
        // Batched, in the seeder's shape and for the seeder's reason: one
        // transaction around thousands of inserts holds the connection for the
        // length of the whole merge, and this runs while a reader is looking
        // at the shelf.
        for chunk in stride(from: 0, to: issues.count, by: 400).map({
            Array(issues[$0..<min($0 + 400, issues.count)])
        }) {
            try db.transaction {
                for issue in chunk { try absorb(issue, into: &report) }
            }
        }
        return report
    }

    private func absorb(_ issue: SyncedIssue, into report: inout SyncMergeReport) throws {
        // Nothing that belongs to a device may be taken from one. A catalogue
        // row is rebuilt from the app bundle and a local file is the folder on
        // this device; accepting either would put a row here that the seeder
        // or the folder scan is entitled to contradict.
        guard issue.site != .local,
              issue.source != Self.catalogueSource(for: issue.site) else {
            report.declined += 1
            return
        }

        let id: Int64
        if let existing = try issueID(matching: issue.identity) {
            id = existing
            if try enrich(existing, with: issue) { report.enriched += 1 }
        } else {
            id = try insert(issue)
            report.added += 1
        }

        for mirror in issue.mirrors {
            // `url` is UNIQUE across the whole table, so a link already known
            // — to this issue or, in the odd case a host serves one file for
            // two rows, to another — is left where it is.
            try db.run("""
                INSERT OR IGNORE INTO mirror (issue_id, url, host, ordinal, filename, size)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [.int(id), .text(mirror.url), .text(mirror.host),
                      .int(Int64(mirror.ordinal)), SQLValue(mirror.filename),
                      mirror.size.map { SQLValue.int($0) } ?? .null])
            if try db.scalarInt("SELECT changes()") > 0 { report.mirrors += 1 }
        }
    }

    /// The row an identity names, or nil.
    ///
    /// Must match `issue_identity_v3` term for term, exactly as the import's
    /// own lookup does. This one is site-generic where that one is not: it
    /// answers for whichever archive the identity names, because an issue
    /// arriving from another device can be from any of them.
    func issueID(matching identity: IssueIdentity) throws -> Int64? {
        var found: Int64?
        try db.query("""
            SELECT id FROM issue
            WHERE site = ? AND IFNULL(code,'') = ? AND IFNULL(number,-1) = ?
              AND title_folded = ? AND IFNULL(series,'') = ?
            """, [.text(identity.site.rawValue), .text(identity.code),
                  .int(Int64(identity.number)), .text(identity.titleFolded),
                  .text(identity.series)]) { row in
            found = row.int(0).map(Int64.init)
        }
        return found
    }

    private func insert(_ issue: SyncedIssue) throws -> Int64 {
        let search = Self.searchText(title: issue.title, code: issue.code,
                                     number: issue.number, series: issue.series,
                                     context: issue.context)
        let id = try db.run("""
            INSERT INTO issue
              (code, number, number_to, title, title_folded, series, style, source,
               context, search_text, cover_url, hero, edition, publisher, site,
               page_count, catalogue_code, catalogue_number)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [SQLValue(issue.code), SQLValue(issue.number), SQLValue(issue.numberTo),
                  SQLValue(issue.title), .text(issue.titleFolded), SQLValue(issue.series),
                  .text(issue.style.rawValue), SQLValue(issue.source),
                  SQLValue(issue.context), .text(search), SQLValue(issue.coverURL),
                  SQLValue(issue.hero), SQLValue(issue.edition), SQLValue(issue.publisher),
                  .text(issue.site.rawValue), SQLValue(issue.pageCount),
                  SQLValue(issue.catalogueCode), SQLValue(issue.catalogueNumber)])

        // FTS is a virtual table with no foreign keys and no triggers here: it
        // is maintained by hand at every insert, and an issue that misses this
        // is on the shelf and cannot be found by typing its name. Deleted
        // first because SQLite reuses the rowid of a deleted issue, and a
        // leftover index row under that id fails the insert — which would
        // abort the whole batch rather than one issue.
        try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(id)])
        try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                   [.int(id), .text(search)])
        return id
    }

    /// Fills in what this row is missing, and changes nothing it already has.
    ///
    /// `COALESCE` throughout, which is the same rule a re-import already
    /// applies: new evidence about an issue is welcome, and a device that
    /// knows less than this one must not be able to blank a field by not
    /// knowing it. Returns whether anything actually moved, so a merge that
    /// found nothing new can say so rather than reporting work it did not do.
    private func enrich(_ id: Int64, with issue: SyncedIssue) throws -> Bool {
        let before = try filledFields(id)
        try db.run("""
            UPDATE issue SET cover_url = COALESCE(cover_url, ?),
                             hero = COALESCE(hero, ?),
                             edition = COALESCE(edition, ?),
                             publisher = COALESCE(publisher, ?),
                             page_count = COALESCE(page_count, ?),
                             number_to = COALESCE(number_to, ?),
                             catalogue_code = COALESCE(catalogue_code, ?),
                             catalogue_number = COALESCE(catalogue_number, ?),
                             context = COALESCE(context, ?)
            WHERE id = ?
            """, [SQLValue(issue.coverURL), SQLValue(issue.hero), SQLValue(issue.edition),
                  SQLValue(issue.publisher), SQLValue(issue.pageCount),
                  SQLValue(issue.numberTo), SQLValue(issue.catalogueCode),
                  SQLValue(issue.catalogueNumber), SQLValue(issue.context),
                  .int(id)])
        return try filledFields(id) != before
    }

    /// How many of the fields a merge can fill are filled.
    ///
    /// Counted rather than compared value by value because the only question
    /// is whether a blank became something; `COALESCE` cannot turn a value
    /// into a different value, so the count moving is exactly equivalent to
    /// the row having changed.
    private func filledFields(_ id: Int64) throws -> Int {
        try db.scalarInt("""
            SELECT (cover_url IS NOT NULL) + (hero IS NOT NULL) + (edition IS NOT NULL)
                 + (publisher IS NOT NULL) + (page_count IS NOT NULL)
                 + (number_to IS NOT NULL) + (catalogue_code IS NOT NULL)
                 + (catalogue_number IS NOT NULL) + (context IS NOT NULL)
            FROM issue WHERE id = ?
            """, [.int(id)])
    }
}

// MARK: - Where a sync got to

/// How far this device has got with the account, kept in `meta` beside the
/// catalogue stamps — small facts about the library rather than about any
/// issue, which is exactly what that table is for.
extension Store {

    /// The high-water marks of what has already been sent up.
    public struct SyncMarks: Equatable, Sendable {
        public var issue: Int
        public var mirror: Int
        public init(issue: Int = 0, mirror: Int = 0) {
            self.issue = issue; self.mirror = mirror
        }
    }

    private func metaValue(_ key: String) throws -> String? {
        var found: String?
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { row in
            found = row.string(0)
        }
        return found
    }

    private func setMetaValue(_ value: String?, forKey key: String) throws {
        guard let value else {
            try db.run("DELETE FROM meta WHERE key = ?", [.text(key)])
            return
        }
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                   [.text(key), .text(value)])
    }

    /// Where the account's own change feed had got to when this device last
    /// looked. Opaque here on purpose: it is the server's bookmark, and
    /// nothing outside the transport has any business reading it.
    public func syncCursor() throws -> SyncCursor? {
        try metaValue("sync_cursor").flatMap { Data(base64Encoded: $0) }
            .map(SyncCursor.init(data:))
    }

    public func setSyncCursor(_ cursor: SyncCursor?) throws {
        try setMetaValue(cursor?.data.base64EncodedString(), forKey: "sync_cursor")
    }

    public func syncMarks() throws -> SyncMarks {
        SyncMarks(issue: Int(try metaValue("sync_pushed_issue") ?? "") ?? 0,
                  mirror: Int(try metaValue("sync_pushed_mirror") ?? "") ?? 0)
    }

    public func setSyncMarks(_ marks: SyncMarks) throws {
        try setMetaValue(String(marks.issue), forKey: "sync_pushed_issue")
        try setMetaValue(String(marks.mirror), forKey: "sync_pushed_mirror")
    }

    /// The highest rowids in the library right now.
    public func currentSyncMarks() throws -> SyncMarks {
        SyncMarks(issue: try db.scalarInt("SELECT IFNULL(MAX(id), 0) FROM issue"),
                  mirror: try db.scalarInt("SELECT IFNULL(MAX(id), 0) FROM mirror"))
    }

    /// Forgets everything about the account, so the next sync is a first one.
    ///
    /// The way back from a library that has drifted — and the only way to send
    /// a change to an issue already up there, which the rowid marks cannot
    /// see. Nothing local is touched: a full resync re-sends what is here and
    /// re-reads what is there, and both sides merge by union.
    public func forgetSyncState() throws {
        try setSyncCursor(nil)
        try setSyncMarks(SyncMarks())
    }
}
