import Foundation
import SZKit

/// Builds the shipped RetroSpec catalogue.
///
///     swift run retrospec-build                # fetch what is missing, rebuild
///     swift run retrospec-build --no-network   # rebuild from the cache alone
///
/// Deliberately a Swift tool rather than a script: it parses the site with
/// `RetroSpecCatalog`, the same code the app runs and the tests cover, so the
/// shipped catalogue cannot drift from the parser that was verified. A second
/// implementation in another language would be a second thing to keep right.
///
/// Everything fetched is cached under `.retrospec-cache/`, so a rebuild after
/// the first costs nothing and the site is asked for each page once. The site
/// is a static Apache archive of a defunct magazine scene; one pass of ~1300
/// requests, spread out and cached, is the whole cost of building this.
@main
struct RetroSpecBuild {

    static let indexPages = [
        "indexAS", "indexBIT", "indexCN", "indexGal", "indexKnjige", "indexMG",
        "indexMMHrv", "indexMMSlo", "indexPJ", "indexRA", "indexSK", "indexSpecial",
    ]

    static let magshowBase = "https://retrospec.elite.org/users/tomcat/yu/magshow.php?all="

    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let allowNetwork = !arguments.contains("--no-network")
        arguments.removeAll { $0 == "--no-network" }

        let root = URL(fileURLWithPath: #filePath)   // .../Sources/RetroSpecBuild/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let output = value(of: "--output", in: arguments).map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Sources/SZKit/Resources/retrospec-catalog.json")
        let fetcher = Fetcher(directory: root.appendingPathComponent(".retrospec-cache"),
                              allowNetwork: allowNetwork)

        // 1. The index pages, which say what exists.
        var entries: [RetroSpecEntry] = []
        for name in indexPages {
            let data = try await fetcher.page(
                at: "https://retrospec.elite.org/pcsux/\(name).html", key: "\(name).html")
            guard let html = RetroSpecCatalog.decode(data) else {
                throw Failure("could not decode \(name).html")
            }
            let found = RetroSpecCatalog.entries(in: html)
            print("  \(name.padded(to: 16)) \(found.count) issues")
            entries += found
        }
        print("index: \(entries.count) issues across "
              + "\(Set(entries.map(\.seriesKey)).count) series\n")

        // 2. Each issue's own page, which is the only place the real series
        //    names, the language and the page count exist.
        var info: [String: RetroSpecIssueInfo] = [:]
        for (n, entry) in entries.enumerated() {
            let data = try await fetcher.page(at: magshowBase + entry.id,
                                              key: "magshow/\(entry.id).html")
            guard let html = RetroSpecCatalog.decode(data),
                  let parsed = RetroSpecCatalog.info(in: html) else {
                print("  ! \(entry.id): no metadata")
                continue
            }
            info[entry.id] = parsed
            if (n + 1) % 100 == 0 { print("  metadata \(n + 1)/\(entries.count)") }
        }
        print("metadata: \(info.count)/\(entries.count) issues\n")

        // 3. Ask each archive its size. Recording it now is what lets the app
        //    refuse a download that will not fit *before* it starts, without
        //    spending a request at read time — and it is how the dead ones are
        //    found.
        var sizes: [String: Fetcher.Probe] = [:]
        for (n, entry) in entries.enumerated() {
            sizes[entry.id] = try await fetcher.probe(entry.zipURL, key: entry.id)
            if (n + 1) % 100 == 0 { print("  archives \(n + 1)/\(entries.count)") }
        }
        let dead = entries.filter { sizes[$0.id]?.status != 200 }
        print("archives: \(entries.count - dead.count) live, \(dead.count) missing")
        for entry in dead {
            print("  dead  \(entry.id.padded(to: 14)) \(sizes[entry.id]?.status ?? 0)  \(entry.zipURL)")
        }

        // 4. Assemble.
        let file = catalogue(from: entries, info: info, sizes: sizes)
        try validate(file)

        let data = try RetroSpecCatalogFile.encoder().encode(file)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        print("\nwrote \(output.path) — \(file.issues.count) issues, "
              + "\(data.count / 1024) KB")
    }

    // MARK: - Assembly

