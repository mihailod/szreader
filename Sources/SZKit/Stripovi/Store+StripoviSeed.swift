import Foundation

public extension Store {

    /// How a Stripovi row records where it came from.
    static var stripoviSource: String { catalogueSource(for: .stripovi) }

    /// Applies the shipped Stripovi index.
    ///
    /// Its own seed rather than the shared one because its catalogue is its
    /// own shape — see `StripoviCatalog`. It keeps the two rules that matter
    /// from the shared seed and drops the one that does not:
    ///
    ///  * **An update touches only what the catalogue owns.** `read_at`,
    ///    `started_at`, `last_page` and the download belong to the reader, and
    ///    a corrected title must not mark a finished comic unread.
    ///  * **The stamp is written last**, so an interrupted seed is repeated
    ///    rather than skipped.
    ///  * No batching. That exists because BombJack is eighteen thousand rows;
    ///    this is thirty-one, and one transaction is the cheaper shape.
    @discardableResult
    func seedStripovi(_ file: StripoviCatalog,
                      force: Bool = false, stamp: String? = nil) throws -> SeedReport {
        guard file.version <= StripoviCatalog.currentVersion else {
            throw SeedError.tooNew(file.version)
        }
        let mark = stamp ?? "\(file.version)/\(file.generated)"
        let key = Self.catalogueStamp(for: .stripovi)
        if !force, try meta(key) == mark { return .alreadyCurrent }

        var inserted = 0, updated = 0
        try db.transaction {
            for comic in file.comics {
                if try writeStripovi(comic, in: file) { inserted += 1 } else { updated += 1 }
            }
        }
        try setMeta(key, mark)
        return SeedReport(inserted: inserted, updated: updated, skipped: false)
    }

    /// What a comic is filed under here, if anything. Keyed on the site's own
    /// `ComicID`, which is the identity; the title is description.
    func stripoviComic(id: Int) throws -> Int64? {
        var found: Int64?
        try db.query("SELECT id FROM issue WHERE site = ? AND code = ?",
                     [.text(IssueSite.stripovi.rawValue), .text(String(id))]) { row in
            found = Int64(row.int(0) ?? 0)
        }
        return found
    }

    /// One comic. Returns true when the row is new.
    @discardableResult
    private func writeStripovi(_ comic: StripoviCatalog.Comic,
                               in file: StripoviCatalog) throws -> Bool {
        let site = IssueSite.stripovi
        let code = String(comic.id)
        let existing = try stripoviComic(id: comic.id)

        // A comic that stands alone is filed under its own name, so the Series
        // filter lists something for every row rather than a blank beside the
        // five that belong to a run.
        let run = comic.series ?? comic.title

        // The creators go into the search index but into no column of their
        // own: someone looking for what Darko Macan wrote can find it, without
        // the shelf growing a column that is empty for every other source.
        let context = [run, comic.creators ?? "", site.display, "Stripovi", code]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let search = Self.searchText(title: comic.title, code: code, number: comic.number,
                                     series: run, context: context)

        let values: [SQLValue] = [
            .text(code), SQLValue(comic.number), .text(comic.title),
            .text(Fold.fold(comic.title)), .text(run), .text(run),
            // These are the site's own web comics, so the site is the
            // publisher. Keeps the Publisher filter populated.
            .text(site.display),
            SQLValue(comic.pages), .text(context), .text(search),
        ]

        let cover = comic.cover.map { file.url($0) }
        let id: Int64
        if let existing {
            id = existing
            try db.run("""
                UPDATE issue SET code = ?, number = ?, title = ?, title_folded = ?,
                                 series = ?, edition = ?, publisher = ?,
                                 page_count = ?, context = ?, search_text = ?
                WHERE id = ?
                """, values + [.int(id)])
            // Only ever fills a gap: a row whose cover is set may be showing
            // the comic's own first page, captured on download, which is
            // better artwork than the site's listing tile.
            if let cover {
                try db.run("""
                    UPDATE issue SET cover_url = ? WHERE id = ? AND cover_url IS NULL
                    """, [.text(cover), .int(id)])
            }
        } else {
            // `style` records how a forum label was parsed and means nothing
            // here — there is no label. Stored because the column is NOT NULL.
            id = try db.run("""
                INSERT INTO issue
                  (code, number, title, title_folded, series, edition, publisher,
                   page_count, context, search_text, cover_url, site, style, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values + [SQLValue(cover), .text(site.rawValue),
                               .text(LabelStyle.labeledBlock.rawValue),
                               .text(Self.stripoviSource)])
        }

        // The comic's own page. Not a page image: the download builds those
        // from the rule, and this is the address it falls back to reading when
        // the rule stops being true.
        try db.run("""
            INSERT OR IGNORE INTO mirror (issue_id, url, host, ordinal)
            VALUES (?, ?, ?, 0)
            """, [.int(id), .text(Stripovi.comicURL(id: comic.id)), .text(Stripovi.host)])

        try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(id)])
        try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                   [.int(id), .text(search)])
        return existing == nil
    }
}
