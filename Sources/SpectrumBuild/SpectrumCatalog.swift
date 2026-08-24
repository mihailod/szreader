import Foundation
import SZKit

/// Builds the shipped ZXDB catalogues.
///
/// The strategy is the one the validation run settled, and it is not the
/// obvious one. A mask expands to `<identifier>/<filename>`, and only the
/// identifier half can be trusted: of 114 sampled issues, 101 reached a real
/// item but four of those named a file the item does not hold — a mask
/// carrying a supplement name the file never had, another written before the
/// scan was renamed. So this expands the mask for the *identifier*, then asks
/// the item what it actually contains.
///
/// That costs one metadata request per item and pays for itself three times:
/// the real filename, the exact byte count (no HEAD probe anywhere in this
/// build), and a place to put the lowercase retry that the case-sensitive
/// identifier lookup needs.
struct SpectrumCatalog {
    let dump: ZXDBDump
    let cache: URL
    let allowNetwork: Bool

    /// One issue as ZXDB describes it, before the archive is asked anything.
    struct Planned {
        let zxdbID: String
        let seriesKey: String
        let seriesName: String
        let language: String?
        let country: String?
        let group: Spectrum.Group
        let identifier: String
        /// What the mask thinks the file is called. A hint, not an answer.
        let suggestedFile: String
        let year: Int?
        let month: Int?
        let number: Int?
        let special: String?
        let supplement: String?
        /// Books carry their own title; a magazine issue's is built from its
        /// numbers. Nil for everything that is not a book.
        var bookTitle: String? = nil
    }

    // MARK: - Planning

    /// Every issue this build could ship, with its mask already expanded.
    ///
    /// Expansion failures are counted rather than thrown: an issue with no
    /// number that its magazine's mask wants is simply not reachable, and the
    /// right response is to leave it out and say how many were left out.
    func plan() -> (planned: [Planned], unexpandable: [String: Int]) {
        let magazines = Dictionary(uniqueKeysWithValues: dump["magazines"].compactMap {
            row in row["id"].map { ($0, row) }
        })
        var planned: [Planned] = []
        var unexpandable: [String: Int] = [:]

        for issue in dump["issues"] {
            guard let magazineID = issue["magazine_id"],
                  let magazine = magazines[magazineID],
                  let group = Spectrum.Group.of(magtype: magazine["magtype_id"],
                                                language: magazine["language_id"]),
                  let mask = issue["archive_mask"] ?? magazine["archive_mask"],
                  let zxdbID = issue["id"]
            else { continue }

            let fields = ZXDBMask.Issue(
                number: issue.int("number"),
                volume: issue.int("volume"),
                year: issue.int("date_year"),
                month: issue.int("date_month"),
                day: issue.int("date_day"),
                special: issue["special"],
                supplement: issue["supplement"])

            switch ZXDBMask.url(mask, for: fields) {
            case .failure(let why):
                unexpandable["\(why)", default: 0] += 1
            case .success(let url):
                guard let (identifier, file) = Validator.split(url) else {
                    unexpandable["not an archive.org download URL", default: 0] += 1
                    continue
                }
                planned.append(Planned(
                    zxdbID: zxdbID,
                    seriesKey: Self.key(magazineID, magazine["name"]),
                    seriesName: magazine["name"] ?? magazineID,
                    language: magazine["language_id"],
                    country: magazine["country_id"],
                    group: group,
                    identifier: identifier,
                    suggestedFile: file,
                    year: fields.year, month: fields.month, number: fields.number,
                    special: fields.special, supplement: fields.supplement))
            }
        }
        return (planned, unexpandable)
    }

    // MARK: - Books

