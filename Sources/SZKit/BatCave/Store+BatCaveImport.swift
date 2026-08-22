import Foundation

/// What the library already holds for one BatCave chapter.
public struct BatCaveRow: Equatable, Sendable {
    public let issueID: Int
    public let isDownloaded: Bool

    public init(issueID: Int, isDownloaded: Bool) {
        self.issueID = issueID; self.isDownloaded = isDownloaded
    }
}

/// What one page's import did.
public struct BatCaveReport: Equatable, Sendable {
    /// The series the page was listing, for the sentence shown afterwards.
    public let series: String
    public let inserted: Int
    public let updated: Int
    /// Chapters the site itself marks as broken, which are not written.
    ///
    /// Counted rather than silently dropped: a reader who can see 194 issues
    /// on screen and finds 190 on the shelf is owed the difference, and this
    /// is the only place that knows it.
    public let broken: Int

    public var issues: Int { inserted + updated }
    public var isEmpty: Bool { issues == 0 }
}

public extension Store {

    /// How a BatCave row records where it came from.
    static var batCaveSource: String { "batcave import" }

    /// What a chapter is filed under here, if anything.
    ///
    /// Keyed on the site's own chapter id. Not on the issue number, which is
    /// not unique within a series — The Walking Dead carries both "#1" and
    /// "#1 10th Anniversary" — and not on the title, which repeats the series
    /// name and would collide the moment two runs share one.
    func batCaveChapter(id: Int) throws -> BatCaveRow? {
        var row: BatCaveRow?
        try db.query("""
            SELECT i.id, EXISTS(SELECT 1 FROM download d WHERE d.issue_id = i.id)
            FROM issue i WHERE i.site = ? AND i.code = ?
            """, [.text(IssueSite.batcave.rawValue), .text(String(id))]) { result in
            row = BatCaveRow(issueID: result.int(0) ?? 0,
                             isDownloaded: (result.int(1) ?? 0) == 1)
        }
        return row
    }

    /// Reads one series page into the library.
    ///
    /// Metadata only, like every other import: nothing is fetched and the
    /// reader is left on the page they were looking at, with the run now on
    /// the shelf waiting to be asked for.
    ///
    /// The whole page at once, which is the unit that makes sense — a series
    /// page *is* one run — and idempotent, so revisiting a series that has
    /// gained a chapter adds the one and leaves the rest alone.
    @discardableResult
    func importBatCave(page html: String) throws -> BatCaveReport {
        guard let series = BatCavePage.series(html) else {
            throw ImportError.notASeriesPage
        }
        var inserted = 0, updated = 0, broken = 0
        try db.transaction {
            for chapter in series.chapters {
                // The site's own flag, honoured. A broken chapter has no
                // scans behind it, so a row for one is a shelf entry whose
                // only possible outcome is a failed download.
                guard !chapter.isBroken else { broken += 1; continue }
                if try writeBatCave(chapter, in: series) { inserted += 1 } else { updated += 1 }
            }
        }
        return BatCaveReport(series: series.title, inserted: inserted,
                             updated: updated, broken: broken)
    }

    /// One chapter. Returns true when the row is new.
    ///
    /// Narrow about what an update touches, for the same reason the Comic Book
    /// Plus and archive.org imports are: `read_at`, `started_at`, `last_page`
    /// and the download belong to the reader, and revisiting a series to pick
    /// up one new chapter must not mark a half-read issue unread.
    @discardableResult
    private func writeBatCave(_ chapter: BatCaveChapter,
                              in series: BatCaveSeries) throws -> Bool {
        let site = IssueSite.batcave
        let code = String(chapter.id)
        let existing = try batCaveChapter(id: chapter.id)

        // The site's ids go into the search index but into no column of their
        // own, so a reader who knows a chapter's number can find it without
        // the shelf growing a column that is empty for every other source.
        let context = [series.title, series.publisher ?? "",
                       site.display, String(series.id), code]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let search = Self.searchText(title: chapter.title, code: code,
                                     number: chapter.number,
                                     series: series.title, context: context)

        // `edition` as well as `series`, because `editions()` fills the Series
        // filter menu and reads that column alone.
        //
        // `page_count` is stated by the site for every chapter, which no other
        // source manages before a download — and here it is load-bearing
        // rather than decorative: it is what a page-by-page fetch counts
        // against, so the progress bar is a measurement rather than a guess.
        let values: [SQLValue] = [
            .text(code), SQLValue(chapter.number), .text(chapter.title),
            .text(Fold.fold(chapter.title)), .text(series.title), .text(series.title),
            // Falling back to the site's own name keeps the column populated
            // so the Publisher filter never shows a blank row.
            .text(series.publisher ?? site.display),
            SQLValue(chapter.pages), .text(context), .text(search),
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
            // Only ever fills a gap. A row whose cover is already set may be
            // showing the issue's own first page, captured on download, which
            // is better artwork than a series poster shared by 194 rows.
            if let cover = series.coverURL {
                try db.run("""
                    UPDATE issue SET cover_url = ? WHERE id = ? AND cover_url IS NULL
                    """, [.text(cover), .int(id)])
            }
        } else {
            // `style` records how a forum label was parsed and means nothing
            // here — there is no label. Stored because the column is NOT NULL,
            // and it is the value every non-forum import writes.
            //
            // The cover is the series poster, which is the same picture for
            // every chapter of a run. Not ideal and not avoidable: the site
            // states no per-chapter thumbnail. A download replaces it with the
            // issue's own first page.
            id = try db.run("""
                INSERT INTO issue
                  (code, number, title, title_folded, series, edition, publisher,
                   page_count, context, search_text, cover_url, site, style, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values + [SQLValue(series.coverURL),
                               .text(site.rawValue),
                               .text(LabelStyle.labeledBlock.rawValue),
                               .text(Self.batCaveSource)])
        }

        // The reader's address, which is the only route to the scans: the site
        // serves no archive file, so there is nothing else to record. Stable,
        // and carries no token.
        let url = BatCave.readerURL(series: series.id, chapter: chapter.id)
        try db.run("""
            INSERT OR IGNORE INTO mirror (issue_id, url, host, ordinal)
            VALUES (?, ?, ?, 0)
            """, [.int(id), .text(url), .text(BatCave.host)])

        try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(id)])
        try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                   [.int(id), .text(search)])
        return existing == nil
    }
}
