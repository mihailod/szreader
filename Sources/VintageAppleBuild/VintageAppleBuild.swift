import Foundation
import SZKit
import BuildSupport

/// Builds the two shipped Vintage Apple catalogues.
///
///     swift run vintageapple-build                    # both shelves
///     swift run vintageapple-build --group books      # one of them
///     swift run vintageapple-build --no-network       # from the cache alone
///
/// Atarimania's shape, and the same kind of tool: it parses with
/// `VintageApple`, the type the tests cover, so the shipped files cannot drift
/// from the parser that was verified.
///
/// Two passes. The first reads seventeen section pages and is the whole of both
/// catalogues except for one number; the second asks each of the ~1,950 PDFs
/// how large it is, because the tables state no size and the app refuses a
/// download that will not fit before it starts. Everything is cached under
/// `.vintageapple-cache/`.
@main
struct VintageAppleBuild {

    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let allowNetwork = !arguments.contains("--no-network")

        let root = URL(fileURLWithPath: #filePath)   // .../Sources/VintageAppleBuild/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fetcher = Fetcher(directory: root.appendingPathComponent(".vintageapple-cache"),
                              allowNetwork: allowNetwork)

        let only = value(of: "--group", in: arguments).flatMap(VintageApple.Group.init(rawValue:))
        let groups = only.map { [$0] } ?? VintageApple.Group.inMenuOrder

        // 1. Every section's table. Read once even when only one shelf is
        //    being written — they are seventeen cached pages.
        var rows: [VintageApple.Group: [(VintageApple.Section, [VintageApple.Entry])]] = [:]
        for section in VintageApple.sections {
            let html = try await fetcher.page(at: VintageApple.base + section.path,
                                              key: "\(section.slug).html")
            let found = VintageApple.entries(in: html)
            guard !found.isEmpty else {
                print("  ! \(section.name): no rows — the page or the parse changed")
                continue
            }
            rows[section.group, default: []].append((section, found))
            print("  \(section.name.padded(to: 34)) \(found.count) files")
        }
        print("")

        // 2. Sizes, for the shelves being written.
        if allowNetwork {
            var urls: [String] = []
            for group in groups {
                for (section, found) in rows[group] ?? [] {
                    urls += found.map { VintageApple.base + section.slug + "/" + $0.pdf }
                }
            }
            print("asking \(urls.count) PDFs their size")
            await fetcher.probeAll(urls, width: 5)
            print("")
        }

        for group in groups {
            let output = root.appendingPathComponent(
                "Sources/SZKit/Resources/\(group.resource).json")
            try write(group: group, sections: rows[group] ?? [],
                      fetcher: fetcher, output: output)
        }
    }

    static func write(group: VintageApple.Group,
                      sections: [(VintageApple.Section, [VintageApple.Entry])],
                      fetcher: Fetcher, output: URL) throws {
        var series: [ShippedCatalog.Series] = []
        var issues: [ShippedCatalog.Issue] = []
        var sized = 0, dead = 0
        // Every file already spoken for. Filenames are unique within a section
        // but the id carries the section, so this catches a page listing one of
        // its own rows twice — which two of Atarimania's do.
        var claimed: Set<String> = []
        var duplicates = 0

        for (section, found) in sections {
            series.append(.init(key: section.slug, name: section.name,
                                code: section.slug, language: "en"))
            // Chronological where there are dates, and the page's own order
            // where there are not — a shelf of undated books stays alphabetical,
            // which is how the site lists them and how they are looked for.
            let ordered = found.enumerated().sorted { a, b in
                (a.element.year ?? .max, a.element.month ?? 0, a.offset)
                    < (b.element.year ?? .max, b.element.month ?? 0, b.offset)
            }
            var rank = 0
            for pair in ordered {
                let entry = pair.element
                let path = section.slug + "/" + entry.pdf
                guard claimed.insert(path).inserted else { duplicates += 1; continue }
                let probe = fetcher.recordedProbe(VintageApple.base + path)
                if probe?.bytes != nil { sized += 1 }
                if let probe, probe.status != 200 { dead += 1 }
                rank += 1
                issues.append(ShippedCatalog.Issue(
                    id: "\(section.slug)/\(entry.stem)",
                    series: section.slug,
                    number: rank,
                    title: entry.title,
                    year: entry.year, month: entry.month,
                    zip: path,
                    cover: entry.thumb.map { section.slug + "/" + $0 },
                    thumb: entry.thumb.map { section.slug + "/" + $0 },
                    bytes: probe?.bytes,
                    // No page count anywhere on the site, and the only way to
                    // learn one is to download the PDF.
                    pages: nil,
                    dead: probe.map { $0.status != 200 } == true ? true : nil))
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let file = ShippedCatalog(
            version: ShippedCatalog.currentVersion,
            generated: formatter.string(from: Date()),
            base: VintageApple.base,
            series: series.sorted { $0.key < $1.key },
            issues: issues)
        try validate(file, group: group, sized: sized)

        let data = try ShippedCatalog.encoder().encode(file)
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .atomic)
        print("\(group.resource): \(file.issues.count) files, \(file.series.count) sections, "
              + "\(dead) dead, \(duplicates) duplicate links skipped, \(data.count / 1024) KB")
    }

    static func validate(_ file: ShippedCatalog, group: VintageApple.Group,
                         sized: Int) throws {
        // Floors rather than exact counts: the site gains a scan now and then,
        // and a catalogue that shrank by half is the failure worth refusing.
        let floor = group == .magazines ? 900 : 700
        guard file.issues.count >= floor else {
            throw Failure("\(group.resource): only \(file.issues.count) files, expected "
                          + "at least \(floor) — the parse or a section is broken")
        }
        let ids = Set(file.issues.map(\.id))
        guard ids.count == file.issues.count else {
            throw Failure("\(group.resource): duplicate issue id")
        }
        let keys = Set(file.series.map(\.key))
        for issue in file.issues where !keys.contains(issue.series) {
            throw Failure("\(issue.id) belongs to unknown section \(issue.series)")
        }
        for issue in file.issues where issue.title.isEmpty || issue.zip.isEmpty {
            throw Failure("\(issue.id) has no title or no file")
        }
        for section in file.series {
            let numbers = file.issues.filter { $0.series == section.key }
                .map(\.number).sorted()
            guard numbers.isEmpty || numbers == Array(1...numbers.count) else {
                throw Failure("\(section.key) is not numbered 1...\(numbers.count)")
            }
        }
        let live = file.issues.filter { $0.dead != true }.count
        guard sized * 10 >= live * 9 else {
            throw Failure("\(group.resource): only \(sized) of \(live) files have a size")
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

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
