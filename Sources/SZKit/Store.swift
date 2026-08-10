import Foundation

/// A library row as it comes back from search.
public struct StoredIssue: Equatable, Sendable {
    public let id: Int
    public let code: String?
    public let number: Int?
    public let title: String?
    public let series: String?
    /// Character the topic sits under: "Mister No", "Alan Ford".
    public let hero: String?
    /// Edition the topic collects, spelled out: "Lunov Magnus Strip".
    public let edition: String?
    public let style: LabelStyle
    public let mirrorCount: Int
    public let coverURL: String?
    /// Whether the archive is on disk. Drives the greyed-out cover and which
    /// actions are offered.
    public let isDownloaded: Bool

    /// Short form of the edition for the shelf: initials when it is several
    /// words ("Lunov Magnus Strip" -> "LMS"), the word itself when it is one
    /// ("Vjesnik", "FIBRA").
    public var editionCode: String? {
        guard let edition, !edition.isEmpty else { return nil }
        return PageContext.code(forEdition: edition)
    }

    /// "LMS 511" — the edition and number as a reader refers to an issue.
    public var shelfMark: String? {
        switch (editionCode, number) {
        case let (code?, num?): return "\(code) \(num)"
        case let (code?, nil):  return code
        case let (nil, num?):   return "\(num)"
        default:                return nil
        }
    }

    /// The hero as it should read on screen — the stored value keeps the
    /// forum's own spelling so search still matches it.
    public var heroDisplay: String? {
        hero.map(PageContext.displayName(forHero:))
    }

    /// "SSB 1 · Alan Ford · Grupa TNT" — how the reader names what is open.
    ///
    /// Wider than the shelf's label because the reader is the one place with
    /// no surrounding context: the covers, the numbers and the series are all
    /// off screen, so the title bar has to say what this is on its own.
    /// Missing pieces are dropped rather than left as empty separators.
    public var readerTitle: String {
        // shelfMark rather than the bare code, so the issue number travels
        // with the series — "SSB 1" is what identifies a comic; "SSB" alone
        // names a whole run of several hundred.
        let parts = [shelfMark, heroDisplay, title ?? code]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "Comic" : parts.joined(separator: " · ")
    }

