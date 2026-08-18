import Foundation

/// What the library already holds for one archive.org item.
public struct ArchiveRow: Equatable, Sendable {
    public let issueID: Int
    /// The file the issue currently points at, as its URL. Nil for a row that
    /// somehow lost its mirror.
    public let mirrorURL: String?
    /// Whether that file is on the device.
    public let isDownloaded: Bool
    /// Whether the row came from the shipped catalogue rather than from a
    /// reader browsing to it.
    public let isCatalogued: Bool

    public init(issueID: Int, mirrorURL: String?, isDownloaded: Bool, isCatalogued: Bool) {
        self.issueID = issueID; self.mirrorURL = mirrorURL
        self.isDownloaded = isDownloaded; self.isCatalogued = isCatalogued
    }
}

/// What one import did.
public struct ArchiveImport: Equatable, Sendable {
    public let issueID: Int
    /// What the shelf will call it.
    public let title: String
    /// Whether the item was already in the library before this.
    public let existed: Bool
    /// Whether the file the issue points at changed. False for re-importing
    /// the same file, which is the case worth reporting as "nothing to do".
    public let fileChanged: Bool
}

public extension Store {

    /// What an archive.org issue is filed under here, if anything.
    ///
    /// The code is the item's identifier for an item that holds one issue —
    /// the same key the shipped catalogue uses, so a reader who browses to
    /// A-Profy finds the copy they already have rather than making a second
    /// one — and `identifier/stem` for one issue of a pack. `ArchiveOrgItem`
    /// decides which; see `code(for:)`.
    func archiveItem(identifier: String) throws -> ArchiveRow? {
        var row: ArchiveRow?
        try db.query("""
            SELECT i.id,
                   (SELECT m.url FROM mirror m WHERE m.issue_id = i.id ORDER BY m.ordinal LIMIT 1),
                   EXISTS(SELECT 1 FROM download d WHERE d.issue_id = i.id),
                   IFNULL(i.source, '')
            FROM issue i WHERE i.site = ? AND i.code = ?
            """, [.text(IssueSite.archive.rawValue), .text(identifier)]) { result in

            row = ArchiveRow(issueID: result.int(0) ?? 0,
                             mirrorURL: result.string(1),
                             isDownloaded: (result.int(2) ?? 0) == 1,
                             isCatalogued: result.string(3) == Self.catalogueSource)
        }
        return row
    }

    /// How a row written by `seedCatalogue` says so.
    ///
    /// Matched rather than reconstructed at the call site so the two cannot
    /// drift: `Store+Catalogue` writes exactly this string.
    static var catalogueSource: String { "\(IssueSite.archive.rawValue) catalogue" }

    /// Adds an archive.org item to the library, pointing at one of its files.
    ///
    /// Metadata only. Nothing is downloaded here and nothing should be: the
    /// reader is standing in a browser looking for the next item, and an issue
    /// arrives on the shelf the way every other issue does — greyed out, with
    /// its cover, waiting to be asked for.
    ///
    /// Idempotent on the identifier. Importing the same item twice updates the
    /// row rather than making a second one, which is what lets the browser
    /// offer to swap the file an issue points at.
    @discardableResult
    func importArchiveItem(_ item: ArchiveOrgItem,
                           file: ArchiveOrgItem.ReadableFile) throws -> ArchiveImport {
        let site = IssueSite.archive
        // Which issue of the item this file belongs to. An item holding one
        // issue is that issue; a pack holds many, and the file says which.
        let issue = item.issue(holding: file)
        let code = issue.map { item.code(for: $0) } ?? item.identifier
        let existing = try archiveItem(identifier: code)
        // A pack's members all share the item's title — thirteen issues of
        // Transactor are all called "Transactor For The Amiga" — so the
        // filename is the only thing that tells them apart, and it is what
        // names them. `TitleCleaner` is not asked: it reads forum mirror
        // names, and on these it turns "…Vol_01_01_1988_Apr" into "01 1988
        // Apr", issue 1.
        let label: (title: String, number: Int?) =
            item.readableIssues.count > 1 && issue != nil
                ? (issue!.name, nil)
                : Self.archiveLabel(for: item.title)
        let url = file.url(item: item.identifier)

        // Everything the item says about itself, so a search finds it by the
        // archive.org title it was uploaded under, by its identifier, by the
        // file it came from, and by its uploader's tags — none of which
        // survive into the shelf's own columns once the title has been
        // cleaned up.
        let context = ([item.title, item.identifier, site.display,
                        issue.map(\.stem) ?? ""] + item.subjects)
            .joined(separator: " ")
        let search = Self.searchText(title: label.title, code: code,
                                     number: label.number, series: nil, context: context)

        var id = Int64(existing?.issueID ?? 0)
        try db.transaction {
            // A row the shipped catalogue owns keeps every column it wrote.
            // Its title is "Septembar 1988", assembled from the item's date
            // and the run's language, and the item's own "Amiga Bilten 1" is
            // not an improvement on it. Only the file it points at is the
            // reader's to change.
            if existing?.isCatalogued != true {
                id = try writeImportedRow(code: code, label: label, context: context,
                                          search: search, existing: existing,
                                          cover: issue.flatMap { item.coverPath(for: $0) })
            }
            // One file per issue, so a swap replaces the link rather than
            // adding a second one. Two mirrors under an issue mean something
            // specific to `Library.fetch` — alternates to fall back through,
            // or the halves of a split archive — and neither is true of two
            // formats of the same scan.
            try db.run("DELETE FROM mirror WHERE issue_id = ? AND url <> ?",
                       [.int(id), .text(url)])
            let host = URL(string: url)?.host ?? ArchiveOrg.host
            // Decoded, because this is the name the file is given on disk. The
            // scans are named as their uploader typed them, and a file called
            // "Amiga%20Bilten%201.pdf" is the escaping leaking out of the URL
            // into the library.
            try db.run("""
                INSERT OR IGNORE INTO mirror (issue_id, url, host, ordinal, filename, size)
                VALUES (?, ?, ?, 0, ?, ?)
                """, [.int(id), .text(url), .text(host),
                      .text(file.name), SQLValue(file.bytes.map(Int.init))])
            // Re-importing refreshes what the archive now says, and clears any
            // death mark: the reader has just been shown this file listed on
            // the item, so whatever failed before is worth trying again.
            try db.run("UPDATE mirror SET filename = ?, size = ?, dead = 0 WHERE url = ?",
                       [.text(file.name), SQLValue(file.bytes.map(Int.init)), .text(url)])
        }

        return ArchiveImport(issueID: Int(id), title: label.title,
                             existed: existing != nil,
                             fileChanged: existing?.mirrorURL != url)
    }

