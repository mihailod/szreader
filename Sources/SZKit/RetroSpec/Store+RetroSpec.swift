import Foundation

/// What one pass of the seed did.
public struct SeedReport: Equatable, Sendable {
    public let inserted: Int
    public let updated: Int
    /// True when the shipped catalogue had already been applied and nothing
    /// was read at all.
    public let skipped: Bool

    public static let alreadyCurrent = SeedReport(inserted: 0, updated: 0, skipped: true)
    public var isEmpty: Bool { inserted == 0 && updated == 0 }
}

public extension Store {

    /// Which build of the shipped catalogue this library has taken.
    static let catalogueStamp = "retrospec_catalogue"

    // MARK: - Entry points

    /// Applies the catalogue that shipped in the bundle, unless it has
    /// already been applied.
    ///
    /// Called on every launch. The common case is the second one — the stamp
    /// matches, nothing is decoded, and the whole thing costs one row read.
    @discardableResult
    func seedRetroSpecCatalogue() throws -> SeedReport {
        guard let url = Bundle.module.url(forResource: "retrospec-catalog",
                                          withExtension: "json") else {
            throw SeedError.catalogueMissing
        }
        let data = try Data(contentsOf: url)
        // Stamped by content, not by the date inside it. `generated` is a
        // calendar day, so two builds on one day are indistinguishable — and
        // the build that fixed three broken titles was the same day as the
        // build that introduced them. Every device that had already seeded
        // would have skipped the correction and kept the damage.
        return try seed(try RetroSpecCatalogFile.decode(data), stamp: Self.digest(data))
    }

    /// A stable fingerprint of the shipped file.
    ///
    /// Stable across launches is the whole requirement, which rules out
    /// `Hasher` — Swift seeds it randomly per process, so it would re-seed
    /// the catalogue on every single launch.
    static func digest(_ data: Data) -> String {
        SHA256.hex(data)
    }

    /// Applies a catalogue, skipping the work when this exact build of it is
    /// already in the library.
    ///
    /// Idempotent whether or not the stamp says so: `force` exists for the
    /// tests, which need to prove that a second pass over the same data
    /// changes nothing, and the stamp would otherwise make that vacuous.
    @discardableResult
    func seed(_ file: RetroSpecCatalogFile, force: Bool = false,
              stamp: String? = nil) throws -> SeedReport {
        guard file.version <= RetroSpecCatalogFile.currentVersion else {
            throw SeedError.tooNew(file.version)
        }
        let stamp = stamp ?? "\(file.version)/\(file.generated)"
        if !force, try meta(Self.catalogueStamp) == stamp { return .alreadyCurrent }

        let series = Dictionary(uniqueKeysWithValues: file.series.map { ($0.key, $0) })
        var inserted = 0, updated = 0

        // One transaction for all 653. Six hundred separate commits on a
        // phone's flash is the difference between a launch that pauses and
        // one that does not.
        try db.transaction {
            for issue in file.issues {
                guard let run = series[issue.series] else { continue }
                let existing = try retroSpecID(code: issue.id)
                let id = try writeRetroSpec(issue, run: run, base: file.base, existing: existing)
                if existing == nil { inserted += 1 } else { updated += 1 }
                try writeRetroSpecMirror(issue, base: file.base, issueID: id)
            }
            try setMeta(Self.catalogueStamp, stamp)
        }
        return SeedReport(inserted: inserted, updated: updated, skipped: false)
    }

    // MARK: - Rows

    /// Looked up by the site's own id rather than by the natural key.
    ///
    /// The natural key includes `title_folded`, and a rebuilt catalogue can
    /// legitimately change a title — a month's spelling corrected upstream.
    /// Keying the seed on it would make that arrive as a *second* row rather
    /// than an edit, which is the identity bug the forum importer already
    /// carries healing code for. The site's id never changes; it is the id.
    private func retroSpecID(code: String) throws -> Int64? {
        var found: Int64?
        try db.query("SELECT id FROM issue WHERE site = ? AND code = ?",
                     [.text(IssueSite.retrospec.rawValue), .text(code)]) { row in
            found = Int64(row.int(0) ?? 0)
        }
        return found
    }

