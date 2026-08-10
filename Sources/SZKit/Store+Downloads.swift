import Foundation

extension Store {

    func migrateDownloads() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS download (
              issue_id   INTEGER PRIMARY KEY REFERENCES issue(id) ON DELETE CASCADE,
              mirror_url TEXT NOT NULL,
              path       TEXT NOT NULL,
              bytes      INTEGER NOT NULL,
              fetched_at REAL NOT NULL
            );
            """)
        // SQLite has no ADD COLUMN IF NOT EXISTS; on a second open this
        // throws "duplicate column name", which is the success case.
        try? db.execute("ALTER TABLE mirror ADD COLUMN dead INTEGER NOT NULL DEFAULT 0")
    }

    public func recordDownload(issueID: Int, mirrorURL: String,
                               path: URL, bytes: Int64) throws {
        try db.run("""
            INSERT OR REPLACE INTO download (issue_id, mirror_url, path, bytes, fetched_at)
            VALUES (?, ?, ?, ?, ?)
            """, [.int(Int64(issueID)), .text(mirrorURL), .text(path.path),
                  .int(bytes), .int(Int64(Date().timeIntervalSince1970))])
    }

    public func downloadedFile(issueID: Int) throws -> DownloadOutcome? {
        var out: DownloadOutcome?
        try db.query("""
            SELECT path, bytes, mirror_url FROM download WHERE issue_id = ?
            """, [.int(Int64(issueID))]) { row in
            guard let p = row.string(0) else { return }
            let url = URL(fileURLWithPath: p)
            out = DownloadOutcome(issueID: issueID, path: url,
                                  kind: ArchiveKind.sniff(url),
                                  bytes: Int64(row.int(1) ?? 0),
                                  mirrorURL: row.string(2) ?? "")
        }
        return out
    }

    /// A mirror that 404s is recorded rather than retried on every read — the
    /// `drugi sken` alternate is there precisely because links rot.
    public func markMirrorDead(url: String) throws {
        try db.run("UPDATE mirror SET dead = 1 WHERE url = ?", [.text(url)])
    }

    /// Live mirrors for an issue, primary first. Dead ones sort last rather
    /// than vanishing: if every mirror is dead, trying again beats refusing.
    public func liveMirrors(forIssue id: Int) throws -> [MirrorLink] {
        var out: [MirrorLink] = []
        try db.query("""
            SELECT url, host, ordinal FROM mirror
            WHERE issue_id = ? ORDER BY dead ASC, ordinal ASC
            """, [.int(Int64(id))]) { row in
            out.append(MirrorLink(url: row.string(0) ?? "",
                                  host: row.string(1) ?? "?",
                                  ordinal: row.int(2) ?? 0))
        }
        return out
    }

    public var downloadedCount: Int {
        (try? db.scalarInt("SELECT COUNT(*) FROM download")) ?? 0
    }
}
