import Foundation

/// What one pass over the reader's folder changed.
///
/// The two lists are ids rather than counts because the caller has work to do
/// with them: pages unpacked from a file that is gone are so much dead weight,
/// and pages unpacked from a file that has been replaced are the *old* issue
/// under the new one's name.
public struct LocalFilesReport: Equatable, Sendable {
    /// Files that were not on the shelf before this scan.
    public let added: Int
    /// Rows whose file is no longer in the folder. Deleted here; their
    /// unpacked pages are the caller's to discard.
    public let removed: [Int]
    /// Rows whose file changed size since it was last seen — the same name,
    /// different bytes. The row stays; anything unpacked from the old file
    /// has to go.
    public let replaced: [Int]

    public var isEmpty: Bool { added == 0 && removed.isEmpty && replaced.isEmpty }
}

public extension Store {

    /// How a row for one of the reader's own files says where it came from.
    ///
    /// Deliberately not `catalogueSource(for: .local)`: that spelling is what
    /// `isCatalogued` reads to mean "the app put this here and no import can
    /// bring it back", and a local file is the opposite of both halves of
    /// that. It is here so the row can be recognised, and so the bulk deletes
    /// can pass over it.
    static let localSource = "local file"

    /// Brings the library into line with what is actually in the folder.
    ///
    /// The folder is the truth and the rows are a view of it: a file dragged
    /// in through the Finder becomes a row, a file dragged to the Trash takes
    /// its row with it, and neither needs the app to have been running. That
    /// is the whole contract, and it is why this runs at launch and again
    /// whenever the app comes back to the front — a reader who deletes a file
    /// with the iPad connected expects the shelf to agree the next time they
    /// look at it.
    ///
    /// Matched on the file's name, which is the row's `code`. Not the path:
    /// the container's absolute path changes on reinstall, and every row
    /// would be a stranger after one. The path is refreshed from this scan
    /// for that reason.
    /// `present` is every name in the folder, which is not always every file
    /// being written here. A file still arriving is left out of `files` — it
    /// is not ready to be a row yet — but it is very much still in the
    /// folder, and computing removals from `files` alone would delete the row
    /// of an issue the reader is in the middle of replacing. Defaults to the
    /// names in `files`, which is the whole truth whenever nothing is
    /// mid-copy.
    @discardableResult
    func reconcileLocalFiles(_ files: [LocalFile],
                             present: Set<String>? = nil) throws -> LocalFilesReport {
        let onDisk = present ?? Set(files.map(\.name))
        var known: [String: (id: Int, bytes: Int64)] = [:]
        try db.query("""
            SELECT issue.id, issue.code, IFNULL(download.bytes, 0)
            FROM issue LEFT JOIN download ON download.issue_id = issue.id
            WHERE issue.site = ?
            """, [.text(IssueSite.local.rawValue)]) { row in
            guard let code = row.string(1), let id = row.int(0) else { return }
            known[code] = (id, Int64(row.int(2) ?? 0))
        }

        var added = 0
        var replaced: [Int] = []
        // One transaction for the lot. A folder holds tens of files, not the
        // thousands a catalogue seed walks, so there is nothing here worth
        // batching — and a scan that is interrupted half way should leave the
        // shelf as it found it rather than half agreeing with the folder.
        try db.transaction {
            for file in files {
                guard let existing = known[file.name] else {
                    _ = try insertLocalIssue(file)
                    added += 1
                    continue
                }
                // The name is the same and the bytes are not: the reader
                // replaced the file. The row is theirs to keep — it carries
                // what they have read — but anything unpacked from the old
                // file is now the wrong issue.
                if existing.bytes != file.bytes { replaced.append(existing.id) }
                // Rewritten every scan, which is what heals a path that a
                // reinstall moved and a size that a replacement changed.
                try recordDownload(issueID: existing.id, mirrorURL: file.name,
                                   path: file.url, bytes: file.bytes)
            }
        }

        let gone = known.filter { name, _ in !onDisk.contains(name) }
        var removed: [Int] = []
        if !gone.isEmpty {
            let ids = gone.values.map(\.id).sorted()
            let holes = ids.map { _ in "?" }.joined(separator: ", ")
            let args = ids.map { SQLValue.int(Int64($0)) }
            try db.transaction {
                try db.run("DELETE FROM issue_fts WHERE rowid IN (\(holes))", args)
                try db.run("DELETE FROM download WHERE issue_id IN (\(holes))", args)
                try db.run("DELETE FROM issue WHERE id IN (\(holes))", args)
            }
            removed = ids
        }
        return LocalFilesReport(added: added, removed: removed, replaced: replaced)
    }

