import Foundation

extension Store {

    public struct BackfillResult: Equatable, Sendable {
        public var probed = 0
        public var titled = 0
        public var failed = 0
        public var mismatched = 0
    }

    struct PendingProbe {
        let mirrorID: Int
        let issueID: Int
        let url: String
        let issueNumber: Int?
        let hasTitle: Bool
    }

    /// Un-probed mirrors belonging to issues that still have no title.
    ///
    /// The backfill will happily probe every mirror in the library, but only
    /// these change what the user sees. Probing is throttled to avoid getting
    /// the IP blocked, so at ~1.5s each the difference is minutes rather than
    /// most of an hour.
    public var untitledMirrorCount: Int {
        (try? db.scalarInt("""
            SELECT COUNT(*) FROM mirror m JOIN issue i ON i.id = m.issue_id
            WHERE m.filename IS NULL AND i.title IS NULL
            """)) ?? 0
    }

    /// Mirrors whose filename we have never resolved. Probe results are
    /// permanent, so this list only ever shrinks.
    func pendingProbes(limit: Int) throws -> [PendingProbe] {
        var out: [PendingProbe] = []
        try db.query("""
            SELECT m.id, m.issue_id, m.url, i.number, i.title IS NOT NULL
            FROM mirror m JOIN issue i ON i.id = m.issue_id
            WHERE m.filename IS NULL
            ORDER BY (i.title IS NULL) DESC, m.ordinal ASC
            LIMIT ?
            """, [.int(Int64(limit))]) { row in
            out.append(PendingProbe(mirrorID: row.int(0) ?? 0,
                                    issueID: row.int(1) ?? 0,
                                    url: row.string(2) ?? "",
                                    issueNumber: row.int(3),
                                    hasTitle: (row.int(4) ?? 0) == 1))
        }
        return out
    }

