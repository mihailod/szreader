import Foundation

/// A library row as it comes back from search.
public struct StoredIssue: Equatable, Sendable {
    public let id: Int
    public let code: String?
    public let number: Int?
    public let title: String?
    public let series: String?
    public let style: LabelStyle
    public let mirrorCount: Int
}

/// The local library: issues, their mirrors, and a folded full-text index.
public final class Store {

    let db: Database   // internal: Store+Backfill reaches in

    public init(path: String = ":memory:") throws {
        db = try Database(path: path)
        try migrate()
    }

    private func migrate() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS issue (
              id           INTEGER PRIMARY KEY,
              code         TEXT,
              number       INTEGER,
              title        TEXT,
              title_folded TEXT NOT NULL,
              series       TEXT,
              style        TEXT NOT NULL,
              source       TEXT,
              verified     INTEGER NOT NULL DEFAULT 0
            );

            -- Natural key. An issue may legitimately appear on several pages,
            -- and re-importing the same page must not duplicate it.
            CREATE UNIQUE INDEX IF NOT EXISTS issue_identity
              ON issue (IFNULL(code,''), IFNULL(number,-1), title_folded);

            CREATE TABLE IF NOT EXISTS mirror (
              id       INTEGER PRIMARY KEY,
              issue_id INTEGER NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
              url      TEXT NOT NULL UNIQUE,
              host     TEXT NOT NULL,
              ordinal  INTEGER NOT NULL,
              filename TEXT,
              size     INTEGER
            );
            CREATE INDEX IF NOT EXISTS mirror_issue ON mirror (issue_id);

            -- Standalone FTS5 over the FOLDED title, with rowid = issue.id.
            -- Folding both sides is what makes "celjusti" find "čeljusti" --
            -- nobody types diacritics into a search field on an iPad.
            CREATE VIRTUAL TABLE IF NOT EXISTS issue_fts USING fts5(title_folded);
            """)
    }

    // MARK: - Ingest

    @discardableResult
    public func ingest(html: String, source: String? = nil) throws -> (issues: Int, mirrors: Int) {
        var newIssues = 0, newMirrors = 0
        try db.execute("BEGIN")
        do {
            for parsed in Catalog.issues(in: html) {
                let folded = Fold.fold(parsed.label.title ?? parsed.label.code ?? "")
                let id = try upsertIssue(parsed, folded: folded, source: source,
                                         inserted: &newIssues)
                for m in parsed.mirrors {
                    // URL is UNIQUE: re-importing a page is a no-op for mirrors.
                    try db.run("""
                        INSERT OR IGNORE INTO mirror (issue_id, url, host, ordinal)
                        VALUES (?, ?, ?, ?)
                        """, [.int(id), .text(m.url), .text(m.host), .int(Int64(m.ordinal))])
                    if try db.scalarInt("SELECT changes()") > 0 { newMirrors += 1 }
                }
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
        return (newIssues, newMirrors)
    }

    private func upsertIssue(_ parsed: ParsedIssue, folded: String,
                             source: String?, inserted: inout Int) throws -> Int64 {
        try db.run("""
            INSERT OR IGNORE INTO issue (code, number, title, title_folded, series, style, source)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [SQLValue(parsed.label.code), SQLValue(parsed.label.number),
                  SQLValue(parsed.label.title), .text(folded),
                  SQLValue(parsed.label.series), .text(parsed.style.rawValue),
                  SQLValue(source)])

        if try db.scalarInt("SELECT changes()") > 0 {
            inserted += 1
            let id = try existingID(parsed, folded: folded)
            // Keep FTS in step manually; rowid ties it back to issue.id.
            try db.run("INSERT INTO issue_fts (rowid, title_folded) VALUES (?, ?)",
                       [.int(id), .text(folded)])
            return id
        }
        return try existingID(parsed, folded: folded)
    }

    private func existingID(_ parsed: ParsedIssue, folded: String) throws -> Int64 {
        var id: Int64 = 0
        try db.query("""
            SELECT id FROM issue
            WHERE IFNULL(code,'') = ? AND IFNULL(number,-1) = ? AND title_folded = ?
            """, [.text(parsed.label.code ?? ""),
                  .int(Int64(parsed.label.number ?? -1)), .text(folded)]) { row in
            id = Int64(row.int(0) ?? 0)
        }
        return id
    }

    // MARK: - Search

    /// Prefix search over folded titles. The query is folded identically to
    /// the stored keys, so diacritics and punctuation cannot cause a miss.
    public func search(_ text: String, limit: Int = 50) throws -> [StoredIssue] {
        let tokens = Fold.fold(text).split(separator: " ").filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        // Folding leaves only letters, digits and spaces, so no FTS5
        // metacharacter can survive into the query string.
        let match = tokens.map { "\($0)*" }.joined(separator: " ")

        var out: [StoredIssue] = []
        try db.query("""
            SELECT i.id, i.code, i.number, i.title, i.series, i.style,
                   (SELECT COUNT(*) FROM mirror m WHERE m.issue_id = i.id)
            FROM issue_fts f
            JOIN issue i ON i.id = f.rowid
            WHERE issue_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """, [.text(match), .int(Int64(limit))]) { row in
            out.append(StoredIssue(
                id: row.int(0) ?? 0,
                code: row.string(1),
                number: row.int(2),
                title: row.string(3),
                series: row.string(4),
                style: LabelStyle(rawValue: row.string(5) ?? "") ?? .inlinePrevLine,
                mirrorCount: row.int(6) ?? 0))
        }
        return out
    }

    public func mirrors(forIssue id: Int) throws -> [MirrorLink] {
        var out: [MirrorLink] = []
        try db.query("""
            SELECT url, host, ordinal FROM mirror WHERE issue_id = ? ORDER BY ordinal
            """, [.int(Int64(id))]) { row in
            out.append(MirrorLink(url: row.string(0) ?? "",
                                  host: row.string(1) ?? "?",
                                  ordinal: row.int(2) ?? 0))
        }
        return out
    }

    public var issueCount: Int { (try? db.scalarInt("SELECT COUNT(*) FROM issue")) ?? 0 }
    public var mirrorCount: Int { (try? db.scalarInt("SELECT COUNT(*) FROM mirror")) ?? 0 }
}
