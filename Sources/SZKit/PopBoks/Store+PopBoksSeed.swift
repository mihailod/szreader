import Foundation

public extension Store {

    /// How a PopBoks row records where it came from.
    static func popboksSource(for magazine: PopBoks.Magazine) -> String {
        catalogueSource(for: magazine.site)
    }

    /// Applies one shipped PopBoks catalogue.
    ///
    /// Its own seed rather than the shared one because the catalogue is its
    /// own shape — see `PopBoksCatalog`. It keeps the rules that matter from
    /// the shared seed and drops the one that does not:
    ///
    ///  * **An update touches only what the catalogue owns.** `read_at`,
    ///    `started_at`, `last_page` and the download belong to the reader, and
    ///    a corrected title must not mark a finished issue unread.
    ///  * **The stamp is written last**, so an interrupted seed is repeated
    ///    rather than skipped.
    ///  * No batching. That exists because BombJack is eighteen thousand rows;
    ///    the larger of these two is 183, and one transaction is the cheaper
    ///    shape.
    ///
    /// **The mirror is the issue's folder on the archive.**
    ///
    /// Every source but Local Files says where its issues came from, and this
    /// one is no exception — the reader's own files are the only thing on the
    /// shelf with nothing behind them to name.
    ///
    /// It took a moment to find the right address. This archive publishes no
    /// file to point at: an issue is thousands of tiles, and the site's reader
    /// keeps which issue is open in a variable rather than in a URL, so there
    /// is no page to link either. The folder every one of those tiles sits
    /// under is the true answer, it is unique per issue — which `mirror.url`
    /// requires — and it is on the right host, so the cooldown machinery reads
    /// it correctly.
    ///
    /// Nothing ever fetches it. The generic download path is what follows a
    /// mirror, and this source takes its own route before reaching it.
    @discardableResult
    func seedPopBoks(_ file: PopBoksCatalog,
                     force: Bool = false, stamp: String? = nil) throws -> SeedReport {
        guard file.version <= PopBoksCatalog.currentVersion else {
            throw SeedError.tooNew(file.version)
        }
        guard let magazine = file.kind else {
            throw SeedError.catalogueMissing(.popboksDzuboks)
        }
        let mark = stamp ?? "\(file.version)/\(file.generated)"
        let key = Self.catalogueStamp(for: magazine.site)
        if !force, try meta(key) == mark { return .alreadyCurrent }

        var inserted = 0, updated = 0
        try db.transaction {
            for issue in file.issues {
                if try writePopBoks(issue, in: file, magazine: magazine) {
                    inserted += 1
                } else {
                    updated += 1
                }
            }
        }
        try setMeta(key, mark)
        return SeedReport(inserted: inserted, updated: updated, skipped: false)
    }

    /// What an issue is filed under, if anything. Keyed on the archive's own
    /// folder number, which is the identity; the title is description.
    func popboksIssue(id: Int, magazine: PopBoks.Magazine) throws -> Int64? {
        var found: Int64?
        try db.query("SELECT id FROM issue WHERE site = ? AND code = ?",
                     [.text(magazine.site.rawValue), .text(String(id))]) { row in
            found = Int64(row.int(0) ?? 0)
        }
        return found
    }

    /// One issue. Returns true when the row is new.
    @discardableResult
    private func writePopBoks(_ issue: PopBoksCatalog.Issue,
                              in file: PopBoksCatalog,
                              magazine: PopBoks.Magazine) throws -> Bool {
        let site = magazine.site
        let code = String(issue.id)
        let existing = try popboksIssue(id: issue.id, magazine: magazine)

        // The magazine is the run. Both are single titles, so every row has
        // one and the Series filter lists something for all of them.
        let run = magazine.display

        // The year goes into the searchable context but into no column of its
        // own — there is none, and the shared seed carries RetroSpec's dates
        // the same way. It is here so that typing "1979" finds that year's
        // issues, and the issue's own designation so that "6/7" finds the
        // double it names.
        let context = [run, "PopBoks", site.display, issue.label,
                       String(issue.year), code]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let search = Self.searchText(title: issue.title, code: code,
                                     number: issue.number, series: run,
                                     context: context)

        let values: [SQLValue] = [
            .text(code), SQLValue(issue.number), .text(issue.title),
            .text(Fold.fold(issue.title)), .text(run), .text(run),
            // The archive is the publisher, spelled so a publisher filter says
            // which archive as well as which magazine.
            .text(site.display),
            SQLValue(issue.pages), .text(context), .text(search),
        ]

        let cover = file.coverURL(issue)
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
            // the issue's own first page, captured on download, which is far
            // better artwork than the archive's 150-pixel listing thumbnail.
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
                               .text(Self.popboksSource(for: magazine))])
        }

        // Where the issue lives, so the info panel names the archive rather
        // than showing a heading over nothing.
        if let folder = file.folderURL(issue) {
            try db.run("""
                INSERT OR IGNORE INTO mirror (issue_id, url, host, ordinal)
                VALUES (?, ?, ?, 0)
                """, [.int(id), .text(folder), .text(PopBoks.host)])
        }

        try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(id)])
        try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                   [.int(id), .text(search)])
        return existing == nil
    }
}