    /// The issue row itself.
    ///
    /// Deliberately narrow about what it writes on an update: `read_at`,
    /// `started_at`, `last_page` and the download belong to the reader, and
    /// re-importing an item to change which file it points at must not mark a
    /// half-read magazine unread.
    private func writeImportedRow(code: String,
                                  label: (title: String, number: Int?),
                                  context: String, search: String,
                                  existing: ArchiveRow?,
                                  cover: String?) throws -> Int64 {
        let site = IssueSite.archive
        let folded = Fold.fold(label.title)
        // Publisher, and nothing else. An imported item has no series and no
        // hero worth the guess — archive.org identifiers are whatever their
        // uploader typed — so "Archive.org" in the one column that is honest
        // is what makes the whole lot findable, filterable and separable from
        // the forum's issues.
        let values: [SQLValue] = [
            .text(code), SQLValue(label.number), .text(label.title),
            .text(folded), .text(site.display),
            .text(context), .text(search),
        ]

        let id: Int64
        if let existing {
            id = Int64(existing.issueID)
            try db.run("""
                UPDATE issue SET code = ?, number = ?, title = ?, title_folded = ?,
                                 publisher = ?, context = ?, search_text = ?
                WHERE id = ?
                """, values + [.int(id)])
            // The cover it already has is kept. It may be the issue's own
            // first page, captured when the comic was downloaded, which is
            // better artwork than anything a URL can offer.
            if let cover {
                try db.run("""
                    UPDATE issue SET cover_url = ? WHERE id = ? AND cover_url IS NULL
                    """, [.text(ArchiveOrg.base + cover), .int(id)])
            }
        } else {
            // `style` records how a forum label was parsed and means nothing
            // here — there is no label. Stored because the column is NOT NULL,
            // and the same value the catalogue seed writes for the same
            // reason.
            id = try db.run("""
                INSERT INTO issue
                  (code, number, title, title_folded, publisher, context, search_text,
                   cover_url, site, style, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values + [SQLValue(cover.map { ArchiveOrg.base + $0 }),
                               .text(site.rawValue),
                               .text(LabelStyle.labeledBlock.rawValue),
                               .text("archive.org import")])
        }

        // FTS is maintained by hand and keyed on rowid; deleting first is what
        // stops a re-import failing on the rowid constraint.
        try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(id)])
        try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                   [.int(id), .text(search)])
        return id
    }

    /// What to call an item on the shelf, and which issue it is.
    ///
    /// archive.org titles are auto-generated from the uploaded filename, so
    /// they read "Zagor 137 Dharma La Strega ( Daim Press 1976 12)" — the hero,
    /// the number, the story and the printer's details, in one line, with the
    /// spacing mangled. `TitleCleaner` was written to pull exactly that apart,
    /// against forum mirror filenames of the same shape, so it is asked here
    /// too rather than a second parser being written beside it.
    ///
    /// Best effort, and it says so by falling back rather than guessing: an
    /// item whose title it cannot read keeps that title untouched. The raw
    /// title goes into the search index either way, so nothing that was
    /// findable before cleaning stops being findable after it.
    static func archiveLabel(for rawTitle: String) -> (title: String, number: Int?) {
        let parsed = TitleCleaner.parse(rawTitle)
        let cleaned = parsed.title?.trimmingCharacters(in: .whitespaces)
        // The edition it also offers is discarded on purpose. On the four
        // items this was measured against it produced "ZAGOR", "OP" and
        // "BILTEN" — one right, one meaningless and one a fragment — and an
        // edition is not a free-standing guess: it becomes a row in the series
        // filter and the code on every shelf tile.
        return (cleaned?.isEmpty == false ? cleaned! : rawTitle, parsed.number)
    }
}
