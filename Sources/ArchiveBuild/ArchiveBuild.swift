import Foundation
import SZKit

/// Builds the shipped archive.org catalogue.
///
///     swift run archive-build
///
/// Nine requests for the four issues shipped today, run by hand when the list
/// in `ArchiveOrgLibrary` changes. Adding an issue is a line in that table and
/// another run of this; nothing about the app has to change.
///
/// Like `retrospec-build`, this is a Swift tool rather than a script so that
/// the shipped file is assembled by the same types the app reads it back with,
/// and the URL forms come from `ArchiveOrg` rather than from string
/// concatenation that only looks the same.
///
/// No cache. RetroSpec's build fetches ~1300 pages off one small Apache and
/// caches every one of them; this asks a CDN for a handful of small JSON
/// documents, so a cache would be a stale copy to explain rather than time
/// saved.
@main
struct ArchiveBuild {

    static func main() async throws {
        let root = URL(fileURLWithPath: #filePath)   // .../Sources/ArchiveBuild/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let output = value(of: "--output", in: Array(CommandLine.arguments.dropFirst()))
            .map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Sources/SZKit/Resources/archive-catalog.json")

        var issues: [ShippedCatalog.Issue] = []

        for series in ArchiveOrgLibrary.series {
            print("\(series.name) — \(series.items.count) issues")
            for (rank, identifier) in series.items.enumerated() {
                let item = try await metadata(of: identifier)
                let built = try await issue(item, series: series, number: rank + 1)
                issues.append(built)
                print("  \(identifier.padded(to: 44)) \(built.title.padded(to: 16)) "
                      + "\(built.pages ?? 0) pages, \((built.bytes ?? 0) / 1024) KB")
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let file = ShippedCatalog(
            version: ShippedCatalog.currentVersion,
            generated: formatter.string(from: Date()),
            base: ArchiveOrg.base,
            series: ArchiveOrgLibrary.series.map {
                .init(key: $0.key, name: $0.name, code: $0.code,
                      language: $0.language.rawValue)
            },
            issues: issues)
        try validate(file)

        let data = try ShippedCatalog.encoder().encode(file)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        print("\nwrote \(output.path) — \(file.issues.count) issues")
    }

    // MARK: - One issue

    /// Everything the catalogue records about one item.
    ///
    /// The scan's size comes out of the metadata rather than from a HEAD on
    /// the file, because the archive states it — this is the one place a
    /// request is saved by asking the right question first.
    static func issue(_ item: ArchiveOrgItem, series: ArchiveOrgSeries,
                      number: Int) async throws -> ShippedCatalog.Issue {
        guard let scan = item.scan else {
            throw Failure("\(item.identifier) has no \"Image Container PDF\" — "
                          + "check what the item actually holds before shipping it")
        }
        guard let title = ArchiveOrgLibrary.title(year: item.year, month: item.month,
                                                  language: series.language) else {
            throw Failure("\(item.identifier) is undated, so there is nothing to "
                          + "call it on the shelf")
        }
        return ShippedCatalog.Issue(
            id: item.identifier,
            series: series.key,
            number: number,
            title: title,
            year: item.year, month: item.month,
            zip: ArchiveOrg.path(item: item.identifier, file: scan.name),
            cover: ArchiveOrg.firstPagePath(item: item.identifier),
            thumb: ArchiveOrg.thumbnailPath(item: item.identifier),
            bytes: scan.bytes,
            pages: try await pageCount(of: item),
            dead: nil)
    }

    // MARK: - Fetching

    static func metadata(of identifier: String) async throws -> ArchiveOrgItem {
        let data = try await get(ArchiveOrg.metadataURL(item: identifier))
        guard let item = try ArchiveOrgItem.decode(data) else {
            throw Failure("no such item on archive.org: \(identifier)")
        }
        return item
    }

    /// How many pages the scan has.
    ///
    /// The metadata states no page count, so this reads the scanner's record
    /// of the book. Recorded because the shelf shows it and the reader shows
    /// "page 4 of 20" before a single page has been opened.
    static func pageCount(of item: ArchiveOrgItem) async throws -> Int {
        guard let file = item.scandata else {
            throw Failure("\(item.identifier) has no scandata to count pages from")
        }
        let data = try await get(ArchiveOrg.base
            + ArchiveOrg.path(item: item.identifier, file: file.name))
        guard let xml = String(data: data, encoding: .utf8),
              let pages = ArchiveOrg.pageCount(inScandata: xml) else {
            throw Failure("\(item.identifier)'s scandata states no page count")
        }
        return pages
    }

    /// One GET, retried through the archive's occasional 500.
    ///
    /// Not defensive programming for its own sake: the item servers behind
    /// `/download/` answered 500 to two of these nine requests while this was
    /// being written, and the same URLs served fine a second later. A build
    /// that dies on that is a build re-run by hand for no reason, so each
    /// request gets a second and third chance, spaced out — and a failure that
    /// survives three attempts is a real one worth stopping for.
    static func get(_ url: String, attempts: Int = 3) async throws -> Data {
        guard let remote = URL(string: url) else { throw Failure("bad URL: \(url)") }
        var request = URLRequest(url: remote)
        // Says what is asking. A build tool run by hand a few times a year has
        // no reason to look like anything else.
        request.setValue("streamzine-archive-build", forHTTPHeaderField: "User-Agent")

        var last = "no attempt was made"
        for attempt in 1...max(attempts, 1) {
            if attempt > 1 { try await Task.sleep(nanoseconds: 2_000_000_000) }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 200 { return data }
            last = "\(url) returned \(status)"
            print("  ! \(last) — attempt \(attempt) of \(attempts)")
        }
        throw Failure(last)
    }

    // MARK: - Validation

    /// Refuses to write a catalogue that is obviously wrong.
    ///
    /// The same reasoning as `retrospec-build`'s: a build tool that silently
    /// emits a half-built file does its damage much later, as issues missing
    /// from a shelf nobody is counting.
    static func validate(_ file: ShippedCatalog) throws {
        guard file.issues.count == ArchiveOrgLibrary.items.count else {
            throw Failure("expected \(ArchiveOrgLibrary.items.count) issues, "
                          + "built \(file.issues.count)")
        }
        guard Set(file.issues.map(\.id)).count == file.issues.count else {
            throw Failure("the same item is listed twice")
        }
        for issue in file.issues {
            guard issue.bytes ?? 0 > 0 else { throw Failure("\(issue.id) has no size") }
            guard issue.pages ?? 0 > 0 else { throw Failure("\(issue.id) has no pages") }
        }
        // Every run numbers from one with no gaps, which is what the shelf's
        // sort and the "issue 2 of 2" reading both rest on.
        for series in file.series {
            let numbers = file.issues.filter { $0.series == series.key }.map(\.number).sorted()
            guard !numbers.isEmpty else { throw Failure("\(series.key) has no issues") }
            guard numbers == Array(1...numbers.count) else {
                throw Failure("\(series.key) is not numbered 1...\(numbers.count)")
            }
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
