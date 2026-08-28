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
        try? addColumns(to: "mirror", [
            // Whether a link has been found to 404. See `markMirrorDead`.
            ("dead", "INTEGER NOT NULL DEFAULT 0"),
            // When the host was last asked about the file, so a probe that
            // never happened and one that found nothing are told apart.
            ("probed_at", "REAL"),
        ])
    }

    public func recordDownload(issueID: Int, mirrorURL: String,
                               path: URL, bytes: Int64) throws {
        try db.run("""
            INSERT OR REPLACE INTO download (issue_id, mirror_url, path, bytes, fetched_at)
            VALUES (?, ?, ?, ?, ?)
            """, [.int(Int64(issueID)), .text(mirrorURL), .text(relativePath(path)),
                  .int(bytes), .double(Date().timeIntervalSince1970)])
    }

    /// Relative to the comics root when it sits under it, so a relocated
    /// container does not orphan the file.
    func relativePath(_ url: URL) -> String {
        guard let root = libraryRoot else { return url.path }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath)
            ? String(url.path.dropFirst(rootPath.count))
            : url.path
    }

    /// Absolute paths are still honoured: rows written before the migration,
    /// and stores used without a root at all (tests).
    func resolvedURL(_ stored: String) -> URL {
        if stored.hasPrefix("/") { return URL(fileURLWithPath: stored) }
        guard let root = libraryRoot else { return URL(fileURLWithPath: stored) }
        return root.appendingPathComponent(stored)
    }

    public func downloadedFile(issueID: Int) throws -> DownloadOutcome? {
        var out: DownloadOutcome?
        try db.query("""
            SELECT path, bytes, mirror_url FROM download WHERE issue_id = ?
            """, [.int(Int64(issueID))]) { row in
            guard let p = row.string(0) else { return }
            let url = resolvedURL(p)
            out = DownloadOutcome(issueID: issueID, path: url,
                                  kind: ArchiveKind.sniff(url),
                                  bytes: Int64(row.int(1) ?? 0),
                                  mirrorURL: row.string(2) ?? "")
        }
        return out
    }

    /// What every downloaded issue weighs, keyed by issue id.
    ///
    /// One read for the whole shelf. The alternative — `downloadedFile` per
    /// row — is a statement per issue, and both callers want the figure for
    /// every visible row at once: the Scan Size order compares on it, and the
    /// list puts it on the button that frees it.
    ///
    /// The recorded archive size, the same number the info panel shows, not
    /// what the unpacked pages occupy on disk. `totalDownloadedBytes` measures
    /// the folders because it reports the library's real footprint; this one
    /// has to agree with the figure already on the screen.
    ///
    /// Rows recording no bytes are left out rather than reported as zero: a
    /// caller cannot tell "nothing" from "not measured" from a 0, and every
    /// one of them treats a missing entry as unknown already.
    public var downloadedBytesByIssue: [Int: Int64] {
        var out: [Int: Int64] = [:]
        try? db.query("SELECT issue_id, bytes FROM download WHERE bytes > 0") { row in
            guard let id = row.int(0), let bytes = row.int(1) else { return }
            out[id] = Int64(bytes)
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

    /// Bytes held by downloaded comics.
    ///
    /// Nothing evicts these — the library keeps whatever you download until you
    /// remove it. This exists so the app can show what is being used, which is
    /// what makes manual clean-up a decision rather than a guess.
    ///
    /// Measured on disk rather than summed from the recorded sizes: the archive
    /// is deleted after unpacking but the unpacked pages remain, so the
    /// recorded byte count is not what the library actually occupies.
    /// Bytes the downloads actually occupy.
    ///
    /// Each directory once, however many issues live in it. A set is one
    /// download shared by a whole run — 116 issues out of one archive — and
    /// charging every one of them for the folder they share reported 16.68 GB
    /// for 144 MB on disk.
    public var totalDownloadedBytes: Int64 {
        var counted: Set<String> = []
        var total: Int64 = 0
        try? db.query("SELECT path FROM download") { row in
            guard let p = row.string(0) else { return }
            let directory = resolvedURL(p).deletingLastPathComponent()
            guard counted.insert(directory.standardizedFileURL.path).inserted else { return }
            total += Self.sizeOnDisk(directory)
        }
        return total
    }

    static func sizeOnDisk(_ directory: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let e = FileManager.default.enumerator(at: directory,
                                                     includingPropertiesForKeys: Array(keys))
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: keys)
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }



    public var downloadedCount: Int {
        (try? db.scalarInt("SELECT COUNT(*) FROM download")) ?? 0
    }

    /// Every recorded download and where its file is supposed to be, for
    /// checking the table against the device. See `Library.reconcileDownloads`,
    /// which is the only caller and holds the rule for reading the answer.
    ///
    /// Local Files are deliberately left out. Their rows are already
    /// reconciled against the folder by `reconcileLocalFiles`, under a rule
    /// this sweep does not have and must not apply: a local file that is gone
    /// takes its whole *issue* with it, because the file was the only thing
    /// the row ever was. Two mechanisms deleting the same rows to two
    /// different rules is how they come to disagree.
    func recordedDownloads() throws -> [(issueID: Int, file: URL)] {
        var out: [(issueID: Int, file: URL)] = []
        try db.query("""
            SELECT d.issue_id, d.path FROM download d
            JOIN issue ON issue.id = d.issue_id
            WHERE \(Self.notLocal)
            """) { row in
            guard let id = row.int(0), let path = row.string(1) else { return }
            out.append((id, resolvedURL(path)))
        }
        return out
    }

    /// Forgets downloads whose files are no longer here, in bulk.
    ///
    /// `deleteDownload`'s contract, applied to many rows at once and without
    /// the file paths it returns — there is nothing on disk left to remove,
    /// which is the whole reason for calling this.
    ///
    /// Chunked because the list is unbounded. A restore leaves every download
    /// in the library stale at once, and a single `IN (...)` of several
    /// thousand placeholders runs into SQLite's variable limit — where the
    /// failure is the sweep silently doing nothing at all.
    func forgetDownloads(issueIDs: [Int]) throws {
        for chunk in stride(from: 0, to: issueIDs.count, by: 500).map({
            Array(issueIDs[$0..<min($0 + 500, issueIDs.count)])
        }) {
            let holes = chunk.map { _ in "?" }.joined(separator: ", ")
            try db.run("DELETE FROM download WHERE issue_id IN (\(holes))",
                       chunk.map { .int(Int64($0)) })
        }
    }
}
