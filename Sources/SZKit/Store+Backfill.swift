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

        /// Issues this batch looked at, whether or not there was anything to
        /// ask about. Zero means there is nothing left to look at, which is
        /// the only reason to stop — an issue with no answerable question is
        /// still progress, because it is marked and drops out of the queue.
        public var considered = 0
    }

    struct PendingCover {
        let issueID: Int
        let number: Int
        let sibling: String
        let siblingNumber: Int
    }

    /// An issue the shelf has nothing to draw, and everything known about it
    /// that might address the catalogue.
    struct CoverlessIssue {
        let issueID: Int
        let number: Int
        let hero: String?
        let edition: String?
        let catalogue: CatalogueRef?
    }

    /// Issues that could still gain artwork: nothing to draw, and not yet
    /// asked about.
    ///
    /// "Nothing to draw" covers two states that used to be one. A row with no
    /// cover at all is the obvious one. A row holding a URL that no longer
    /// resolves looked, to every query here, exactly like a row that was
    /// already taken care of — so an issue whose artwork died on some image
    /// host was never reconsidered, and the empty frame it showed was
    /// permanent.
    ///
    /// StripZona only. RetroSpec's issues are magazines rather than comics and
    /// stripovi.com does not catalogue them, so asking would be a request per
    /// issue against a host that cannot have the answer. Their artwork comes
    /// from their own archive, and where it fails the comic's own first page
    /// still stands in.
    func coverlessIssues(limit: Int) throws -> [CoverlessIssue] {
        var out: [CoverlessIssue] = []
        try db.query("""
            SELECT id, number, hero, edition, catalogue_code, catalogue_number
            FROM issue
            WHERE (cover_url IS NULL OR cover_dead_at IS NOT NULL)
              AND cover_asked_at IS NULL
              AND number IS NOT NULL
              AND site = ?
            LIMIT ?
            """, [.text(IssueSite.stripzona.rawValue), .int(Int64(limit))]) { row in
            guard let id = row.int(0), let number = row.int(1) else { return }
            var reference: CatalogueRef?
            if let code = row.string(4), let filed = row.int(5) {
                reference = CatalogueRef(code: code, number: filed)
            }
            out.append(CoverlessIssue(issueID: id, number: number,
                                      hero: row.string(2), edition: row.string(3),
                                      catalogue: reference))
        }
        return out
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
        try coverlessIssues(limit: limit).compactMap { issue in
            try siblingCover(forIssue: issue.issueID).map {
                PendingCover(issueID: issue.issueID, number: issue.number,
                             sibling: $0.url, siblingNumber: $0.number)
            }
        }
    }

    /// A catalogued cover from the same topic to read the naming from, when
    /// the neighbours agree on where covers live.
    func siblingCover(forIssue id: Int) throws -> (url: String, number: Int)? {
        var siblings: [(url: String, number: Int)] = []
        try db.query("""
            SELECT s.cover_url, s.number
            FROM issue i
            JOIN issue s ON s.context IS i.context
                        AND s.cover_url IS NOT NULL
                        AND s.cover_dead_at IS NULL
                        AND s.number IS NOT NULL
                        AND s.id <> i.id
            WHERE i.id = ? AND i.context IS NOT NULL
            """, [.int(Int64(id))]) { row in
            if let url = row.string(0), let n = row.int(1) { siblings.append((url, n)) }
        }

        let directories = Set(siblings.map { sibling -> String in
            let url = sibling.url
            return String(url[..<(url.lastIndex(of: "/") ?? url.endIndex)])
        })
        guard directories.count == 1 else { return nil }
        return siblings.first
    }

    /// Asks the catalogue for covers the page did not give.
    ///
    /// Two questions, in order of how much the page itself says. A neighbour
    /// on the same topic names the pattern outright, so that guess goes first.
    /// Failing one — a topic carrying a single issue has no neighbours, and a
    /// topic whose art was posted to a since-dead image host has none the
    /// catalogue would recognise — the naming is assembled from what the row
    /// knows: see `CoverGuess.catalogueCandidates`.
    ///
    /// A guess is recorded only when an image comes back. A number the
    /// catalogue does not have redirects to an HTML page rather than 404ing,
    /// and a cover URL that resolves to nothing would sit on the shelf for
    /// good, showing an empty frame and keeping the comic's own first page
    /// from ever standing in for it. That rule is the whole reason it is safe
    /// to ask more than one question per issue.
    @discardableResult
    public func backfillCovers(via transport: Transport,
                               limit: Int = 20) async throws -> CoverBackfillResult {
        var result = CoverBackfillResult()
        let pending = try coverlessIssues(limit: limit)
        guard !pending.isEmpty else { return result }
        // Built once for the batch: it is a scan of the covers the library
        // already holds, and it does not change while the batch runs.
        let index = try catalogueIndex()

        for issue in pending {
            var candidates: [String] = []
            if let sibling = try siblingCover(forIssue: issue.issueID),
               let guess = CoverGuess.url(likeSibling: sibling.url,
                                          number: sibling.number, wanted: issue.number) {
                candidates.append(guess)
            }
            for candidate in CoverGuess.catalogueCandidates(
                hero: issue.hero, edition: issue.edition,
                catalogue: issue.catalogue, number: issue.number, index: index)
            where !candidates.contains(candidate) {
                candidates.append(candidate)
            }

            defer { try? markCoverAsked(issueID: issue.issueID) }
            result.considered += 1
            guard !candidates.isEmpty else { continue }
            result.asked += 1
            for candidate in candidates {
                guard let url = URL(string: candidate) else { continue }
                if await isCover(url, via: transport) {
                    try setCoverURL(candidate, issueID: issue.issueID)
                    result.found += 1
                    break
                }
            }
        }
        return result
    }

    /// The naming the library has already seen the catalogue use.
    func catalogueIndex() throws -> CatalogueIndex {
        var rows: [(hero: String?, edition: String?, url: String)] = []
        try db.query("""
            SELECT hero, edition, cover_url FROM issue
            WHERE cover_url LIKE '%stripovi.com/naslovnice/%' AND cover_dead_at IS NULL
            """) { row in
            if let url = row.string(2) { rows.append((row.string(0), row.string(1), url)) }
        }
        return CatalogueIndex(rows: rows)
    }

    /// Whether a URL really is artwork.
    ///
    /// HEAD for the catalogue, which answers with the same status and content
    /// type as a GET would and saves fetching the image to find out. Every
    /// other host keeps the GET it always had: HEAD is not universally
    /// implemented, and reading a 405 as "no cover" would lose artwork the old
    /// path found.
    private func isCover(_ url: URL, via transport: Transport) async -> Bool {
        let catalogued = url.host?.hasSuffix("stripovi.com") == true
        let request = HTTPRequest(url: url, method: catalogued ? "HEAD" : "GET")
        guard let response = try? await transport.send(request) else { return false }
        return CoverGuess.isImage(status: response.status,
                                  contentType: response.headers["content-type"],
                                  body: response.body)
    }

    func markCoverAsked(issueID: Int) throws {
        try db.run("UPDATE issue SET cover_asked_at = strftime('%s', 'now') WHERE id = ?",
                   [.int(Int64(issueID))])
    }

    /// Downloaded issues with nothing to show for artwork.
    ///
    /// A cover is captured from a comic's own first page when its download
    /// finishes — but only if it had no cover *at that moment*. An issue whose
    /// remote artwork dies later than that falls through the gap: the file is
    /// on the device, the pages are right there, and the shelf shows a grey
    /// rectangle for ever because nothing ever asks again.
    ///
    /// That is what happened to Joystik, whose covers are hotlinked from a
    /// host the shelf could not reach, and it will happen to any source whose
    /// images move or go away.
    ///
    /// Limited per pass. Each one opens an archive and renders a page, so this
    /// is deliberately a trickle rather than a job that runs over a library of
    /// twenty thousand at launch.
    public func downloadedIssuesLackingCover(limit: Int = 12) throws -> [Int] {
        var found: [Int] = []
        try db.query("""
            SELECT i.id FROM issue i
            JOIN download d ON d.issue_id = i.id
            WHERE (i.cover_url IS NULL OR i.cover_dead_at IS NOT NULL)
              AND i.cover_capture_failed_at IS NULL
            ORDER BY i.id DESC LIMIT ?
            """, [.int(Int64(limit))]) { row in
            if let id = row.int(0) { found.append(id) }
        }
        return found
    }

    /// Issues that could still gain a cover from the catalogue.
    public var coverlessIssueCount: Int {
        (try? db.scalarInt("""
            SELECT COUNT(*) FROM issue
            WHERE (cover_url IS NULL OR cover_dead_at IS NOT NULL)
              AND cover_asked_at IS NULL AND number IS NOT NULL AND site = ?
            """, [.text(IssueSite.stripzona.rawValue)])) ?? 0
    }
}