    /// The row one file becomes.
    ///
    /// Written as downloaded from the moment it exists, because it is: the
    /// file is on the device and there is nothing to fetch. That is also why
    /// no mirror is written — a mirror is a link to try, and this row has
    /// nowhere to go if the file disappears. It disappears too.
    private func insertLocalIssue(_ file: LocalFile) throws -> Int {
        let described = LocalFiles.describe(file.name)
        let title = described.title ?? file.name
        let folded = Fold.fold(title)
        // The source's own name in the searchable context, as every other
        // source does it: typing "local" finds the lot. The filename goes in
        // as well, so a file whose cleaned-up title dropped a word can still
        // be found by what it is actually called on disk.
        let context = "\(IssueSite.local.display) \(file.name)"
        let search = Self.searchText(title: title, code: file.name,
                                     number: described.number,
                                     series: described.edition, context: context)
        let id = try db.run("""
            INSERT INTO issue
              (code, number, title, title_folded, series, edition, publisher,
               context, search_text, site, style, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(file.name), SQLValue(described.number), .text(title),
                  .text(folded), SQLValue(described.edition),
                  SQLValue(described.edition), .text(IssueSite.local.display),
                  .text(context), .text(search),
                  .text(IssueSite.local.rawValue),
                  .text(LabelStyle.labeledBlock.rawValue),
                  .text(Self.localSource)])
        try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(id)])
        try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                   [.int(id), .text(search)])
        try recordDownload(issueID: Int(id), mirrorURL: file.name,
                           path: file.url, bytes: file.bytes)
        return Int(id)
    }

    /// How many of the reader's own files the shelf holds, and what they
    /// weigh.
    ///
    /// Both numbers in one read, because the one place that asks needs both
    /// in the same sentence: the question put after Delete Library names the
    /// count and the size before it deletes anything.
    var localFileTotals: (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        try? db.query("""
            SELECT COUNT(*), IFNULL(SUM(download.bytes), 0)
            FROM issue LEFT JOIN download ON download.issue_id = issue.id
            WHERE issue.site = ?
            """, [.text(IssueSite.local.rawValue)]) { row in
            count = row.int(0) ?? 0
            bytes = Int64(row.int(1) ?? 0)
        }
        return (count, bytes)
    }

    /// Deletes every local row, and hands back the files they stand for.
    ///
    /// The files are the caller's to remove: they are the reader's own, they
    /// sit outside everything this app owns on disk, and deleting them is a
    /// thing that has to be asked about rather than done in passing. Nothing
    /// here decides that — it returns the list and deletes the rows.
    @discardableResult
    func deleteLocalIssues() throws -> [(id: Int, file: URL)] {
        var files: [(id: Int, file: URL)] = []
        let site = SQLValue.text(IssueSite.local.rawValue)
        let doomed = "SELECT id FROM issue WHERE site = ?"
        // The id as well as the path: the file is the reader's to remove, and
        // the pages unpacked from it are the app's. Neither caller can find
        // the second from the first.
        try db.query("SELECT issue_id, path FROM download WHERE issue_id IN (\(doomed))",
                     [site]) { row in
            if let id = row.int(0), let p = row.string(1) {
                files.append((id, resolvedURL(p)))
            }
        }
        try db.transaction {
            try db.run("DELETE FROM issue_fts WHERE rowid IN (\(doomed))", [site])
            try db.run("DELETE FROM download WHERE issue_id IN (\(doomed))", [site])
            try db.run("DELETE FROM issue WHERE site = ?", [site])
        }
        return files
    }
}
