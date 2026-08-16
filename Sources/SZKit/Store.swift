import Foundation

/// A library row as it comes back from search.
/// Where an issue stands with the reader.
public enum ReadState: String, Sendable, CaseIterable {
    case unread, reading, read
}

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
    /// Who published it: "BONELLI", "FIBRA", "Magnus - Bunker".
    public let publisher: String?
    /// Whether the reader has marked it read.
    public let isRead: Bool
    /// Furthest page reached, zero-based. Nil until the reader moves off the
    /// cover.
    public let lastPage: Int?
    /// The far end of a double issue, when one magazine covers two numbers.
    public let numberTo: Int?
    /// Whether reading ever got past the cover. Sticky: only finishing the
    /// comic and then unmarking it clears this.
    public let started: Bool
    /// Whether the last download attempt failed. Some links really are dead,
    /// and a shelf that looks identical before and after trying is a shelf you
    /// try again from tomorrow.
    public let downloadFailed: Bool

    /// Where this issue stands. Deliberately exclusive: an issue is exactly
    /// one of these, so the three filters partition the library rather than
    /// overlapping.
    public var readState: ReadState {
        if isRead { return .read }
        // Not derived from `lastPage`: that is where the reader stopped, and
        // it moves backwards as freely as forwards now. Scrubbing back to the
        // cover would have read as never having started.
        return started ? .reading : .unread
    }
    public let style: LabelStyle
    public let mirrorCount: Int
    public let coverURL: String?
    /// Whether the archive is on disk. Drives the greyed-out cover and which
    /// actions are offered.
    public let isDownloaded: Bool
    /// Which archive this came from. Drives nothing about how an issue reads
    /// — only whether the reader has asked to see that source at all.
    public let site: IssueSite
    /// Scanned pages, where the source states them. Nil for anything from the
    /// forum, which never does — so this says "unknown", not "empty".
    public let pageCount: Int?

    /// Spelled out rather than left to the compiler's memberwise one, so
    /// `site` can carry a default. Every issue in existence was StripZona's
    /// before this column, and the tests that build a row to check sorting or
    /// a label have no opinion about where it came from — making them all say
    /// so would be noise around the thing each is actually testing.
    ///
    /// The two places that read real rows out of the database pass it
    /// explicitly; nothing else should need to.
    public init(id: Int, code: String?, number: Int?, title: String?, series: String?,
                hero: String?, edition: String?, publisher: String?,
                isRead: Bool, lastPage: Int?, numberTo: Int?, started: Bool,
                downloadFailed: Bool, style: LabelStyle, mirrorCount: Int,
                coverURL: String?, isDownloaded: Bool,
                site: IssueSite = .default, pageCount: Int? = nil) {
        self.id = id; self.code = code; self.number = number; self.title = title
        self.series = series; self.hero = hero; self.edition = edition
        self.publisher = publisher; self.isRead = isRead; self.lastPage = lastPage
        self.numberTo = numberTo; self.started = started
        self.downloadFailed = downloadFailed; self.style = style
        self.mirrorCount = mirrorCount; self.coverURL = coverURL
        self.isDownloaded = isDownloaded; self.site = site
        self.pageCount = pageCount
    }

    /// Short form of the edition for the shelf: initials when it is several
    /// words ("Lunov Magnus Strip" -> "LMS"), the word itself when it is one
    /// ("Vjesnik", "FIBRA").
    public var editionCode: String? {
        guard let edition, !edition.isEmpty else { return nil }
        return PageContext.code(forEdition: edition)
    }

    /// "LMS 511" — the edition and number as a reader refers to an issue.
    public var shelfMark: String? {
        // A double issue reads as the pair it was printed as: "Sirius 121-122".
        let mark = number.map { n in numberTo.map { "\(n)-\($0)" } ?? "\(n)" }
        switch (editionCode, mark) {
        case let (code?, num?): return "\(code) \(num)"
        case let (code?, nil):  return code
        case let (nil, num?):   return num
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
        // with the series — "SSB 1" is what identifies an issue; "SSB" alone
        // names a whole run of several hundred.
        let parts = [shelfMark, heroDisplay, title ?? code]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        // "Issue", never "Comic": the library holds magazines too.
        return parts.isEmpty ? "Issue" : parts.joined(separator: " · ")
    }

    /// "Mister No, Lunov Magnus Strip" — who it is about and what it is from.
    public var provenance: String? {
        // Publisher included: for a magazine there is no hero, so without it a
        // row read "Kolorka" alone and lost the FIBRA it belongs to.
        let parts = [heroDisplay, edition, publisher]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The local library: issues, their mirrors, and a folded full-text index.
/// Thread-safe by construction: every statement goes through `Database`, which
/// serialises on a recursive lock, and the one other piece of mutable state
/// (`libraryRoot`) is guarded below. That is what makes `@unchecked Sendable`
/// a statement of fact here rather than a promise — a `Store` is handed to the
/// background title backfill while the UI keeps reading from it.
public final class Store: @unchecked Sendable {

    /// Where downloads live. Stored paths are relative to this, so they
    /// survive the container being relocated.
    ///
    /// Guarded because it is written once by `Library.init` and then read from
    /// whichever thread happens to resolve a path — "written once, early" is a
    /// convention, not something the compiler or anything else enforces.
    public var libraryRoot: URL? {
        get { rootLock.lock(); defer { rootLock.unlock() }; return storedRoot }
        set { rootLock.lock(); storedRoot = newValue; rootLock.unlock() }
    }

    private var storedRoot: URL?
    private let rootLock = NSLock()


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
            --
            -- The series belongs in it. One topic can carry two runs — the
            -- Kosmoplov/Galaksija page carries both, and Galaksija continues
            -- its own numbering from 1 — so without it Galaksija 1 and
            -- Kosmoplov 1 are the same row. Neither has a title or a code,
            -- and the second to arrive was silently dropped with its links
            -- handed to the first: twenty-four issues gone, and no sign of it
            -- anywhere except a run that appeared to start at 25.
            -- The index itself is created further down, once the `site`
            -- column it now includes is guaranteed to exist.
            DROP INDEX IF EXISTS issue_identity;

            -- Covers read off a page that did not list the issue they name.
            -- Keyed by what identifies the issue to a reader, since the row
            -- itself may not exist yet.
            CREATE TABLE IF NOT EXISTS cover_offer (
              edition TEXT NOT NULL,
              number  INTEGER NOT NULL,
              url     TEXT NOT NULL,
              PRIMARY KEY (edition, number)
            );

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

            -- A single download covering a run of issues.
            --
            -- Some topics outlive their individual links: Sirius's are all
            -- dead, and the only surviving copies are three archives holding
            -- one PDF per issue. A mirror cannot express that — its URL is
            -- unique to one issue — so the set is recorded once and matched
            -- to issues by number.
            CREATE TABLE IF NOT EXISTS segment (
              id      INTEGER PRIMARY KEY,
              context TEXT NOT NULL,
              url     TEXT NOT NULL,
              label   TEXT NOT NULL,
              first   INTEGER NOT NULL,
              last    INTEGER NOT NULL,
              UNIQUE(context, url)
            );

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
        try? db.execute("ALTER TABLE issue ADD COLUMN publisher TEXT")
        try? db.execute("ALTER TABLE issue ADD COLUMN read_at REAL")
        try? db.execute("ALTER TABLE issue ADD COLUMN last_page INTEGER")
        try? db.execute("ALTER TABLE issue ADD COLUMN download_failed_at REAL")
        try? db.execute("ALTER TABLE issue ADD COLUMN started_at REAL")
        // When the catalogue was last asked for a cover this page did not
        // link. Without it a miss is asked again on every pass.
        try? db.execute("ALTER TABLE issue ADD COLUMN cover_asked_at REAL")
        // The far end of a double issue: one magazine printed as "121/122".
        try? db.execute("ALTER TABLE issue ADD COLUMN number_to INTEGER")
        // Which archive a row came from. NOT NULL with a default, so every
        // issue that existed before the column is a StripZona issue — which
        // is what they all are — without a second statement to backfill them.
        try? db.execute("""
            ALTER TABLE issue ADD COLUMN site TEXT NOT NULL DEFAULT 'stripzona'
            """)
        // How many scanned pages the archive holds, where the source says so.
        // Nil for everything imported from the forum, which never states it.
        try? db.execute("ALTER TABLE issue ADD COLUMN page_count INTEGER")

        // Small facts about the library itself rather than about any issue —
        // currently just which build of the shipped catalogue has been
        // applied, so re-seeding an unchanged one costs a single read.
        try db.execute("""
            CREATE TABLE IF NOT EXISTS meta (
              key   TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """)

        // The natural key, now that `site` exists to go in it.
        //
        // Two archives are two namespaces: RetroSpec's Galaksija is a
        // Belgrade science monthly and StripZona's is an SF magazine, and
        // nothing but the source tells their issue 1 apart. Without the
        // column in the key they are one row, and the second to arrive is
        // dropped with its links handed to the first — the same silent loss
        // the v2 comment above describes, across catalogues instead of within
        // one.
        //
        // Safe to create over existing data whatever it holds: adding a
        // column to a unique index only ever admits more rows than the
        // narrower index did, so anything v2 accepted v3 accepts too.
        try db.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS issue_identity_v3
              ON issue (site, IFNULL(code,''), IFNULL(number,-1), title_folded,
                        IFNULL(series,''));
            DROP INDEX IF EXISTS issue_identity_v2;
            """)

        // Libraries that already took the forum's "picture missing" graphic
        // as artwork. Clearing it puts those issues back to having no cover,
        // which is the truth and lets the first page stand in once the comic
        // is downloaded.
        try? db.execute("""
            UPDATE issue SET cover_url = NULL
            WHERE cover_url LIKE '%picturemissing%'
            """)

        // Libraries written before there was a column for it: anything with a
        // place recorded past the cover was being read, and would otherwise
        // drop out of Reading the moment this build opened it.
        try? db.execute("""
            UPDATE issue SET started_at = strftime('%s', 'now')
            WHERE started_at IS NULL AND IFNULL(last_page, 0) >= 1
            """)

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
        // A few topics are only reliable in one member's posts; for the rest
        // this hands back the page untouched.
        let html = Catalog.authoritativeHTML(html)
        let pageContext = Catalog.pageContext(in: html)
        let context = pageContext.searchableText
        let covers = Catalog.covers(in: html)
        // The filename tiers alone travel off this page; see spendLeftoverCovers.
        let exact = Catalog.exactCovers(in: html)
        let named = Catalog.namedCovers(in: html)
        var coveredHere: Set<Int> = []
        var editionsHere: Set<String> = []
        try recordSegments(Catalog.segments(in: html), context: context)
        try db.transaction {
            for raw in Catalog.issues(in: html) {
                // A label that is only a number carries nothing to tell it
                // from the same number on another topic, so the topic's own
                // name goes into the key. Applied here rather than in the
                // parser because it is identity, not reading: only the store
                // cares that two pages must not collide.
                let parsed = ParsedIssue(label: raw.label.qualified(by: pageContext.edition),
                                         style: raw.style, mirrors: raw.mirrors)
                let folded = Fold.fold(parsed.label.title ?? parsed.label.code ?? "")
                let id = try upsertIssue(parsed, folded: folded, source: source,
                                         context: context, hero: pageContext.hero,
                                         edition: Self.edition(of: parsed.label.series,
                                                               under: pageContext.edition),
                                         publisher: pageContext.publisher,
                                         inserted: &newIssues)
                // Covers arrive per page; fill one in if this issue lacks one.
                // Fills these in for rows created before the columns existed,
                // so a re-import upgrades an old library rather than only
                // helping new arrivals.
                try db.run("""
                    UPDATE issue SET hero = COALESCE(hero, ?),
                                     edition = COALESCE(edition, ?),
                                     publisher = COALESCE(publisher, ?)
                    WHERE id = ?
                    """, [SQLValue(pageContext.hero),
                          SQLValue(Self.edition(of: parsed.label.series,
                                                under: pageContext.edition)),
                          SQLValue(pageContext.publisher), .int(id)])
                if let number = parsed.label.number, let cover = covers[number] {
                    try db.run("UPDATE issue SET cover_url = ? WHERE id = ? AND cover_url IS NULL",
                               [.text(cover), .int(id)])
                } else if parsed.label.number == nil,
                          let cover = Self.namedCover(for: parsed.label.title, among: named) {
                    // A special with no number of its own — "YU SIRIUS" — whose
                    // cover is filed under that name rather than a number.
                    try db.run("UPDATE issue SET cover_url = ? WHERE id = ? AND cover_url IS NULL",
                               [.text(cover), .int(id)])
                }
                coveredHere.insert(parsed.label.number ?? -1)
                editionsHere.insert(Self.edition(of: parsed.label.series,
                                                 under: pageContext.edition) ?? "")
                for m in parsed.mirrors {
                    // URL is UNIQUE: re-importing a page is a no-op for mirrors.
                    try db.run("""
                        INSERT OR IGNORE INTO mirror (issue_id, url, host, ordinal)
                        VALUES (?, ?, ?, ?)
                        """, [.int(id), .text(m.url), .text(m.host), .int(Int64(m.ordinal))])
                    if try db.scalarInt("SELECT changes()") > 0 { newMirrors += 1 }
                }
            }
            try spendLeftoverCovers(exact, coveredHere: coveredHere, editions: editionsHere)
            // Unconditional: this page may have supplied the issues that an
            // earlier page's covers were waiting for. The mixed topics are
            // precisely the ones that record no offers and need them most.
            try claimCoverOffers()
        }
        return (newIssues, newMirrors)
    }

    /// Covers for issues that are not on the page carrying them.
    ///
    /// A run is often spread over several topics — Galaksija's issues come
    /// from three "obrade" pages, while the page with the artwork lists a
    /// different hundred of them. The art names its issue outright, so a
    /// cover with no issue beside it is still an answer for the issue it
    /// names; without this, 68 of Galaksija's covers were read off the page
    /// and then dropped for want of a row to put them on.
    ///
    /// Deliberately narrow, because a number on its own means nothing across
    /// a library — every series has an issue 5:
    ///
    ///  * only the filename tiers, never the positional guess. Position is
    ///    inferred from where art sits in *this* page's post and says nothing
    ///    about any other page;
    ///  * only from a page whose issues are all one edition. "Kosmoplov i
    ///    Galaksija" is one topic holding two runs, each numbered from one,
    ///    and a leftover cover there names an issue in one of them with no
    ///    way to say which;
    ///  * only where the issue has no cover, so nothing already established
    ///    is overwritten.
    ///
    /// Kept rather than spent on the spot, because which page is imported
    /// first is arbitrary. Alphabetically the artwork page comes before the
    /// three topics listing the issues, and a cover applied before its issue
    /// exists is a cover thrown away: Galaksija landed 106 that way against
    /// 175 in the other order. An offer sits in the table until an issue it
    /// names turns up.
    func spendLeftoverCovers(_ covers: [Int: String], coveredHere: Set<Int>,
                             editions: Set<String>) throws {
        guard editions.count == 1, let edition = editions.first, !edition.isEmpty else { return }
        for (number, url) in covers where !coveredHere.contains(number) {
            try db.run("""
                INSERT OR IGNORE INTO cover_offer (edition, number, url) VALUES (?, ?, ?)
                """, [.text(edition), .int(Int64(number)), .text(url)])
        }
    }

    /// Hands every kept cover to the issue it names, if that issue has none.
    func claimCoverOffers() throws {
        try db.run("""
            UPDATE issue SET cover_url = (
                SELECT o.url FROM cover_offer o
                WHERE o.edition = issue.edition AND o.number = issue.number)
            WHERE cover_url IS NULL AND edition IS NOT NULL AND number IS NOT NULL
              AND EXISTS (SELECT 1 FROM cover_offer o
                          WHERE o.edition = issue.edition AND o.number = issue.number)
            """)
    }

    /// Which name an issue is filed under.
    ///
    /// Usually the topic's: "LUNOV MAGNUS STRIP" is what a Mister No issue
    /// belongs to. But a topic can gather several runs — "Kosmoplov i
    /// Galaksija" carries both, each numbering from one — and then the
    /// topic's name says where the issue was found rather than what it is,
    /// and reduces to "KIG", which names neither.
    ///
    /// The giveaway is that the topic names the series inside itself. Where
    /// it does, the series is the finer answer and becomes the edition, so
    /// the shelf and the filters separate them.
    static func edition(of series: String?, under topic: String?) -> String? {
        guard let series, !series.isEmpty, let topic, !topic.isEmpty,
              Fold.fold(topic) != Fold.fold(series) else { return topic }
        let words = Set(Fold.fold(topic).split(whereSeparator: { !$0.isLetter }).map(String.init))
        let mine = Fold.fold(series).split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !mine.isEmpty, mine.allSatisfy(words.contains) else { return topic }
        return series
    }

    /// The cover whose name appears in an issue's title.
    ///
    /// "Sirius_YU.jpg" against "YU SIRIUS". Whole words only, so a two-letter
    /// key cannot latch onto the middle of an unrelated title.
    static func namedCover(for title: String?, among named: [String: String]) -> String? {
        guard let title, !named.isEmpty else { return nil }
        let words = Set(Fold.fold(title).split(whereSeparator: { !$0.isLetter }).map(String.init))
        for (key, url) in named where words.contains(key) { return url }
        return nil
    }

    private func upsertIssue(_ parsed: ParsedIssue, folded: String, source: String?,
                             context: String, hero: String?, edition: String?,
                             publisher: String?, inserted: inout Int) throws -> Int64 {
        let searchText = Self.searchText(title: parsed.label.title, code: parsed.label.code,
                                         number: parsed.label.number,
                                         series: parsed.label.series, context: context)
        // `site` is written explicitly rather than left to the column's
        // default. The default is there to backfill rows that predate the
        // column; a row being inserted now should say what it is, so that
        // reading this statement answers the question.
        try db.run("""
            INSERT OR IGNORE INTO issue
              (code, number, number_to, title, title_folded, series, style, source,
               context, search_text, hero, edition, publisher, site)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [SQLValue(parsed.label.code), SQLValue(parsed.label.number),
                  SQLValue(parsed.label.numberTo),
                  SQLValue(parsed.label.title), .text(folded),
                  SQLValue(parsed.label.series), .text(parsed.style.rawValue),
                  SQLValue(source), .text(context), .text(searchText),
                  SQLValue(hero), SQLValue(edition), SQLValue(publisher),
                  .text(IssueSite.stripzona.rawValue)])

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

    /// The row the natural key names.
    ///
    /// Must match `issue_identity_v3` term for term, `site` included. A
    /// lookup narrower than the index it stands for matches a row from the
    /// other catalogue too, and hands this page's mirrors to whichever the
    /// scan happened to return last.
    ///
    /// No test distinguishes the clause, and it is worth saying why rather
    /// than leaving someone to discover it: dropping `site` from the WHERE
    /// still produces the right answer today, because the scan follows the
    /// index's own (site, ...) order and "retrospec" sorts before
    /// "stripzona", so the forum's row is always the last one written to the
    /// result. That is the alphabet being helpful, not the query being
    /// correct. A third source named after "stripzona", or a query plan that
    /// returns rows in another order, silently reverses it — so the clause
    /// stays.
    private func existingID(_ parsed: ParsedIssue, folded: String) throws -> Int64 {
        var id: Int64 = 0
        try db.query("""
            SELECT id FROM issue
            WHERE site = ? AND IFNULL(code,'') = ? AND IFNULL(number,-1) = ?
              AND title_folded = ? AND IFNULL(series,'') = ?
            """, [.text(IssueSite.stripzona.rawValue), .text(parsed.label.code ?? ""),
                  .int(Int64(parsed.label.number ?? -1)), .text(folded),
                  .text(parsed.label.series ?? "")]) { row in
            id = Int64(row.int(0) ?? 0)
        }
        return id
    }

    // MARK: - Search

    /// Prefix search over folded titles. The query is folded identically to
    /// the stored keys, so diacritics and punctuation cannot cause a miss.
    public func search(_ text: String, limit: Int? = 50,
                       downloadedOnly: Bool = false,
                       editions: Set<String> = [],
                       publishers: Set<String> = [],
                       heroes: Set<String> = [],
                       states: Set<ReadState> = [],
                       sites: Set<IssueSite> = []) throws -> [StoredIssue] {
        let tokens = Fold.fold(text).split(separator: " ").filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        // Folding leaves only letters, digits and spaces, so no FTS5
        // metacharacter can survive into the query string.
        let match = tokens.map { "\($0)*" }.joined(separator: " ")

        var out: [StoredIssue] = []
        let terms = Self.filterClauses(downloadedOnly: downloadedOnly, editions: editions,
                                       publishers: publishers, heroes: heroes,
                                       states: states, sites: sites)
        let filter = terms.sql.isEmpty ? "" : "AND " + terms.sql.joined(separator: " AND ")
        try db.query("""
            SELECT i.id, i.code, i.number, i.title, i.series, i.style,
                   (SELECT COUNT(*) FROM mirror m WHERE m.issue_id = i.id), i.cover_url,
                   EXISTS(SELECT 1 FROM download d WHERE d.issue_id = i.id),
                   i.hero, i.edition, i.publisher,
                   i.read_at IS NOT NULL,
                   i.last_page,
                   i.download_failed_at IS NOT NULL,
                   i.started_at IS NOT NULL,
                   i.number_to,
                   i.site, i.page_count
            FROM issue_fts f
            JOIN issue i ON i.id = f.rowid
            WHERE issue_fts MATCH ?
            \(filter)
            ORDER BY rank
            \(limit == nil ? "" : "LIMIT ?")
            """, [.text(match)] + terms.args
                  + (limit.map { [SQLValue.int(Int64($0))] } ?? [])) { row in
            out.append(StoredIssue(
                id: row.int(0) ?? 0,
                code: row.string(1),
                number: row.int(2),
                title: row.string(3),
                series: row.string(4),
                hero: row.string(9), edition: row.string(10),
                publisher: row.string(11),
                isRead: (row.int(12) ?? 0) == 1,
                lastPage: row.int(13),
                numberTo: row.int(16),
                started: (row.int(15) ?? 0) == 1,
                downloadFailed: (row.int(14) ?? 0) == 1,
                style: LabelStyle(rawValue: row.string(5) ?? "") ?? .inlinePrevLine,
                mirrorCount: row.int(6) ?? 0,
                coverURL: row.string(7),
                isDownloaded: (row.int(8) ?? 0) == 1,
                site: IssueSite(rawValue: row.string(17) ?? "") ?? .default,
                pageCount: row.int(18)))
        }
        return out
    }

    /// The library in insertion order, for the shelf when no query is active.
    /// An empty search field should show the library, not an empty screen.
    /// `limit: nil` returns everything. The shelf uses that: a cap there is
    /// invisible — the library simply appears to stop, with no indication that
    /// more exists.
    /// Every series present in the library, for the filter menu.
    ///
    /// Read from the issues themselves rather than a fixed list: the forum
    /// gains editions, and a hard-coded menu would quietly stop matching what
    /// has actually been imported.
    ///
    /// Scoped by source for the same reason: with RetroSpec switched off, its
    /// nineteen runs must leave the menu too. A hidden source that still fills
    /// half the Series list with entries that select nothing is worse than
    /// not hiding it at all.
    public func editions(sites: Set<IssueSite> = []) throws -> [String] {
        try distinctColumn("edition", sites: sites)
    }

    /// One shape for the three menu queries. They differed only in a column
    /// name, and adding the source scope to each by hand is three chances to
    /// write it slightly differently.
    ///
    /// The column is never caller-supplied — the three names are literals
    /// below — so interpolating it cannot carry anything from outside.
    private func distinctColumn(_ column: String,
                                sites: Set<IssueSite>) throws -> [String] {
        var out: [String] = []
        var clause = ""
        var args: [SQLValue] = []
        if !sites.isEmpty, sites.count < IssueSite.allCases.count {
            let slots = sites.map { _ in "?" }.joined(separator: ", ")
            clause = "AND site IN (\(slots))"
            args = sites.sorted { $0.rawValue < $1.rawValue }.map { SQLValue.text($0.rawValue) }
        }
        try db.query("""
            SELECT DISTINCT \(column) FROM issue
            WHERE \(column) IS NOT NULL AND \(column) <> '' \(clause)
            ORDER BY \(column) COLLATE NOCASE
            """, args) { row in
            if let value = row.string(0) { out.append(value) }
        }
        return out
    }

    /// Records whether the last download attempt failed.
    ///
    /// Cleared by a success, so the mark always describes the most recent
    /// attempt rather than accumulating history.
    public func setDownloadFailed(_ failed: Bool, issueID: Int) throws {
        try db.run("UPDATE issue SET download_failed_at = ? WHERE id = ?",
                   [failed ? .double(Date().timeIntervalSince1970) : .null,
                    .int(Int64(issueID))])
    }

    /// Marks an issue read or unread.
    ///
    /// A timestamp rather than a flag: it costs nothing now and leaves "what
    /// did I read recently" answerable later.
    public func setRead(_ read: Bool, issueID: Int) throws {
        // Marking read clears both the position and the fact of having
        // started. Otherwise unmarking would drop the issue straight back into
        // "Reading", and there would be no way out of that state at all —
        // finishing and then unmarking is the only exit.
        try db.run("""
            UPDATE issue SET read_at = ?, last_page = NULL, started_at = NULL
            WHERE id = ?
            """, [read ? .double(Date().timeIntervalSince1970) : .null,
                  .int(Int64(issueID))])
    }

    /// Where the reader stopped, so the comic reopens there.
    ///
    /// Assigned, not advanced. This used to keep the furthest page ever
    /// reached, so that flicking back to check something earlier could not
    /// lose your place — but it also meant every way of moving backwards was
    /// discarded. Scrubbing back twenty pages and closing reopened the comic
    /// at the far end, and since a scrub is usually a jump back, scrubbing
    /// looked like it did not count at all.
    public func setLastPage(_ page: Int, issueID: Int) throws {
        // Reaching a second page starts the comic, and nothing about moving
        // around inside it afterwards un-starts it. Scrubbing back to the
        // cover changes where you resume, not whether you have begun.
        try db.run("""
            UPDATE issue SET last_page = ?,
                             started_at = CASE
                                 WHEN ? >= 1 AND started_at IS NULL
                                 THEN strftime('%s', 'now') ELSE started_at END
            WHERE id = ?
            """, [.int(Int64(page)), .int(Int64(page)), .int(Int64(issueID))])
    }

    /// The artwork reference recorded for an issue, if any.
    public func coverURL(forIssue issueID: Int) throws -> String? {
        var out: String?
        try db.query("SELECT cover_url FROM issue WHERE id = ?",
                     [.int(Int64(issueID))]) { row in out = row.string(0) }
        return out
    }

    /// Records artwork for an issue. Used for covers taken from a downloaded
    /// comic's own first page, which the forum page did not provide.
    public func setCoverURL(_ url: String, issueID: Int) throws {
        try db.run("UPDATE issue SET cover_url = ? WHERE id = ?",
                   [.text(url), .int(Int64(issueID))])
    }

    public func lastPage(forIssue issueID: Int) throws -> Int {
        (try? db.scalarInt("SELECT IFNULL(last_page, 0) FROM issue WHERE id = ?",
                           [.int(Int64(issueID))])) ?? 0
    }

    /// Every hero present in the library, for the filter menu.
    ///
    /// Stored spellings, not display ones: the menu shows "Zagor" but has to
    /// filter on "Zagor Te-Nay", which is what the rows actually hold.
    public func heroes(sites: Set<IssueSite> = []) throws -> [String] {
        try distinctColumn("hero", sites: sites)
    }

    /// Every publisher present in the library, for the filter menu.
    public func publishers(sites: Set<IssueSite> = []) throws -> [String] {
        try distinctColumn("publisher", sites: sites)
    }

    /// The WHERE terms shared by both queries.
    ///
    /// Series are OR'd against each other and AND'd with Downloaded: picking
    /// two series means "either of these", not "both at once", which nothing
    /// could satisfy.
    static func filterClauses(downloadedOnly: Bool, editions: Set<String>,
                              publishers: Set<String>, heroes: Set<String>,
                              states: Set<ReadState>,
                              sites: Set<IssueSite> = []) -> (sql: [String], args: [SQLValue]) {
        var sql: [String] = []
        var args: [SQLValue] = []
        if downloadedOnly {
            sql.append("EXISTS(SELECT 1 FROM download f WHERE f.issue_id = i.id)")
        }
        // Which archives the reader wants to see at all. Same shape as the
        // read states below: naming every source is the same as naming none,
        // so neither narrows anything, and an empty set is "no opinion"
        // rather than "nothing" — a caller that has not been taught about
        // sources still gets the whole library.
        if !sites.isEmpty, sites.count < IssueSite.allCases.count {
            let slots = sites.map { _ in "?" }.joined(separator: ", ")
            sql.append("i.site IN (\(slots))")
            args += sites.sorted { $0.rawValue < $1.rawValue }.map { SQLValue.text($0.rawValue) }
        }
        // Bound, never interpolated: these names come out of forum HTML.
        if !editions.isEmpty {
            let slots = editions.map { _ in "?" }.joined(separator: ", ")
            sql.append("i.edition IN (\(slots))")
            args += editions.sorted().map { SQLValue.text($0) }
        }
        if !publishers.isEmpty {
            let slots = publishers.map { _ in "?" }.joined(separator: ", ")
            sql.append("i.publisher IN (\(slots))")
            args += publishers.sorted().map { SQLValue.text($0) }
        }
        if !heroes.isEmpty {
            let slots = heroes.map { _ in "?" }.joined(separator: ", ")
            sql.append("i.hero IN (\(slots))")
            args += heroes.sorted().map { SQLValue.text($0) }
        }
        // Selecting all three is the same as selecting none: both mean the
        // whole library, so neither adds a term.
        if !states.isEmpty, states.count < ReadState.allCases.count {
            let terms = states.sorted { $0.rawValue < $1.rawValue }.map { state -> String in
                switch state {
                case .read:    return "i.read_at IS NOT NULL"
                case .reading: return "(i.read_at IS NULL AND i.started_at IS NOT NULL)"
                case .unread:  return "(i.read_at IS NULL AND i.started_at IS NULL)"
                }
            }
            sql.append("(" + terms.joined(separator: " OR ") + ")")
        }
        return (sql, args)
    }

    public func recent(limit: Int? = 100, downloadedOnly: Bool = false,
                       editions: Set<String> = [],
                       publishers: Set<String> = [],
                       heroes: Set<String> = [],
                       states: Set<ReadState> = [],
                       sites: Set<IssueSite> = []) throws -> [StoredIssue] {
        var out: [StoredIssue] = []
        // Applied in SQL rather than to the results, so a filter cannot be
        // defeated by a cap the caller happens to pass.
        let terms = Self.filterClauses(downloadedOnly: downloadedOnly, editions: editions,
                                       publishers: publishers, heroes: heroes,
                                       states: states, sites: sites)
        let filter = terms.sql.isEmpty ? "" : "WHERE " + terms.sql.joined(separator: " AND ")
        try db.query("""
            SELECT i.id, i.code, i.number, i.title, i.series, i.style,
                   (SELECT COUNT(*) FROM mirror m WHERE m.issue_id = i.id), i.cover_url,
                   EXISTS(SELECT 1 FROM download d WHERE d.issue_id = i.id),
                   i.hero, i.edition, i.publisher,
                   i.read_at IS NOT NULL,
                   i.last_page,
                   i.download_failed_at IS NOT NULL,
                   i.started_at IS NOT NULL,
                   i.number_to,
                   i.site, i.page_count
            FROM issue i \(filter) ORDER BY i.id \(limit == nil ? "" : "LIMIT ?")
            """, terms.args + (limit.map { [SQLValue.int(Int64($0))] } ?? [])) { row in
            out.append(StoredIssue(
                id: row.int(0) ?? 0, code: row.string(1), number: row.int(2),
                title: row.string(3), series: row.string(4),
                hero: row.string(9), edition: row.string(10),
                publisher: row.string(11),
                isRead: (row.int(12) ?? 0) == 1,
                lastPage: row.int(13),
                numberTo: row.int(16),
                started: (row.int(15) ?? 0) == 1,
                downloadFailed: (row.int(14) ?? 0) == 1,
                style: LabelStyle(rawValue: row.string(5) ?? "") ?? .inlinePrevLine,
                mirrorCount: row.int(6) ?? 0,
                coverURL: row.string(7),
                isDownloaded: (row.int(8) ?? 0) == 1,
                site: IssueSite(rawValue: row.string(17) ?? "") ?? .default,
                pageCount: row.int(18)))
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