    /// Every English book with a scan this app can actually fetch.
    ///
    /// A different pair of tables from everything above. A magazine issue is
    /// an `issues` row whose scan is named by a mask; a book is an `entries`
    /// row with a book genre whose scan is a `downloads` row — a real recorded
    /// file, no template involved. What the two paths share is the last step,
    /// which is asking archive.org how big the file is.
    ///
    /// Shelved by imprint. ZXDB records a machine for a book, but leaves it
    /// blank for 172 of these 187 — a Spectrum book is simply the default and
    /// nobody fills it in — so it groups nothing. The publisher is filled in
    /// for 179 of them and is how these books are actually known: Usborne,
    /// Interface, Melbourne House, Sunshine.
    func planBooks() -> [Planned] {
        let bookGenres = Set(dump["genretypes"].compactMap { row -> String? in
            guard let id = row["id"], let text = row["text"] else { return nil }
            return text.hasPrefix("Book:") || text == "E-Book" ? id : nil
        })
        let titles = Dictionary(uniqueKeysWithValues: dump["entries"].compactMap {
            row -> (String, String)? in
            guard let id = row["id"], let genre = row["genretype_id"],
                  bookGenres.contains(genre), row["language_id"] == "en",
                  let title = row["title"] else { return nil }
            return (id, title)
        })

        let labels = Dictionary(uniqueKeysWithValues: dump["labels"].compactMap {
            row -> (String, String)? in
            guard let id = row["id"], let name = row["name"] else { return nil }
            return (id, name)
        })
        var publisher: [String: String] = [:]
        for row in dump["publishers"] {
            guard let entry = row["entry_id"], let label = row["label_id"],
                  publisher[entry] == nil else { continue }
            publisher[entry] = labels[label]
        }

        var planned: [Planned] = []
        var seen: Set<String> = []
        for row in dump["downloads"] {
            guard let entry = row["entry_id"], let title = titles[entry],
                  let type = row["filetype_id"], type == "46" || type == "60",
                  let link = row["file_link"], Spectrum.canFetchBook(link: link),
                  !seen.contains(entry) else { continue }
            // One `base` per catalogue, and it is archive.org's. The two dozen
            // books served from spectrumcomputing.co.uk cannot share it, and a
            // second host is not worth a second catalogue shape for two dozen
            // rows.
            guard let url = URL(string: link),
                  let (identifier, file) = Validator.split(url) else { continue }
            seen.insert(entry)

            let imprint = publisher[entry] ?? "Other publishers"
            planned.append(Planned(
                zxdbID: "book-\(entry)",
                seriesKey: Self.slug(imprint),
                seriesName: imprint,
                language: "en",
                country: nil,
                group: .books,
                identifier: identifier,
                suggestedFile: file,
                year: nil, month: nil, number: nil,
                special: nil, supplement: nil,
                bookTitle: title))
        }
        return planned
    }

    /// A stable series key. The magazine id is what makes it unique — two
    /// runs of "Moj mikro" in different languages are different series and
    /// their names do not tell them apart.
    static func key(_ id: String, _ name: String?) -> String {
        let slug = Self.slug(name ?? "")
        return slug.isEmpty ? "zxdb-\(id)" : "\(slug)-\(id)"
    }