    /// "Mister No, Lunov Magnus Strip" — who it is about and what it is from.
    public var provenance: String? {
        let parts = [heroDisplay, edition].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The local library: issues, their mirrors, and a folded full-text index.
public final class Store {

    /// Where downloads live. Stored paths are relative to this, so they
    /// survive the container being relocated.
    public var libraryRoot: URL?


    let db: Database   // internal: Store+Backfill reaches in

    public init(path: String = ":memory:") throws {
        db = try Database(path: path)
        try migrate()
        try migrateDownloads()
    }

    private func migrate() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS issue (
              id           INTEGER PRIMARY KEY,
              code         TEXT,
              number       INTEGER,
              title        TEXT,
              title_folded TEXT NOT NULL,
              series       TEXT,
              style        TEXT NOT NULL,
              source       TEXT,
              verified     INTEGER NOT NULL DEFAULT 0
            );

            -- Natural key. An issue may legitimately appear on several pages,
            -- and re-importing the same page must not duplicate it.
            CREATE UNIQUE INDEX IF NOT EXISTS issue_identity
              ON issue (IFNULL(code,''), IFNULL(number,-1), title_folded);

            CREATE TABLE IF NOT EXISTS mirror (
              id       INTEGER PRIMARY KEY,
              issue_id INTEGER NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
              url      TEXT NOT NULL UNIQUE,
              host     TEXT NOT NULL,
              ordinal  INTEGER NOT NULL,
              filename TEXT,
              size     INTEGER
            );
            CREATE INDEX IF NOT EXISTS mirror_issue ON mirror (issue_id);

            -- Standalone FTS5 with rowid = issue.id. Folding both the stored
            -- key and the query is what makes "celjusti" find "čeljusti" --
            -- nobody types diacritics into a search field on an iPad.
            CREATE VIRTUAL TABLE IF NOT EXISTS issue_fts USING fts5(search_text);
            """)

        // Added after the first release of the schema; ALTER has no
        // IF NOT EXISTS, so a duplicate-column error is the success case.
        try? db.execute("ALTER TABLE issue ADD COLUMN context TEXT")
        try? db.execute("ALTER TABLE issue ADD COLUMN search_text TEXT")
        try? db.execute("ALTER TABLE issue ADD COLUMN cover_url TEXT")
        try? db.execute("ALTER TABLE issue ADD COLUMN hero TEXT")
        try? db.execute("ALTER TABLE issue ADD COLUMN edition TEXT")

        // Heal libraries damaged by the identity bug: naming an issue used to
        // rewrite `title_folded`, which is part of the natural key, so the next
        // import of the same page matched nothing and inserted every issue
        // again.
        //
        // The spurious row is identifiable: `mirror.url` is UNIQUE, so the
        // duplicate's mirror inserts were ignored and it has none, while the
        // original kept them. Restricted to rows whose twin *does* have
        // mirrors, so a genuinely link-less entry is never touched.
        let spurious = """
            SELECT i.id FROM issue i
            WHERE NOT EXISTS (SELECT 1 FROM mirror m WHERE m.issue_id = i.id)
              AND EXISTS (SELECT 1 FROM issue j
                          WHERE j.id <> i.id
                            AND IFNULL(j.code,'')   = IFNULL(i.code,'')
                            AND IFNULL(j.number,-1) = IFNULL(i.number,-1)
                            AND EXISTS (SELECT 1 FROM mirror m2 WHERE m2.issue_id = j.id))
            """
        try? db.execute("DELETE FROM issue_fts WHERE rowid IN (\(spurious))")
        try? db.execute("DELETE FROM issue WHERE id IN (\(spurious))")

        // Scanners shout inconsistently, so a library built from filenames ends
        // up with a mix of "DIJAMANTSKA KLOPKA" and "Sablast doline".
        normaliseStoredTitles()

        // Paths used to be stored absolute. iOS gives the app container a new
        // UUID on reinstall, so every one of them went stale: the rows survived
        // and the files existed, but nothing could find them — the library
        // reported "2 downloaded (0 MB)" and would have re-fetched both.
        // Rewrite them relative to the comics root, which never moves.
        try? db.execute("""
            UPDATE download
            SET path = substr(path, instr(path, '/SZReader/comics/')
                                     + length('/SZReader/comics/'))
            WHERE path LIKE '%/SZReader/comics/%'
            """)
        // Covers stored before the https fix would each pay a 301 redirect.
        try? db.execute("""
            UPDATE issue SET cover_url = replace(cover_url, 'http://', 'https://')
            WHERE cover_url LIKE 'http://%'
            """)

        // The FTS table used to index title_folded alone. If an older index is
        // present, rebuild it over the wider search_text instead of leaving
        // half the library unsearchable.
        let indexedColumn = try? db.scalarInt(
            "SELECT COUNT(*) FROM pragma_table_info('issue_fts') WHERE name = 'search_text'")
        if indexedColumn == 0 {
            try db.execute("DROP TABLE IF EXISTS issue_fts")
            try db.execute("CREATE VIRTUAL TABLE issue_fts USING fts5(search_text)")
        }
        if try db.scalarInt("SELECT COUNT(*) FROM issue WHERE search_text IS NULL") > 0 {
            try rebuildSearchIndex()
        }
    }

    /// Recomputes every row's search text and repopulates FTS.
    ///
    /// Cheap enough to run on migration: the library is thousands of rows, not
    /// millions, and getting it wrong means silently unfindable comics.
    func rebuildSearchIndex() throws {
        var rows: [(Int64, String?, String?, Int?, String?, String?)] = []
        try db.query("SELECT id, title, code, number, series, context FROM issue") { row in
            rows.append((Int64(row.int(0) ?? 0), row.string(1), row.string(2),
                         row.int(3), row.string(4), row.string(5)))
        }
        try db.transaction {
            try db.execute("DELETE FROM issue_fts")
            for (id, title, code, number, series, context) in rows {
                let text = Self.searchText(title: title, code: code, number: number,
                                           series: series, context: context)
                try db.run("UPDATE issue SET search_text = ? WHERE id = ?", [.text(text), .int(id)])
                try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                           [.int(id), .text(text)])
            }
        }
    }

    /// Everything one issue can be found by, folded into one indexed string.
    ///
    /// The code is split on underscores so `MN_LMS_511` yields the tokens
    /// "mn", "lms" and "511" — otherwise typing "lms" matches nothing. The
    /// number is added separately because codes carry zero-padded forms
    /// ("0151") that a prefix search for "151" would never hit.
    static func searchText(title: String?, code: String?, number: Int?,
                           series: String?, context: String?) -> String {
        var parts: [String] = []
        if let title { parts.append(title) }
        if let code { parts.append(code.replacingOccurrences(of: "_", with: " ")) }
        if let number { parts.append(String(number)) }
        if let series { parts.append(series) }
        if let context { parts.append(context) }
        return Fold.fold(parts.joined(separator: " "))
    }

    // MARK: - Ingest

    @discardableResult
    public func ingest(html: String, source: String? = nil) throws -> (issues: Int, mirrors: Int) {
        var newIssues = 0, newMirrors = 0
        // Publisher, hero and edition live in the page chrome, not the posts,
        // so they are read once per page and stamped onto each issue.
        let pageContext = Catalog.pageContext(in: html)
        let context = pageContext.searchableText
        let covers = Catalog.covers(in: html)
        try db.transaction {
            for parsed in Catalog.issues(in: html) {
                let folded = Fold.fold(parsed.label.title ?? parsed.label.code ?? "")
                let id = try upsertIssue(parsed, folded: folded, source: source,
                                         context: context, hero: pageContext.hero,
                                         edition: pageContext.edition,
                                         inserted: &newIssues)
                // Covers arrive per page; fill one in if this issue lacks one.
                // Fills these in for rows created before the columns existed,
                // so a re-import upgrades an old library rather than only
                // helping new arrivals.
                try db.run("""
                    UPDATE issue SET hero = COALESCE(hero, ?), edition = COALESCE(edition, ?)
                    WHERE id = ?
                    """, [SQLValue(pageContext.hero), SQLValue(pageContext.edition), .int(id)])
                if let number = parsed.label.number, let cover = covers[number] {
                    try db.run("UPDATE issue SET cover_url = ? WHERE id = ? AND cover_url IS NULL",
                               [.text(cover), .int(id)])
                }
                for m in parsed.mirrors {
                    // URL is UNIQUE: re-importing a page is a no-op for mirrors.
                    try db.run("""
                        INSERT OR IGNORE INTO mirror (issue_id, url, host, ordinal)
                        VALUES (?, ?, ?, ?)
                        """, [.int(id), .text(m.url), .text(m.host), .int(Int64(m.ordinal))])
                    if try db.scalarInt("SELECT changes()") > 0 { newMirrors += 1 }
                }
            }
        }
        return (newIssues, newMirrors)
    }

    private func upsertIssue(_ parsed: ParsedIssue, folded: String, source: String?,
                             context: String, hero: String?, edition: String?,
                             inserted: inout Int) throws -> Int64 {
        let searchText = Self.searchText(title: parsed.label.title, code: parsed.label.code,
                                         number: parsed.label.number,
                                         series: parsed.label.series, context: context)
        try db.run("""
            INSERT OR IGNORE INTO issue
              (code, number, title, title_folded, series, style, source, context,
               search_text, hero, edition)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [SQLValue(parsed.label.code), SQLValue(parsed.label.number),
                  SQLValue(parsed.label.title), .text(folded),
                  SQLValue(parsed.label.series), .text(parsed.style.rawValue),
                  SQLValue(source), .text(context), .text(searchText),
                  SQLValue(hero), SQLValue(edition)])

        if try db.scalarInt("SELECT changes()") > 0 {
            inserted += 1
            let id = try existingID(parsed, folded: folded)
            // Keep FTS in step manually; rowid ties it back to issue.id.
            // Delete first: the index is maintained by hand, and a leftover row
            // for this id makes the insert fail on its rowid constraint — which
            // aborts the whole import rather than just that issue.
            try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(id)])
            try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                       [.int(id), .text(searchText)])
            return id
        }
        return try existingID(parsed, folded: folded)
    }

    private func existingID(_ parsed: ParsedIssue, folded: String) throws -> Int64 {
        var id: Int64 = 0
        try db.query("""
            SELECT id FROM issue
            WHERE IFNULL(code,'') = ? AND IFNULL(number,-1) = ? AND title_folded = ?
            """, [.text(parsed.label.code ?? ""),
                  .int(Int64(parsed.label.number ?? -1)), .text(folded)]) { row in
            id = Int64(row.int(0) ?? 0)
        }
        return id
    }

    // MARK: - Search

    /// Prefix search over folded titles. The query is folded identically to
    /// the stored keys, so diacritics and punctuation cannot cause a miss.
    public func search(_ text: String, limit: Int? = 50,
                       downloadedOnly: Bool = false) throws -> [StoredIssue] {
        let tokens = Fold.fold(text).split(separator: " ").filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        // Folding leaves only letters, digits and spaces, so no FTS5
        // metacharacter can survive into the query string.
        let match = tokens.map { "\($0)*" }.joined(separator: " ")

        var out: [StoredIssue] = []
        try db.query("""
            SELECT i.id, i.code, i.number, i.title, i.series, i.style,
                   (SELECT COUNT(*) FROM mirror m WHERE m.issue_id = i.id), i.cover_url,
                   EXISTS(SELECT 1 FROM download d WHERE d.issue_id = i.id),
                   i.hero, i.edition
            FROM issue_fts f
            JOIN issue i ON i.id = f.rowid
            WHERE issue_fts MATCH ?
            \(downloadedOnly
              ? "AND EXISTS(SELECT 1 FROM download f WHERE f.issue_id = i.id)" : "")
            ORDER BY rank
            \(limit == nil ? "" : "LIMIT ?")
            """, [.text(match)] + (limit.map { [SQLValue.int(Int64($0))] } ?? [])) { row in
            out.append(StoredIssue(
                id: row.int(0) ?? 0,
                code: row.string(1),
                number: row.int(2),
                title: row.string(3),
                series: row.string(4),
                hero: row.string(9), edition: row.string(10),
                style: LabelStyle(rawValue: row.string(5) ?? "") ?? .inlinePrevLine,
                mirrorCount: row.int(6) ?? 0,
                coverURL: row.string(7),
                isDownloaded: (row.int(8) ?? 0) == 1))
        }
        return out
    }

    /// The library in insertion order, for the shelf when no query is active.
    /// An empty search field should show the library, not an empty screen.
    /// `limit: nil` returns everything. The shelf uses that: a cap there is
    /// invisible — the library simply appears to stop, with no indication that
    /// more exists.
    public func recent(limit: Int? = 100, downloadedOnly: Bool = false) throws -> [StoredIssue] {
        var out: [StoredIssue] = []
        // Applied in SQL rather than to the results: the query is capped, so
        // filtering afterwards would drop downloads that sit past the cap.
        let filter = downloadedOnly
            ? "WHERE EXISTS(SELECT 1 FROM download f WHERE f.issue_id = i.id)" : ""
        try db.query("""
            SELECT i.id, i.code, i.number, i.title, i.series, i.style,
                   (SELECT COUNT(*) FROM mirror m WHERE m.issue_id = i.id), i.cover_url,
                   EXISTS(SELECT 1 FROM download d WHERE d.issue_id = i.id),
                   i.hero, i.edition
            FROM issue i \(filter) ORDER BY i.id \(limit == nil ? "" : "LIMIT ?")
            """, limit.map { [SQLValue.int(Int64($0))] } ?? []) { row in
            out.append(StoredIssue(
                id: row.int(0) ?? 0, code: row.string(1), number: row.int(2),
                title: row.string(3), series: row.string(4),
                hero: row.string(9), edition: row.string(10),
                style: LabelStyle(rawValue: row.string(5) ?? "") ?? .inlinePrevLine,
                mirrorCount: row.int(6) ?? 0,
                coverURL: row.string(7),
                isDownloaded: (row.int(8) ?? 0) == 1))
        }
        return out
    }

    public func mirrors(forIssue id: Int) throws -> [MirrorLink] {
        var out: [MirrorLink] = []
        try db.query("""
            SELECT url, host, ordinal FROM mirror WHERE issue_id = ? ORDER BY ordinal
            """, [.int(Int64(id))]) { row in
            out.append(MirrorLink(url: row.string(0) ?? "",
                                  host: row.string(1) ?? "?",
                                  ordinal: row.int(2) ?? 0))
        }
        return out
    }

    public var issueCount: Int { (try? db.scalarInt("SELECT COUNT(*) FROM issue")) ?? 0 }
    public var mirrorCount: Int { (try? db.scalarInt("SELECT COUNT(*) FROM mirror")) ?? 0 }
}