    static func catalogue(from entries: [RetroSpecEntry],
                          info: [String: RetroSpecIssueInfo],
                          sizes: [String: Fetcher.Probe]) -> RetroSpecCatalogFile {
        let base = RetroSpecCatalog.base
        var issues: [RetroSpecCatalogFile.Issue] = []

        for series in RetroSpecSeriesTable.all {
            let mine = entries.enumerated().filter { $0.element.seriesKey == series.key }
            // Chronological, then page order. The page's own order is already
            // chronological everywhere except Računari, whose 1988 special is
            // parked at the end of the grid — sorting here files it beside the
            // April 1988 issue it belongs with, and `isSpecial` keeps it just
            // after rather than just before.
            let ordered = mine.sorted { a, b in
                (a.element.year ?? .max, a.element.month ?? 0,
                 a.element.isSpecial ? 1 : 0, a.offset)
                    < (b.element.year ?? .max, b.element.month ?? 0,
                       b.element.isSpecial ? 1 : 0, b.offset)
            }
            for (rank, item) in ordered.enumerated() {
                let entry = item.element
                let probe = sizes[entry.id]
                let alive = probe?.status == 200
                issues.append(RetroSpecCatalogFile.Issue(
                    id: entry.id,
                    series: series.key,
                    number: rank + 1,
                    title: title(for: entry, info: info[entry.id]),
                    year: entry.year, month: entry.month,
                    zip: relative(entry.zipURL, base: base),
                    cover: entry.coverURL.map { relative($0, base: base) },
                    thumb: entry.thumbnailURL.map { relative($0, base: base) },
                    bytes: alive ? probe?.bytes : nil,
                    pages: info[entry.id]?.pageCount,
                    dead: alive ? nil : true))
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return RetroSpecCatalogFile(
            version: RetroSpecCatalogFile.currentVersion,
            generated: formatter.string(from: Date()),
            base: base,
            series: RetroSpecSeriesTable.all.map {
                .init(key: $0.key, name: $0.name, code: $0.code,
                      language: $0.language?.rawValue)
            },
            issues: issues)
    }

    /// What the shelf calls an issue.
    ///
    /// The month comes from the site's database rather than the caption
    /// beside the cover, because three captions are copied from the cell
    /// above them. It is kept in the language it was printed in — a Croatian
    /// magazine says "Prosinac" — since that is what is on the cover the
    /// reader is looking at. A double issue already reads as one
    /// ("Februar/Mart"), so nothing has to be assembled here.
    ///
    /// Books have no date at all; their title is the whole identity, and the
    /// site files it where a magazine's series name goes.
    ///
    /// A book is titled from the index page rather than from `magshow.php`,
    /// even though both carry the same string. The index page is served as
    /// windows-1250 and has the characters; the database behind `magshow`
    /// has lost some of them, so it offers "Spektrum Priru?nik" where the
    /// page says "Spektrum Priručnik". For a month that loss is repairable
    /// from a closed vocabulary of twelve names — for a book title it is not,
    /// so the fix is to read the source that is not broken.
    static func title(for entry: RetroSpecEntry, info: RetroSpecIssueInfo?) -> String {
        guard let info else { return entry.label }
        guard let year = info.year else { return entry.label }
        guard let month = info.monthText, !month.isEmpty else { return String(year) }
        return "\(month) \(year)"
    }

    static func relative(_ url: String, base: String) -> String {
        url.hasPrefix(base) ? String(url.dropFirst(base.count)) : url
    }

    // MARK: - Validation

    /// Refuses to write a catalogue that is obviously wrong.
    ///
    /// A build tool that silently emits a half-parsed file is worse than one
    /// that fails: the damage shows up much later, as issues missing from a
    /// shelf nobody is counting.
    static func validate(_ file: RetroSpecCatalogFile) throws {
        guard file.issues.count == 653 else {
            throw Failure("expected 653 issues, built \(file.issues.count)")
        }
        let ids = Set(file.issues.map(\.id))
        guard ids.count == file.issues.count else { throw Failure("duplicate issue id") }

        let keys = Set(file.series.map(\.key))
        for issue in file.issues where !keys.contains(issue.series) {
            throw Failure("\(issue.id) belongs to unknown series \(issue.series)")
        }
        for issue in file.issues where issue.title.isEmpty {
            throw Failure("\(issue.id) has no title")
        }
        // Every run numbers from one with no gaps, which is what the shelf's
        // sort and the "issue 3 of 145" reading both rest on.
        for series in file.series {
            let numbers = file.issues.filter { $0.series == series.key }.map(\.number).sorted()
            guard numbers.isEmpty || numbers == Array(1...numbers.count) else {
                throw Failure("\(series.key) is not numbered 1...\(numbers.count)")
            }
        }
        let dead = file.issues.filter { $0.dead == true }
        guard dead.count <= 12 else {
            throw Failure("\(dead.count) archives are missing — the site or the "
                          + "parse is broken, not the archive")
        }
    }

    // MARK: - Plumbing

    static func value(of flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