    /// A name reduced to something that can be a key.
    static func slug(_ name: String) -> String {
        name
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, c in
                if c == "-" && (out.isEmpty || out.hasSuffix("-")) { return }
                out.append(c)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - Building

    func build(group: Spectrum.Group, limit: Int?, output: URL) async throws {
        var unexpandable: [String: Int] = [:]
        var mine: [Planned]
        if group == .books {
            mine = planBooks()
        } else {
            let (planned, why) = plan()
            unexpandable = why
            mine = planned.filter { $0.group == group }
        }
        if let limit { mine = Array(mine.prefix(limit)) }

        let identifiers = Set(mine.map(\.identifier))
        print("  \(mine.count) issues across "
              + "\(Set(mine.map(\.seriesKey)).count) series")
        print("  \(identifiers.count) distinct archive.org items to ask about")
        if !unexpandable.isEmpty {
            print("  (\(unexpandable.values.reduce(0, +)) issues could not be "
                  + "expanded: \(unexpandable))")
        }
        print("")

        let store = ItemStore(directory: cache.appendingPathComponent("items"),
                              transport: URLSessionTransport(),
                              allowNetwork: allowNetwork)

        // Ask the archive about every distinct item first, in parallel, so
        // assembly below is a pass over a warm cache rather than 2,444 round
        // trips taken one at a time.
        if allowNetwork {
            let started = Date()
            await store.warm(identifiers.sorted(), width: 5) { done, total in
                guard done % 100 == 0 || done == total else { return }
                let rate = Double(done) / max(Date().timeIntervalSince(started), 1)
                let left = Int(Double(total - done) / max(rate, 0.001))
                print("  fetched \(done)/\(total) items — "
                      + "about \(left / 60)m \(left % 60)s left")
            }
            print("")
        }

        var issues: [ShippedCatalog.Issue] = []
        var seriesSeen: [String: Planned] = [:]
        var missingItems = 0, noReadableFile = 0
        var renamed = 0, duplicates = 0
        /// Every "<item>/<file>" already spoken for, so no two rows can name
        /// the same download.
        var claimed: Set<String> = []

        // Chronological within each series, so `number` counts a real run.
        let ordered = mine.sorted { a, b in
            (a.seriesKey, a.year ?? .max, a.month ?? 0, a.number ?? 0, a.zxdbID)
                < (b.seriesKey, b.year ?? .max, b.month ?? 0, b.number ?? 0, b.zxdbID)
        }
        var rank: [String: Int] = [:]

        for (n, entry) in ordered.enumerated() {
            seriesSeen[entry.seriesKey] = entry
            guard let item = try await store.item(entry.identifier) else {
                missingItems += 1
                continue
            }
            // The file the mask named, if the item really has it; otherwise
            // whatever the item offers that this app can open.
            let names = Set(item.files.map(\.name))
            let chosen: String?
            let bytes: Int64?
            if names.contains(entry.suggestedFile) {
                chosen = entry.suggestedFile
                bytes = item.files.first { $0.name == entry.suggestedFile }?.bytes
            } else if let best = item.readableFiles.first {
                chosen = best.name
                bytes = best.bytes
                renamed += 1
            } else {
                chosen = nil
                bytes = nil
            }
            guard let file = chosen else {
                noReadableFile += 1
                continue
            }
            // One file, one row.
            //
            // Several issues often share an archive.org item, and when the
            // mask's filename is stale for all of them the fallback above
            // hands every one the item's best readable file — nineteen Micro
            // Mart rows all pointing at the same 2016 PDF. A handful of ZXDB
            // issues also expand to byte-identical URLs outright. Either way
            // the second claimant is not a different issue that happens to
            // share a scan; it is a row the build cannot place, and a missing
            // row is better than a wrong one that looks right on the shelf.
            let claim = "\(entry.identifier)/\(file)"
            guard claimed.insert(claim).inserted else {
                duplicates += 1
                continue
            }

            rank[entry.seriesKey, default: 0] += 1
            issues.append(ShippedCatalog.Issue(
                id: entry.zxdbID,
                series: entry.seriesKey,
                number: rank[entry.seriesKey] ?? 1,
                title: Self.title(for: entry),
                year: entry.year, month: entry.month,
                zip: ArchiveOrg.path(item: entry.identifier, file: file),
                cover: ArchiveOrg.firstPagePath(item: entry.identifier),
                thumb: ArchiveOrg.thumbnailPath(item: entry.identifier),
                bytes: bytes,
                // Deliberately nil. `archive-build` reads a page count out of
                // each item's scandata XML, which is a *second* request per
                // item; at this scale that is another ten thousand requests to
                // put a number on a shelf that reads perfectly without it.
                pages: nil,
                dead: nil))

            if (n + 1) % 100 == 0 {
                print("  \(n + 1)/\(ordered.count) — \(issues.count) built, "
                      + "\(missingItems) items missing, \(renamed) renamed")
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let file = ShippedCatalog(
            version: ShippedCatalog.currentVersion,
            generated: formatter.string(from: Date()),
            base: ArchiveOrg.base,
            series: seriesSeen.values
                .filter { entry in issues.contains { $0.series == entry.seriesKey } }
                .map { .init(key: $0.seriesKey, name: $0.seriesName,
                             code: $0.country ?? "", language: $0.language) }
                .sorted { $0.key < $1.key },
            issues: issues)

        try Self.validate(file)
        let data = try ShippedCatalog.encoder().encode(file)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)

        print("""

          built  \(issues.count) issues, \(file.series.count) series
          missing item   \(missingItems)
          no readable file  \(noReadableFile)
          dropped, file already claimed  \(duplicates)
          filename recovered from the item  \(renamed)
          wrote \(output.path) — \(data.count / 1024) KB
        """)
    }

    /// What the shelf calls one issue.
    static func title(for entry: Planned) -> String {
        if let book = entry.bookTitle { return book }
        var parts: [String] = []
        if let number = entry.number { parts.append("Issue \(number)") }
        if let special = entry.special, !special.isEmpty { parts.append(special) }
        if let supplement = entry.supplement, !supplement.isEmpty {
            parts.append("(\(supplement))")
        }
        if parts.isEmpty {
            if let year = entry.year, let month = entry.month,
               (1...12).contains(month) {
                parts.append("\(ZXDBMask.months[month - 1]) \(year)")
            } else if let year = entry.year {
                parts.append(String(year))
            } else {
                parts.append(entry.seriesName)
            }
        }
        return parts.joined(separator: " ")
    }

    /// The checks a catalogue has to pass before it is written.
    ///
    /// Not RetroSpec's checks. That one demands every run be numbered 1...n
    /// with no gaps, which is true of a complete archive of 653 issues and is
    /// not true here: ZXDB lists issues whose scans were never uploaded, so a
    /// run legitimately arrives with holes. What must hold is that every row
    /// is addressable and belongs to a series that exists.
    static func validate(_ file: ShippedCatalog) throws {
        guard !file.issues.isEmpty else {
            throw ZXDBDump.Failure("built nothing — refusing to write an empty catalogue")
        }
        let ids = Set(file.issues.map(\.id))
        guard ids.count == file.issues.count else {
            throw ZXDBDump.Failure("duplicate issue id")
        }
        let keys = Set(file.series.map(\.key))
        for issue in file.issues where !keys.contains(issue.series) {
            throw ZXDBDump.Failure("\(issue.id) belongs to unknown series \(issue.series)")
        }
        for issue in file.issues where issue.title.isEmpty {
            throw ZXDBDump.Failure("\(issue.id) has no title")
        }
        for issue in file.issues where issue.zip.isEmpty {
            throw ZXDBDump.Failure("\(issue.id) has no file to download")
        }
        // A catalogue where most rows have no size means the metadata lookups
        // silently failed, which is worth refusing rather than shipping.
        let sized = file.issues.filter { ($0.bytes ?? 0) > 0 }.count
        guard sized * 10 >= file.issues.count * 9 else {
            throw ZXDBDump.Failure(
                "only \(sized) of \(file.issues.count) issues have a size — "
                + "the metadata lookups are not working")
        }
    }
}

// MARK: - Item metadata, remembered

/// archive.org item metadata, cached on disk.
///
/// The cache is what makes this build rerunnable. Ten thousand items at a
/// polite pace is a long afternoon once; every run after it is instant, and a
/// group can be rebuilt without asking the archive anything.
struct ItemStore: Sendable {
    let directory: URL
    let transport: Transport
    let allowNetwork: Bool

    /// The same allowance `ArchiveOrgClient` makes, for the same observed
    /// reason: the archive answers a small fraction of requests with a 500 and
    /// the identical URL succeeds a moment later. The first validation run
    /// scored thirteen such answers as missing items before this was handled.
    static let attempts = 3

    init(directory: URL, transport: Transport, allowNetwork: Bool) {
        self.directory = directory
        self.transport = transport
        self.allowNetwork = allowNetwork
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    /// Nil means the archive has no such item — a real answer, and cached as
    /// one so a rebuild does not ask again.
    ///
    /// What is cached is the archive's own response, byte for byte, decoded on
    /// the way out by the same `ArchiveOrgItem.decode` the app uses. Caching a
    /// reshaped copy instead would mean the build reads back something no
    /// server ever sent, and the decoder the app depends on would go untested
    /// by every rebuild after the first.
    func item(_ identifier: String) async throws -> ArchiveOrgItem? {
        let file = directory.appendingPathComponent(Self.filename(identifier))
        if let data = try? Data(contentsOf: file) {
            return try? ArchiveOrgItem.decode(data)
        }
        guard allowNetwork else { return nil }

        var body = await fetch(identifier)
        // Identifiers are case-sensitive: `pixel-junior-1-October-1987` is
        // empty where the lowercase spelling is a real item. ZXDB's `{M}`
        // token capitalises a month name, which is right for the filename half
        // of a mask and wrong for the identifier half, so a miss is worth one
        // more try before it is believed.
        if Self.isEmpty(body), identifier.lowercased() != identifier {
            body = await fetch(identifier.lowercased())
        }

        let data = body ?? Data("{}".utf8)
        try? data.write(to: file, options: .atomic)
        return try? ArchiveOrgItem.decode(data)
    }

    /// One metadata document, retrying only what is worth retrying.
    private func fetch(_ identifier: String) async -> Data? {
        guard let url = URL(string: ArchiveOrg.metadataURL(item: identifier)) else {
            return nil
        }
        let request = HTTPRequest(url: url, maxBodyBytes: 8 << 20)
        for round in 1...Self.attempts {
            if round > 1 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard let response = try? await transport.send(request) else { continue }
            try? await Task.sleep(nanoseconds: 200_000_000)
            if response.status == 200 { return response.body }
            // A 4xx is the archive's final word; only a 5xx is worth asking
            // again.
            if response.status < 500 { return nil }
        }
        return nil
    }

    /// archive.org answers "no such item" with `{}` and HTTP 200.
    static func isEmpty(_ body: Data?) -> Bool {
        guard let body else { return true }
        let text = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "{}"
    }

    /// Fill the cache for many items before the catalogue is assembled.
    ///
    /// Sequentially this ran at about fifteen items a minute — two and a half
    /// hours for the English group alone and most of a day for all five, which
    /// is slow enough to make the tool one nobody would rerun. The cost is
    /// almost entirely latency rather than bytes, so a handful of requests in
    /// flight fixes it without asking archive.org for anything more than it
    /// was already being asked for.
    ///
    /// Five, not fifty. This is a public read API being asked six thousand
    /// small questions by one person building an index once; the polite pace
    /// costs twenty minutes and nothing afterwards, because everything here is
    /// cached. Assembly stays sequential and reads only from the cache, so the
    /// catalogue it writes does not depend on what order the answers arrived.
    func warm(_ identifiers: [String], width: Int,
              progress: @Sendable @escaping (Int, Int) -> Void) async {
        let total = identifiers.count
        var done = 0
        var next = 0

        await withTaskGroup(of: Void.self) { group in
            while next < min(width, total) {
                let identifier = identifiers[next]
                next += 1
                group.addTask { _ = try? await self.item(identifier) }
            }
            while await group.next() != nil {
                done += 1
                progress(done, total)
                if next < total {
                    let identifier = identifiers[next]
                    next += 1
                    group.addTask { _ = try? await self.item(identifier) }
                }
            }
        }
    }

    /// A filename an identifier cannot break.
    static func filename(_ identifier: String) -> String {
        let safe = identifier.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(safe).prefix(120) + ".json"
    }
}
