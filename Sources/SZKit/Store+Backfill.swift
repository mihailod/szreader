import Foundation

extension Store {

    public struct BackfillResult: Equatable, Sendable {
        public var probed = 0
        public var titled = 0
        public var failed = 0
        public var mismatched = 0

        /// Mirrors this batch asked about at all. Zero means there is nothing
        /// left to ask, which is the only reason to stop — a batch that
        /// produced no titles has still made progress, because those mirrors
        /// will not be asked again.
        public var attempted: Int { probed + failed }
    }

    struct PendingProbe {
        let mirrorID: Int
        let issueID: Int
        let url: String
        let issueNumber: Int?
        let hasTitle: Bool
    }

    /// Un-probed mirrors belonging to issues that still have no title.
    ///
    /// The backfill will happily probe every mirror in the library, but only
    /// these change what the user sees. Probing is throttled to avoid getting
    /// the IP blocked, so at ~1.5s each the difference is minutes rather than
    /// most of an hour.
    public var untitledMirrorCount: Int {
        (try? db.scalarInt("""
            SELECT COUNT(*) FROM mirror m JOIN issue i ON i.id = m.issue_id
            WHERE m.filename IS NULL AND m.probed_at IS NULL AND i.title IS NULL
            """)) ?? 0
    }

    /// Mirrors whose filename we have never resolved. Probe results are
    /// permanent, so this list only ever shrinks.
    func pendingProbes(limit: Int) throws -> [PendingProbe] {
        var out: [PendingProbe] = []
        try db.query("""
            SELECT m.id, m.issue_id, m.url, i.number, i.title IS NOT NULL
            FROM mirror m JOIN issue i ON i.id = m.issue_id
            WHERE m.filename IS NULL AND m.probed_at IS NULL
            ORDER BY (i.title IS NULL) DESC, m.ordinal ASC
            LIMIT ?
            """, [.int(Int64(limit))]) { row in
            out.append(PendingProbe(mirrorID: row.int(0) ?? 0,
                                    issueID: row.int(1) ?? 0,
                                    url: row.string(2) ?? "",
                                    issueNumber: row.int(3),
                                    hasTitle: (row.int(4) ?? 0) == 1))
        }
        return out
    }

