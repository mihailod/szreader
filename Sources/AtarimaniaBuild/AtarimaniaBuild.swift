import Foundation
import SZKit
import BuildSupport

/// Builds the shipped Atarimania catalogue.
///
///     swift run atarimania-build                # fetch what is missing, rebuild
///     swift run atarimania-build --no-network   # rebuild from the cache alone
///
/// RetroSpec's shape, and deliberately the same kind of tool: it parses with
/// `Atarimania`, the type the tests cover, so the shipped file cannot drift
/// from the parser that was verified.
///
/// Two passes over the site. The first reads 86 pages — the index and one per
/// title — and is the whole of the catalogue except for one number. The second
/// asks each of the ~1,900 PDFs how large it is, because the listings state no
/// size and the app refuses a download that will not fit *before* it starts.
/// Everything is cached under `.atarimania-cache/`, so a second run costs
/// nothing.
@main
struct AtarimaniaBuild {

    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let allowNetwork = !arguments.contains("--no-network")

        let root = URL(fileURLWithPath: #filePath)   // .../Sources/AtarimaniaBuild/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let output = value(of: "--output", in: arguments).map { URL(fileURLWithPath: $0) }
            ?? root.appendingPathComponent("Sources/SZKit/Resources/atarimania-catalog.json")
        let fetcher = Fetcher(directory: root.appendingPathComponent(".atarimania-cache"),
                              allowNetwork: allowNetwork)

        // 1. The index, which names every title.
        let indexHTML = try await fetcher.page(at: Atarimania.base + Atarimania.indexPath,
                                               key: "index.html")
        let ids = Atarimania.magazineIDs(in: indexHTML)
        guard !ids.isEmpty else { throw Failure("the index named no titles") }
        print("index: \(ids.count) titles\n")

        // 2. Each title's own page, which is where the issues are.
        var series: [ShippedCatalog.Series] = []
        var issues: [ShippedCatalog.Issue] = []
        var empty: [String] = []
        // Every PDF already spoken for. Two of the site's pages list one of
        // their own scans twice — Teaching and Computers 1983-09 and a
        // Portfolio Connection issue — which would otherwise be two shelf rows
        // for one file. First occurrence wins.
        var claimed: Set<String> = []
        var duplicates = 0

        for id in ids {
            let html = try await fetcher.page(at: "\(Atarimania.base)magazines/\(id)",
                                              key: "magazines/\(id).html")
            guard let name = Atarimania.name(in: html) else {
                print("  ! \(id): no title on the page")
                continue
            }
            let found = Atarimania.issues(in: html)
            guard !found.isEmpty else {
                empty.append(name)
                continue
            }
            let key = Self.key(id: id, name: name)
            series.append(.init(key: key, name: name, code: String(id), language: "en"))

            // Chronological, so `number` counts a real run. Undated issues
            // keep the order the page listed them in, after the dated ones.
            let ordered = found.enumerated().sorted { a, b in
                (a.element.year ?? .max, a.element.month ?? 0, a.offset)
                    < (b.element.year ?? .max, b.element.month ?? 0, b.offset)
            }
            var rank = 0
            for pair in ordered {
                let entry = pair.element
                guard claimed.insert(entry.pdf).inserted else {
                    duplicates += 1
                    continue
                }
                rank += 1
                issues.append(ShippedCatalog.Issue(
                    id: entry.stem,
                    series: key,
                    number: rank,
                    title: entry.label.isEmpty ? entry.stem : entry.label,
                    year: entry.year, month: entry.month,
                    zip: entry.pdf,
                    cover: entry.cover,
                    thumb: entry.cover,
                    bytes: nil,
                    // The site states no page count anywhere, and the only way
                    // to learn one is to download the PDF. The shelf reads
                    // perfectly without it.
                    pages: nil,
                    dead: nil))
            }
            print("  \(name.padded(to: 40)) \(found.count) issues")
        }
        print("\ntitles with issues: \(series.count), empty: \(empty.count), "
              + "issues: \(issues.count), duplicate links skipped: \(duplicates)\n")

        // 3. Sizes. The one thing the pages do not state.
        if allowNetwork {
            let paths = issues.map(\.zip)
            print("asking \(paths.count) PDFs their size")
            await fetcher.probeAll(paths.map { Atarimania.base + $0 }, width: 5)
            print("")
        }
        var sized = 0
        issues = issues.map { issue in
            guard let probe = fetcher.recordedProbe(Atarimania.base + issue.zip) else {
                return issue
            }
            if probe.bytes != nil { sized += 1 }
            return ShippedCatalog.Issue(
                id: issue.id, series: issue.series, number: issue.number,
                title: issue.title, year: issue.year, month: issue.month,
                zip: issue.zip, cover: issue.cover, thumb: issue.thumb,
                bytes: probe.bytes, pages: nil,
                dead: probe.status == 200 ? nil : true)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let file = ShippedCatalog(
            version: ShippedCatalog.currentVersion,
            generated: formatter.string(from: Date()),
            base: Atarimania.base,
            series: series.sorted { $0.key < $1.key },
            issues: issues)
        try validate(file, sized: sized)

        let data = try ShippedCatalog.encoder().encode(file)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        let dead = file.issues.filter { $0.dead == true }.count
        print("wrote \(output.path) — \(file.issues.count) issues, "
              + "\(file.series.count) titles, \(dead) dead, \(data.count / 1024) KB")
    }

    /// A stable series key. The site's id is what makes it unique — two
    /// titles are both called "Atari User", one of them Spanish.
    static func key(id: Int, name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, c in
                if c == "-" && (out.isEmpty || out.hasSuffix("-")) { return }
                out.append(c)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "atarimania-\(id)" : "\(slug)-\(id)"
    }

    static func validate(_ file: ShippedCatalog, sized: Int) throws {
        guard file.issues.count > 1_500 else {
            throw Failure("only \(file.issues.count) issues — the site lists ~1,900, "
                          + "so the parse or the index is broken")
        }
        let ids = Set(file.issues.map(\.id))
        guard ids.count == file.issues.count else {
            // Every PDF lives in one flat directory, so filenames are unique
            // by construction. A collision means the parse invented one.
            throw Failure("duplicate issue id — \(file.issues.count - ids.count) collisions")
        }
        let keys = Set(file.series.map(\.key))
        for issue in file.issues where !keys.contains(issue.series) {
            throw Failure("\(issue.id) belongs to unknown series \(issue.series)")
        }
        for issue in file.issues where issue.title.isEmpty || issue.zip.isEmpty {
            throw Failure("\(issue.id) has no title or no file")
        }
        for series in file.series {
            let numbers = file.issues.filter { $0.series == series.key }.map(\.number).sorted()
            guard numbers.isEmpty || numbers == Array(1...numbers.count) else {
                throw Failure("\(series.key) is not numbered 1...\(numbers.count)")
            }
        }
        let dead = file.issues.filter { $0.dead == true }.count
        guard dead * 20 <= file.issues.count else {
            throw Failure("\(dead) of \(file.issues.count) PDFs are missing — "
                          + "the site is broken, not the catalogue")
        }
        guard sized * 10 >= file.issues.count * 9 else {
            throw Failure("only \(sized) of \(file.issues.count) issues have a size")
        }
    }

    static func value(of flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
