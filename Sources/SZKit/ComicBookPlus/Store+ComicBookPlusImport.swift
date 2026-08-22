import Foundation

/// What the library already holds for one Comic Book Plus scan.
public struct ComicBookPlusRow: Equatable, Sendable {
    public let issueID: Int
    public let isDownloaded: Bool

    public init(issueID: Int, isDownloaded: Bool) {
        self.issueID = issueID; self.isDownloaded = isDownloaded
    }
}

/// What one page's import did.
public struct ComicBookPlusReport: Equatable, Sendable {
    /// The series the page was listing, for the sentence shown afterwards.
    public let series: String
    public let inserted: Int
    public let updated: Int

    public var issues: Int { inserted + updated }
    public var isEmpty: Bool { issues == 0 }
}

public extension Store {

    /// How a Comic Book Plus row records where it came from.
    static var comicBookPlusSource: String { "comicbookplus import" }

    /// What a scan is filed under here, if anything.
    ///
    /// Keyed on the site's own `dlid` rather than on anything about the book.
    /// A series routinely holds two scans of one issue — a first upload and a
    /// better one years later — which share a title, an issue number and a
    /// cover date and differ only in page count and who made them. Any key
    /// built out of those would collapse the pair into one row and hand the
    /// reader whichever arrived last.
    func comicBookPlusBook(dlid: Int) throws -> ComicBookPlusRow? {
        var row: ComicBookPlusRow?
        try db.query("""
            SELECT i.id, EXISTS(SELECT 1 FROM download d WHERE d.issue_id = i.id)
            FROM issue i WHERE i.site = ? AND i.code = ?
            """, [.text(IssueSite.comicbookplus.rawValue), .text(String(dlid))]) { result in
            row = ComicBookPlusRow(issueID: result.int(0) ?? 0,
                                   isDownloaded: (result.int(1) ?? 0) == 1)
        }
        return row
    }

    /// Reads one series page into the library.
    ///
    /// Metadata only, like every other import: nothing is downloaded and the
    /// reader is left standing on the page they were looking at, with a shelf
    /// that now has the run on it waiting to be asked for.
    ///
    /// The whole page at once, which is the unit that makes sense here — a
    /// leaf page *is* one series, the way a forum topic is one run — and
    /// idempotent, so revisiting a series that has gained a scan adds the one
    /// and leaves the rest alone.
    @discardableResult
    func importComicBookPlus(page html: String) throws -> ComicBookPlusReport {
        guard let leaf = ComicBookPlusPage.leaf(html) else {
            throw ImportError.notALeafPage
        }
        var inserted = 0, updated = 0
        try db.transaction {
            for book in leaf.books {
                if try writeComicBookPlus(book, in: leaf) { inserted += 1 } else { updated += 1 }
            }
        }
        return ComicBookPlusReport(series: leaf.series,
                                   inserted: inserted, updated: updated)
    }