    /// Resolves filenames for un-probed mirrors and fills in missing titles.
    ///
    /// This is what gives `labeledBlock` issues (Mister No: a code, no title)
    /// a name. Ordered so title-less issues are probed first — those are the
    /// ones a user cannot currently find by searching.
    @discardableResult
    public func backfillTitles(registry: HostRegistry = HostRegistry(),
                               via transport: Transport,
                               limit: Int = 50) async throws -> BackfillResult {
        var result = BackfillResult()
        for pending in try pendingProbes(limit: limit) {
            guard let url = URL(string: pending.url) else {
                result.failed += 1
                try markProbed(mirrorID: pending.mirrorID)
                continue
            }
            let meta: FileMeta
            do {
                meta = try await registry.probe(url, via: transport)
            } catch {
                result.failed += 1
                try markProbed(mirrorID: pending.mirrorID)
                continue
            }
            result.probed += 1
            try recordProbe(mirrorID: pending.mirrorID, meta: meta)

            guard let filename = meta.filename else { continue }
            let parsed = TitleCleaner.parse(filename)

            // Cross-check the label against the file's own metadata. The forum
            // label can be wrong — one confirmed case in the corpus pointed at
            // a different comic entirely — and trusting it silently would show
            // the wrong title for a file the user then downloads.
            if let labelNumber = pending.issueNumber {
                let numbers = Set(Rx(#"\d{1,5}"#).allMatches(filename).compactMap { Int($0) })
                if !numbers.contains(labelNumber) {
                    result.mismatched += 1
                    try db.run("UPDATE issue SET verified = -1 WHERE id = ?",
                               [.int(Int64(pending.issueID))])
                    continue        // do not overwrite a title from a file we distrust
                }
                try db.run("UPDATE issue SET verified = 1 WHERE id = ?",
                           [.int(Int64(pending.issueID))])
            }

            guard !pending.hasTitle,
                  let title = parsed.title, TitleCleaner.isPlausible(title) else { continue }
            // Scanners shout inconsistently; the shelf should not.
            try setTitle(issueID: pending.issueID, title: TitleCleaner.normaliseCase(title))
            result.titled += 1
        }
        return result
    }

    /// Evens out titles stored before casing was normalised.
    ///
    /// Runs at open, and only rewrites rows it actually changes, so it costs a
    /// single scan once and nothing thereafter. Goes through `setTitle` rather
    /// than a bulk UPDATE so the FTS index is rebuilt in step — a title changed
    /// behind the index's back stops matching what the user types.
    func normaliseStoredTitles() {
        var rows: [(Int, String)] = []
        try? db.query("SELECT id, title FROM issue WHERE title IS NOT NULL") { row in
            if let id = row.int(0), let title = row.string(1) { rows.append((id, title)) }
        }
        for (id, title) in rows {
            let tidied = TitleCleaner.normaliseCase(title)
            if tidied != title { try? setTitle(issueID: id, title: tidied) }
        }
    }

    func recordProbe(mirrorID: Int, meta: FileMeta) throws {
        try db.run("""
            UPDATE mirror SET filename = ?, size = ?, probed_at = strftime('%s', 'now')
            WHERE id = ?
            """, [SQLValue(meta.filename), SQLValue(meta.size), .int(Int64(mirrorID))])
    }

    /// Records that a mirror was asked and gave nothing back.
    ///
    /// A probe can answer without a filename, and a dead link cannot answer at
    /// all. Neither fills `filename`, so without a mark of its own the mirror
    /// stays in the pending set and is asked again on the next batch, for
    /// ever. That is what forced the caller to give up as soon as a batch
    /// stopped producing titles — and a run of five nameless links, which the
    /// older forum pages are full of, then stranded every issue behind them.
    func markProbed(mirrorID: Int) throws {
        try db.run("UPDATE mirror SET probed_at = strftime('%s', 'now') WHERE id = ?",
                   [.int(Int64(mirrorID))])
    }

    /// Updates the title and keeps the FTS index in step.
    ///
    /// The index covers code, number, series and forum context as well, so the
    /// whole row is recomputed — refreshing only the title would drop the rest
    /// and quietly make the issue unfindable by publisher or hero.
    func setTitle(issueID: Int, title: String) throws {
        var code: String?, series: String?, context: String?
        var number: Int?
        try db.query("SELECT code, number, series, context FROM issue WHERE id = ?",
                     [.int(Int64(issueID))]) { row in
            code = row.string(0); number = row.int(1)
            series = row.string(2); context = row.string(3)
        }
        // `title_folded` is deliberately NOT updated. It is the row's identity
        // — part of the natural key `(code, number, title_folded)` that
        // re-import matches on — and it records the label as the page carried
        // it. Rewriting it to the resolved title changed the row's identity, so
        // the next import of the same page matched nothing and inserted every
        // issue a second time. Search does not use it; that goes through
        // `search_text` and the FTS index.
        let searchText = Store.searchText(title: title, code: code, number: number,
                                          series: series, context: context)
        try db.run("""
            UPDATE issue SET title = ?, search_text = ? WHERE id = ?
            """, [.text(title), .text(searchText), .int(Int64(issueID))])
        try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(Int64(issueID))])
        try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                   [.int(Int64(issueID)), .text(searchText)])
    }

    /// Issues still waiting for a name *and* still resolvable — untitled, with
    /// at least one mirror never probed.
    ///
    /// Counted in issues rather than mirrors: an issue usually has two mirrors
    /// but only needs one probed, so mirrors would overstate the work by about
    /// double. Excluding the unresolvable ones matters too — an untitled issue
    /// whose mirrors have all been probed can never be named, and counting it
    /// would leave a progress readout permanently short of its total.
    public var untitledIssueCount: Int {
        (try? db.scalarInt("""
            SELECT COUNT(DISTINCT i.id) FROM issue i JOIN mirror m ON m.issue_id = i.id
            WHERE m.filename IS NULL AND m.probed_at IS NULL AND i.title IS NULL
            """)) ?? 0
    }

    /// Largest recorded size among an issue's mirrors, if any were probed.
    ///
    /// Nil means no mirror has been probed yet, which is not the same as zero
    /// — a caller must not read it as "this file is empty".
    public func knownSize(forIssue issueID: Int) throws -> Int64? {
        var out: Int64?
        try db.query("SELECT MAX(size) FROM mirror WHERE issue_id = ? AND size IS NOT NULL",
                     [.int(Int64(issueID))]) { row in
            if let value = row.int(0), value > 0 { out = Int64(value) }
        }
        return out
    }

    public func recordFilename(_ filename: String, forMirrorAt url: String) throws {
        try db.run("UPDATE mirror SET filename = ? WHERE url = ?",
                   [.text(filename), .text(url)])
    }

    public func recordSize(_ size: Int64, forMirrorAt url: String) throws {
        try db.run("UPDATE mirror SET size = ? WHERE url = ?", [.int(size), .text(url)])
    }

    public func filename(forMirrorAt url: String) throws -> String? {
        var out: String?
        try db.query("SELECT filename FROM mirror WHERE url = ?", [.text(url)]) { out = $0.string(0) }
        return out
    }
}