    /// Writes one issue, leaving everything the reader owns alone.
    ///
    /// An update touches only what the catalogue is authoritative about.
    /// `read_at`, `started_at`, `last_page` and the download rows belong to
    /// the person using the app: a corrected title must not mark a finished
    /// magazine unread.
    private func writeRetroSpec(_ issue: RetroSpecCatalogFile.Issue,
                                run: RetroSpecCatalogFile.Series,
                                base: String, existing: Int64?) throws -> Int64 {
        let folded = Fold.fold(issue.title)
        // The run's name goes in the searchable context so that typing
        // "svet kompjutera" finds an issue titled only "Oktobar 1984", and
        // the source's name so that "retrospec" finds the lot.
        let context = "\(run.name) \(IssueSite.retrospec.display)"
        let search = Self.searchText(title: issue.title, code: issue.id,
                                     number: issue.number, series: run.name,
                                     context: context)

        let values: [SQLValue] = [
            .text(issue.id), .int(Int64(issue.number)), .text(issue.title),
            .text(folded), .text(run.name), .text(run.name),
            .text(IssueSite.retrospec.display),
            SQLValue(issue.coverURL(base: base)),
            .text(context), .text(search),
            SQLValue(issue.pages),
        ]

        let id: Int64
        if let existing {
            try db.run("""
                UPDATE issue SET code = ?, number = ?, title = ?, title_folded = ?,
                                 series = ?, edition = ?, publisher = ?, cover_url = ?,
                                 context = ?, search_text = ?, page_count = ?
                WHERE id = ?
                """, values + [.int(existing)])
            id = existing
        } else {
            // `style` records how a forum label was parsed and means nothing
            // here — there is no label, only a generated table cell. Stored
            // because the column is NOT NULL.
            id = try db.run("""
                INSERT INTO issue
                  (code, number, title, title_folded, series, edition, publisher,
                   cover_url, context, search_text, page_count, site, style, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, values + [.text(IssueSite.retrospec.rawValue),
                               .text(LabelStyle.labeledBlock.rawValue),
                               .text("retrospec catalogue")])
        }

        // FTS is maintained by hand and keyed on rowid; deleting first is
        // what stops a re-seed failing on the rowid constraint.
        try db.run("DELETE FROM issue_fts WHERE rowid = ?", [.int(id)])
        try db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                   [.int(id), .text(search)])
        return id
    }

    /// The one archive an issue has.
    ///
    /// The size is recorded now, from the site's own headers at build time,
    /// which is what lets a download too large for the device be refused
    /// before it starts — `checkSpace` asks nothing over the network and so
    /// does nothing at all unless a size is already known.
    ///
    /// Nothing here marks the eight missing archives dead. The site may
    /// restore them, and nothing in the app ever clears that flag; letting
    /// the download discover a 404 and record it keeps the answer current
    /// instead of freezing today's.
    private func writeRetroSpecMirror(_ issue: RetroSpecCatalogFile.Issue,
                                      base: String, issueID: Int64) throws {
        let url = issue.zipURL(base: base)
        let host = URL(string: url)?.host ?? "retrospec"
        let filename = url.split(separator: "/").last.map(String.init)
        try db.run("""
            INSERT OR IGNORE INTO mirror (issue_id, url, host, ordinal, filename, size)
            VALUES (?, ?, ?, 0, ?, ?)
            """, [.int(issueID), .text(url), .text(host),
                  SQLValue(filename), SQLValue(issue.bytes.map(Int.init))])
        // A re-seed refreshes what the site reported without disturbing the
        // row's identity, so an archive that changed size stops being
        // checked against a stale number.
        try db.run("UPDATE mirror SET filename = ?, size = ? WHERE url = ?",
                   [SQLValue(filename), SQLValue(issue.bytes.map(Int.init)), .text(url)])
    }

    /// Whether this library already holds the catalogue.
    ///
    /// Asked once by a build that introduces the source switch, to tell a
    /// reader who already has these magazines from one meeting them for the
    /// first time. The rows are the evidence rather than the stamp: a row is
    /// what a reader would notice going missing.
    func hasSeededRetroSpec() throws -> Bool {
        try db.scalarInt("SELECT EXISTS(SELECT 1 FROM issue WHERE site = ?)",
                         [.text(IssueSite.retrospec.rawValue)]) == 1
    }

    // MARK: - Stamp

    func meta(_ key: String) throws -> String? {
        var value: String?
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { row in
            value = row.string(0)
        }
        return value
    }

    func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                   [.text(key), .text(value)])
    }
}

public enum SeedError: Error, CustomStringConvertible {
    case catalogueMissing
    case tooNew(Int)

    public var description: String {
        switch self {
        case .catalogueMissing:
            return "the RetroSpec catalogue is missing from the bundle"
        case .tooNew(let version):
            return "the RetroSpec catalogue is version \(version), which this build "
                 + "does not understand"
        }
    }
}
