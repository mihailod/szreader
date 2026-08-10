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
            try setTitle(issueID: pending.issueID, title: title)
            result.titled += 1
        }
        return result
    }

    func recordProbe(mirrorID: Int, meta: FileMeta) throws {
        try db.run("UPDATE mirror SET filename = ?, size = ? WHERE id = ?",
                   [SQLValue(meta.filename), SQLValue(meta.size), .int(Int64(mirrorID))])
    }

    /// Updates the title and keeps the FTS index in step.
    func setTitle(issueID: Int, title: String) throws {
        let folded = Fold.fold(title)
        try db.run("UPDATE issue SET title = ?, title_folded = ? WHERE id = ?",
                   [.text(title), .text(folded), .int(Int64(issueID))])
        try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(Int64(issueID))])
        try db.run("INSERT INTO issue_fts (rowid, title_folded) VALUES (?, ?)",
                   [.int(Int64(issueID)), .text(folded)])
    }

    public var untitledIssueCount: Int {
        (try? db.scalarInt("SELECT COUNT(*) FROM issue WHERE title IS NULL")) ?? 0
    }

    public func filename(forMirrorAt url: String) throws -> String? {
        var out: String?
        try db.query("SELECT filename FROM mirror WHERE url = ?", [.text(url)]) { out = $0.string(0) }
        return out
    }
}