// MARK: - Covers the catalogue has but the page did not link

extension Store {

    public struct CoverBackfillResult: Equatable, Sendable {
        public var asked = 0
        public var found = 0
    }

    struct PendingCover {
        let issueID: Int
        let number: Int
        let sibling: String
        let siblingNumber: Int
    }

    /// Issues with no artwork, paired with a catalogued cover from the same
    /// edition to read the naming from.
    ///
    /// Matched on the topic an issue came from, and then only when every
    /// catalogued neighbour agrees on where the covers live.
    ///
    /// The catalogue files covers by series — Veliki Blek's under
    /// `naslovnice/VelikiBlek`, Mister No's under `naslovnice/MisterNo` —
    /// while one edition carries several series: LUNOV MAGNUS STRIP alone
    /// runs Kit Teler, Martin Mystere, Mister No and Zagor. Offered a
    /// neighbour from the wrong one, the guessed number very likely exists
    /// there too, and the result is a plausible-looking wrong cover.
    ///
    /// The topic is the identity rather than hero and edition: a page with no
    /// breadcrumb leaves the hero unknown, and two unrelated series then look
    /// alike under one edition. Issues from one topic are one series by
    /// construction. The directory check backs it up — neighbours pointing at
    /// two different places are no evidence at all, so nothing is guessed.
    func pendingCovers(limit: Int) throws -> [PendingCover] {
        var ids: [(id: Int, number: Int)] = []
        try db.query("""
            SELECT i.id, i.number FROM issue i
            WHERE i.cover_url IS NULL
              AND i.cover_asked_at IS NULL
              AND i.number IS NOT NULL
              AND i.context IS NOT NULL
            LIMIT ?
            """, [.int(Int64(limit))]) { row in
            if let id = row.int(0), let number = row.int(1) { ids.append((id, number)) }
        }

        var out: [PendingCover] = []
        for (id, number) in ids {
            var siblings: [(url: String, number: Int)] = []
            try db.query("""
                SELECT s.cover_url, s.number
                FROM issue i
                JOIN issue s ON s.context IS i.context
                            AND s.cover_url IS NOT NULL
                            AND s.number IS NOT NULL
                            AND s.id <> i.id
                WHERE i.id = ?
                """, [.int(Int64(id))]) { row in
                if let url = row.string(0), let n = row.int(1) { siblings.append((url, n)) }
            }

            let directories = Set(siblings.map { sibling -> String in
                let url = sibling.url
                return String(url[..<(url.lastIndex(of: "/") ?? url.endIndex)])
            })
            guard directories.count == 1, let pick = siblings.first else { continue }
            out.append(PendingCover(issueID: id, number: number,
                                    sibling: pick.url, siblingNumber: pick.number))
        }
        return out
    }

    /// Asks the catalogue for covers the page left out.
    ///
    /// A guess is recorded only when an image comes back: a number the
    /// catalogue does not have redirects to an HTML page rather than 404ing,
    /// and a cover URL that resolves to nothing would sit on the shelf for
    /// good, showing an empty frame and keeping the comic's own first page
    /// from ever standing in for it.
    @discardableResult
    public func backfillCovers(via transport: Transport,
                               limit: Int = 20) async throws -> CoverBackfillResult {
        var result = CoverBackfillResult()
        for pending in try pendingCovers(limit: limit) {
            guard let guess = CoverGuess.url(likeSibling: pending.sibling,
                                             number: pending.siblingNumber,
                                             wanted: pending.number),
                  let url = URL(string: guess) else {
                try markCoverAsked(issueID: pending.issueID)
                continue
            }
            result.asked += 1
            let response = try? await transport.send(HTTPRequest(url: url))
            if let response,
               CoverGuess.isImage(status: response.status,
                                  contentType: response.headers["Content-Type"]
                                            ?? response.headers["content-type"],
                                  body: response.body) {
                try setCoverURL(guess, issueID: pending.issueID)
                result.found += 1
            }
            try markCoverAsked(issueID: pending.issueID)
        }
        return result
    }

    func markCoverAsked(issueID: Int) throws {
        try db.run("UPDATE issue SET cover_asked_at = strftime('%s', 'now') WHERE id = ?",
                   [.int(Int64(issueID))])
    }

    /// Issues that could still gain a cover from the catalogue.
    public var coverlessIssueCount: Int {
        (try? db.scalarInt("""
            SELECT COUNT(*) FROM issue
            WHERE cover_url IS NULL AND cover_asked_at IS NULL AND number IS NOT NULL
            """)) ?? 0
    }
}
