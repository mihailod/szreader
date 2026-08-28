import Foundation

extension Store {

    /// Removes one issue and everything hanging off it.
    ///
    /// Returns any downloaded file that is now orphaned, for the caller to
    /// delete. Rows cascade via foreign keys, but two things do not:
    /// `issue_fts` is a virtual table with no FK support, and files on disk
    /// know nothing about the database. Miss either and you get a library that
    /// still finds deleted comics, or gigabytes that never come back.
    @discardableResult
    public func delete(issueID: Int) throws -> URL? {
        // Before the row goes, while there is still something to derive its
        // name in the account from. Deleting is a fact the reader's other
        // devices have to hear: absence cannot carry it, because absence is
        // also what an issue they have and this one never did looks like.
        try recordDeletions(issueIDs: [issueID])
        return try deleteWithoutRecording(issueID: issueID)
    }

    /// The same delete, for a deletion that arrived from another device.
    ///
    /// Recording one here would send the account back a fact it has just told
    /// us — harmless in itself, and the start of two devices talking about the
    /// same deletion for ever.
    @discardableResult
    func deleteWithoutRecording(issueID: Int) throws -> URL? {
        let file = try downloadedFile(issueID: issueID)?.path
        try db.transaction {
            try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(Int64(issueID))])
            try db.run("DELETE FROM issue WHERE id = ?", [.int(Int64(issueID))])
        }
        return file
    }

    /// Removes the downloaded archive but keeps the issue in the library.
    ///
    /// Distinct from `delete`: the metadata and mirrors survive, so the comic
    /// stays searchable and can be downloaded again without re-importing the
    /// topic page — which matters, because re-importing costs a Like.
    @discardableResult
    public func deleteDownload(issueID: Int) throws -> URL? {
        let file = try downloadedFile(issueID: issueID)?.path
        try db.run("DELETE FROM download WHERE issue_id = ?", [.int(Int64(issueID))])
        return file
    }

    /// Drops every downloaded archive but keeps the whole catalogue.
    ///
    /// The bulk counterpart to `deleteDownload`: reclaims the disk without
    /// costing a single re-import, which matters because re-importing is
    /// gated by the daily Like quota.
    /// A local file is not a download and is passed over by both, here and in
    /// every bulk delete below.
    ///
    /// "Remove All Downloads" means the space taken by things that can be
    /// fetched again — every one of which the app fetched in the first place.
    /// The reader's own files can be fetched again by nobody: removing one
    /// means going and finding it on a computer, which is not what a reader
    /// reclaiming space has agreed to. `deleteLocalIssues` is the one path
    /// that touches them, and it is asked for by name.
    static var notLocal: String { "issue.site <> '\(IssueSite.local.rawValue)'" }

    /// The ids a doomed-rows query names, read before anything is deleted.
    ///
    /// The bulk deletes all work by handing one `SELECT id` to several
    /// statements, and by the time the last of them has run there is nothing
    /// left to ask. `recordDeletions` needs the rows while they exist.
    func ids(matching sql: String, _ args: [SQLValue]) throws -> [Int] {
        var out: [Int] = []
        try db.query(sql, args) { row in if let id = row.int(0) { out.append(id) } }
        return out
    }

    @discardableResult
    public func deleteAllDownloads() throws -> [URL] {
        let kept = "SELECT id FROM issue WHERE \(Self.notLocal)"
        var files: [URL] = []
        try db.query("SELECT path FROM download WHERE issue_id IN (\(kept))") { row in
            if let p = row.string(0) { files.append(resolvedURL(p)) }
        }
        try db.run("DELETE FROM download WHERE issue_id IN (\(kept))")
        return files
    }

    /// How many issues the seed put on the shelf.
    ///
    /// The complement of what a bulk delete may take: everything else on the
    /// shelf arrived by an Import that can be run again.
    public var shippedCount: Int {
        let stamps = IssueSite.allCases.map { Self.catalogueSource(for: $0) }
        let holes = stamps.map { _ in "?" }.joined(separator: ", ")
        return (try? db.scalarInt("SELECT COUNT(*) FROM issue WHERE source IN (\(holes))",
                                  stamps.map { SQLValue.text($0) })) ?? 0
    }

    /// Empties the library of everything an Import could bring back, leaving
    /// the rows the seed wrote from a catalogue shipped in the app.
    ///
    /// Skipped rather than refused: those rows cannot be got back — the stamp
    /// the seed leaves on the library makes a second pass skip the whole file
    /// — so "delete everything" can only honestly mean everything that an
    /// Import returns. Their downloads stay with them; Remove All is what
    /// reclaims that space.
    @discardableResult
    public func deleteImported() throws -> [URL] {
        let stamps = IssueSite.allCases.map { Self.catalogueSource(for: $0) }
        let holes = stamps.map { _ in "?" }.joined(separator: ", ")
        let args = stamps.map { SQLValue.text($0) }
        // Every statement below reads this against the issue table, so the
        // issues themselves must go last — after it, it names nothing.
        //
        // Local files are excluded here as well as from the downloads above.
        // Delete Library empties the library of everything an Import could
        // bring back, and an Import brings back none of them — the way to get
        // one back is to plug the iPad in and copy it over again. The app
        // asks about them separately, after this has run.
        let doomed = "SELECT id FROM issue WHERE IFNULL(source, '') NOT IN (\(holes)) "
                   + "AND \(Self.notLocal)"

        var files: [URL] = []
        try db.query("SELECT path FROM download WHERE issue_id IN (\(doomed))", args) { row in
            if let p = row.string(0) { files.append(resolvedURL(p)) }
        }
        try recordDeletions(issueIDs: try ids(matching: doomed, args))
        try db.transaction {
            try db.run("DELETE FROM issue_fts WHERE rowid IN (\(doomed))", args)
            try db.run("DELETE FROM download WHERE issue_id IN (\(doomed))", args)
            // Cascade would take these with the issues, but only while the
            // issues are still there to cascade from.
            try db.run("DELETE FROM mirror WHERE issue_id IN (\(doomed))", args)
            try db.run("DELETE FROM issue WHERE id IN (\(doomed))", args)
        }
        return files
    }

    /// Empties the library, shipped rows and all.
    ///
    /// Not what the app's Delete Library does — that is `deleteImported`, which
    /// leaves what no Import could bring back. This is the unconditional
    /// primitive underneath it.
    @discardableResult
    public func deleteAll() throws -> [URL] {
        var files: [URL] = []
        try db.query("SELECT path FROM download") { row in
            if let p = row.string(0) { files.append(resolvedURL(p)) }
        }
        try recordDeletions(issueIDs: try ids(matching: "SELECT id FROM issue", []))
        try db.transaction {
            try db.execute("DELETE FROM issue_fts")
            try db.execute("DELETE FROM issue")
            // Belt and braces: cascade should have taken these, but a stray
            // row here would resurrect mirrors for issues that no longer exist.
            try db.execute("DELETE FROM mirror")
            try db.execute("DELETE FROM download")
        }
        return files
    }
}
