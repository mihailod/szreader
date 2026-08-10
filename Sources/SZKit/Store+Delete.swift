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
    @discardableResult
    public func deleteAllDownloads() throws -> [URL] {
        var files: [URL] = []
        try db.query("SELECT path FROM download") { row in
            if let p = row.string(0) { files.append(resolvedURL(p)) }
        }
        try db.execute("DELETE FROM download")
        return files
    }

    /// Empties the library. Returns every downloaded file to remove.
    @discardableResult
    public func deleteAll() throws -> [URL] {
        var files: [URL] = []
        try db.query("SELECT path FROM download") { row in
            if let p = row.string(0) { files.append(resolvedURL(p)) }
        }
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