    /// Resolves filenames for un-probed mirrors and fills in missing titles.
    ///
    /// This is what gives `labeledBlock` issues (Mister No: a code, no title)
    /// a name. Ordered so title-less issues are probed first — those are the
    /// ones a user cannot currently find by searching.
    @discardableResult
    public func backfillTitles(registry: HostRegistry = HostRegistry(),
                               via transport: Transport,
                               limit: Int = 50) async throws -> BackfillResult {
        var result = BackfillResult()
        for pending in try pendingProbes(limit: limit) {
            guard let url = URL(string: pending.url) else { result.failed += 1; continue }
            let meta: FileMeta
            do {
                meta = try await registry.probe(url, via: transport)
            } catch {
                result.failed += 1
                continue
            }
            result.probed += 1
            try recordProbe(mirrorID: pending.mirrorID, meta: meta)

            guard let filename = meta.filename else { continue }
            let parsed = TitleCleaner.parse(filename)

            // Cross-check the label against the file's own metadata. The forum
            // label can be wrong — one confirmed case in the corpus pointed at
            // a different comic entirely — and trusting it silently would show
            // the wrong title for a file the user then downloads.
            if let labelNumber = pending.issueNumber {
                let numbers = Set(Rx(#"\d{1,5}"#).allMatches(filename).compactMap { Int($0) })
                if !numbers.contains(labelNumber) {
                    result.mismatched += 1
                    try db.run("UPDATE issue SET verified = -1 WHERE id = ?",
                               [.int(Int64(pending.issueID))])
                    continue        // do not overwrite a title from a file we distrust
                }
                try db.run("UPDATE issue SET verified = 1 WHERE id = ?",
                           [.int(Int64(pending.issueID))])
            }

            guard !pending.hasTitle,
                  let title = parsed.title, TitleCleaner.isPlausible(title) else { continue }
            // Scanners shout inconsistently; the shelf should not.
            try setTitle(issueID: pending.issueID, title: TitleCleaner.normaliseCase(title))
            result.titled += 1
        }
        return result
    }

    /// Evens out titles stored before casing was normalised.
    ///
    /// Runs at open, and only rewrites rows it actually changes, so it costs a
    /// single scan once and nothing thereafter. Goes through `setTitle` rather
    /// than a bulk UPDATE so the FTS index is rebuilt in step — a title changed
    /// behind the index's back stops matching what the user types.
    func normaliseStoredTitles() {
        var rows: [(Int, String)] = []
        try? db.query("SELECT id, title FROM issue WHERE title IS NOT NULL") { row in
            if let id = row.int(0), let title = row.string(1) { rows.append((id, title)) }
        }
        for (id, title) in rows {
            let tidied = TitleCleaner.normaliseCase(title)
            if tidied != title { try? setTitle(issueID: id, title: tidied) }
        }
    }

    func recordProbe(mirrorID: Int, meta: FileMeta) throws {
        try db.run("UPDATE mirror SET filename = ?, size = ? WHERE id = ?",
                   [SQLValue(meta.filename), SQLValue(meta.size), .int(Int64(mirrorID))])
    }

    /// Updates the title and keeps the FTS index in step.
    ///
    /// The index covers code, number, series and forum context as well, so the
    /// whole row is recomputed — refreshing only the title would drop the rest
    /// and quietly make the issue unfindable by publisher or hero.
    func setTitle(issueID: Int, title: String) throws {
        var code: String?, series: String?, context: String?
        var number: Int?
        try db.query("SELECT code, number, series, context FROM issue WHERE id = ?",
                     [.int(Int64(issueID))]) { row in
            code = row.string(0); number = row.int(1)
            series = row.string(2); context = row.string(3)
        }
        // `title_folded` is deliberately NOT updated. It is the row's identity
        // — part of the natural key `(code, number, title_folded)` that
        // re-import matches on — and it records the label as the page carried
        // it. Rewriting it to the resolved title changed the row's identity, so
        // the next import of the same page matched nothing and inserted every
        // issue a second time. Search does not use it; that goes through
        // `search_text` and the FTS index.
        let searchText = Store.searchText(title: title, code: code, number: number,
                                          series: series, context: context)
        try db.run("""
            UPDATE issue SET title = ?, search_text = ? WHERE id = ?
            """, [.text(title), .text(searchText), .int(Int64(issueID))])
        try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(Int64(issueID))])
        try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                   [.int(Int64(issueID)), .text(searchText)])
    }

    /// Issues still waiting for a name *and* still resolvable — untitled, with
    /// at least one mirror never probed.
    ///
    /// Counted in issues rather than mirrors: an issue usually has two mirrors
    /// but only needs one probed, so mirrors would overstate the work by about
    /// double. Excluding the unresolvable ones matters too — an untitled issue
    /// whose mirrors have all been probed can never be named, and counting it
    /// would leave a progress readout permanently short of its total.
    public var untitledIssueCount: Int {
        (try? db.scalarInt("""
            SELECT COUNT(DISTINCT i.id) FROM issue i JOIN mirror m ON m.issue_id = i.id
            WHERE m.filename IS NULL AND i.title IS NULL
            """)) ?? 0
    }

    /// Largest recorded size among an issue's mirrors, if any were probed.
    ///
    /// Nil means no mirror has been probed yet, which is not the same as zero
    /// — a caller must not read it as "this file is empty".
    public func knownSize(forIssue issueID: Int) throws -> Int64? {
        var out: Int64?
        try db.query("SELECT MAX(size) FROM mirror WHERE issue_id = ? AND size IS NOT NULL",
                     [.int(Int64(issueID))]) { row in
            if let value = row.int(0), value > 0 { out = Int64(value) }
        }
        return out
    }

    public func recordFilename(_ filename: String, forMirrorAt url: String) throws {
        try db.run("UPDATE mirror SET filename = ? WHERE url = ?",
                   [.text(filename), .text(url)])
    }

    public func recordSize(_ size: Int64, forMirrorAt url: String) throws {
        try db.run("UPDATE mirror SET size = ? WHERE url = ?", [.int(size), .text(url)])
    }

    public func filename(forMirrorAt url: String) throws -> String? {
        var out: String?
        try db.query("SELECT filename FROM mirror WHERE url = ?", [.text(url)]) { out = $0.string(0) }
        return out
    }
}