    /// One scan. Returns true when the row is new.
    ///
    /// Deliberately narrow about what an update touches, for the same reason
    /// `Store+ArchiveImport` is: `read_at`, `started_at`, `last_page` and the
    /// download belong to the reader, and revisiting a series page to pick up
    /// one new scan must not mark a half-read issue unread.
    @discardableResult
    private func writeComicBookPlus(_ book: ComicBookPlusBook,
                                    in leaf: ComicBookPlusLeaf) throws -> Bool {
        let site = IssueSite.comicbookplus
        let code = String(book.dlid)
        let existing = try comicBookPlusBook(dlid: book.dlid)

        // The scanner's name and the site's own id go into the search index
        // but into no column of their own: a reader looking for the copy
        // "titansfan" uploaded can find it, without the shelf growing a column
        // that is empty for every other source.
        //
        // Both spellings of the site, because `Fold` strips punctuation: the
        // marketing name folds to "comicbook", so a reader who types "comic
        // book plus" — which is what the site is called everywhere except its
        // own logo — would otherwise match nothing.
        let context = [leaf.series, leaf.publisher ?? "",
                       site.display, site.settingsName, "Comic Book Plus",
                       book.contributor ?? "", code]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let search = Self.searchText(title: book.title, code: code, number: book.number,
                                     series: leaf.series, context: context)

        // `edition` as well as `series`, because `editions()` is what fills the
        // Series filter menu and it reads that column alone. Written from the
        // page's own heading rather than guessed off the titles, which here
        // would produce "Adventures in 3-D 1" for a series called
        // "Adventures in 3-D".
        let values: [SQLValue] = [
            .text(code), SQLValue(book.number), .text(book.title),
            .text(Fold.fold(book.title)), .text(leaf.series), .text(leaf.series),
            // The print publisher, which is what the site files a series
            // under. Falling back to the site's own name keeps the column
            // populated so the Publisher filter never shows a blank row.
            .text(leaf.publisher ?? site.display),
            SQLValue(book.pages), .text(context), .text(search),
        ]

        let id: Int64
        if let existing {
            id = Int64(existing.issueID)
            try db.run("""
                UPDATE issue SET code = ?, number = ?, title = ?, title_folded = ?,
                                 series = ?, edition = ?, publisher = ?,
                                 page_count = ?, context = ?, search_text = ?
                WHERE id = ?
                """, values + [.int(id)])
            // Backfills a cover, and only ever fills a gap. Rows imported
            // before this app knew the right address have none, and
            // re-importing the series is the natural way to fix them — but a
            // row whose cover is already set may be showing the comic's own
            // first page, captured on download, which is better artwork than
            // a 200px thumbnail and must not be replaced by one.
            try db.run("""
                UPDATE issue SET cover_url = ? WHERE id = ? AND cover_url IS NULL
                """, [.text(ComicBookPlus.thumbnailURL(hash: book.hash)), .int(id)])
        } else {
            // `style` records how a forum label was parsed and means nothing
            // here — there is no label. Stored because the column is NOT NULL,
            // and the same value the catalogue seed and the archive.org import
            // both write for the same reason.
            //
            // The cover is built from the file hash rather than taken from the
            // row's own `thumbnailUrl`, which the site still states in a form
            // it stopped serving — see `ComicBookPlus.thumbnailURL`.
            id = try db.run("""
                INSERT INTO issue
                  (code, number, title, title_folded, series, edition, publisher,
                   page_count, context, search_text, cover_url, site, style, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values + [.text(ComicBookPlus.thumbnailURL(hash: book.hash)),
                               .text(site.rawValue),
                               .text(LabelStyle.labeledBlock.rawValue),
                               .text(Self.comicBookPlusSource)])
        }

        // The book's own page, and never a download address.
        //
        // The address a file actually comes from carries a session token in
        // its query string, and that token is replaced whenever the site's
        // session rolls over. Recording one would put a credential in the
        // library file and would be stale within days. This form is stable,
        // and it is the page a resolver has to read anyway to learn the
        // filename and the format — see `ComicBookPlus.downloadURL`.
        let url = ComicBookPlus.bookURL(dlid: book.dlid)
        try db.run("""
            INSERT OR IGNORE INTO mirror (issue_id, url, host, ordinal)
            VALUES (?, ?, ?, 0)
            """, [.int(id), .text(url), .text(ComicBookPlus.host)])

        try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(id)])
        try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                   [.int(id), .text(search)])
        return existing == nil
    }
}

/// Why an import could not read the page it was handed.
public enum ImportError: Error, CustomStringConvertible {
    case notALeafPage
    case notASeriesPage

    public var description: String {
        switch self {
        case .notALeafPage:
            // Said in terms of what the reader can see, because the fix is
            // theirs: they are on a search result, a category, or a single
            // book, and the page that works is the one listing a series.
            return "This page does not list a series. Open a title, then Import."
        case .notASeriesPage:
            // Same shape, different site, and said in terms of what the reader
            // can see: they are on the front page, a category or a search
            // result, and the page that works is a title's own.
            return "This page lists no issues. Open a title, then Import."
        }
    }
}
