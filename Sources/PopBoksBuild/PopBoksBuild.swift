import BuildSupport
import Foundation
import SZKit

/// Builds the two shipped PopBoks catalogues.
///
///     swift run popboks-build                      # both magazines
///     swift run popboks-build --magazine ritam     # one of them
///     swift run popboks-build --no-network         # rebuild from the cache
///
/// Deliberately a Swift tool rather than a script: it reads the archive with
/// `PopBoksIndex`, the same code the tests cover, so the shipped catalogue
/// cannot drift from the parser that was verified.
///
/// **Most of what this does is measure.** The index itself is two files — the
/// scripts that draw each magazine's front page carry the whole thing as
/// literal arrays, so there is no crawl and no HTML. What the scripts do *not*
/// record is the shape of the tile grid a page is cut into, and that is the
/// one thing a download cannot safely guess: see
/// `PopBoksCatalog.Issue.rows`. So every issue's first page is probed, edge
/// outwards, until the archive stops answering.
///
/// Everything is cached under `.popboks-cache/`, so a second run costs nothing
/// and `--no-network` rebuilds from the cache alone. Deleting that directory
/// is how you ask for fresh copies.
@main
struct PopBoksBuild {

    /// How far out to look for the edge of the grid.
    ///
    /// Both are past anything the archive has: every page measured so far is
    /// five columns, and the tallest is eight rows. Bounded rather than open
    /// so that a server answering everything with 200 cannot spin this for
    /// ever — and `validate` refuses a grid that reaches either limit, because
    /// an issue at the ceiling is one whose real edge was never found.
    static let columnLimit = 7
    static let rowLimit = 11

    /// Which rows the column walk runs along, and which columns the row walk
    /// runs down.
    ///
    /// Two of each, and the largest answer wins. One line would be only as
    /// good as the tiles on it, and this archive has holes in exactly those
    /// places — see the comment where these are probed.
    static let measuringLines = [0, 1]

    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let allowNetwork = !arguments.contains("--no-network")
        arguments.removeAll { $0 == "--no-network" }

        let wanted: [PopBoks.Magazine]
        if let named = value(of: "--magazine", in: arguments) {
            guard let one = PopBoks.Magazine(rawValue: named) else {
                throw Failure("unknown magazine \"\(named)\" — "
                            + "expected dzuboks or ritam")
            }
            wanted = [one]
        } else {
            wanted = PopBoks.Magazine.inMenuOrder
        }

        let root = URL(fileURLWithPath: #filePath)   // .../Sources/PopBoksBuild/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fetcher = Fetcher(directory: root.appendingPathComponent(".popboks-cache"),
                              allowNetwork: allowNetwork)

        for magazine in wanted {
            try await build(magazine, fetcher: fetcher, root: root)
        }
    }

    static func build(_ magazine: PopBoks.Magazine,
                      fetcher: Fetcher, root: URL) async throws {
        print("\n=== \(magazine.display) ===")

        // 1. The index, which is the whole of what the archive says exists.
        let script = try await fetcher.page(at: magazine.indexScript,
                                            key: "\(magazine.rawValue).js")
        let entries: [PopBoksIndex.Entry]
        switch magazine {
        case .dzuboks: entries = try PopBoksIndex.dzuboks(script)
        case .ritam:   entries = try PopBoksIndex.ritam(script)
        }
        let pages = entries.reduce(0) { $0 + $1.pages }
        print("index: \(entries.count) issues, \(pages) pages, "
            + "\(entries.map(\.year).min() ?? 0)-\(entries.map(\.year).max() ?? 0)")

        // 2. The tile grid, measured per issue. The scripts do not record it,
        //    and the archive's own reader hard-codes a seven-row loop that is
        //    too short for two of these issues — so the site is not a witness
        //    here either. Only the tiles are.
        var probes: [String] = []
        for entry in entries {
            probes.append(magazine.coverURL(issue: entry.id))
            for page in sampled(entry) {
                // Along two rows and two columns rather than one of each.
                //
                // A single measuring line is only as good as the tiles on it,
                // and this archive has holes *in* those lines. Walking row 0
                // alone read Džuboks 88's page 35 — which is missing the tile
                // at 4,0 — as four columns wide; walking column 0 alone read
                // Džuboks 34 and 60 as three and four rows tall, when both are
                // ordinary seven-row pages missing one tile. Every one of
                // those measurements would have shipped a catalogue that
                // cropped real pages.
                for line in measuringLines {
                    for column in 0...columnLimit {
                        probes.append(magazine.tileURL(issue: entry.id, page: page,
                                                       column: column, row: line))
                    }
                    for row in 0...rowLimit {
                        probes.append(magazine.tileURL(issue: entry.id, page: page,
                                                       column: line, row: row))
                    }
                }
            }
        }
        print("measuring \(entries.count) issues (\(probes.count) probes)\u{2026}")
        await fetcher.probeAll(probes, width: 5)

        // 3. Assemble.
        var issues: [PopBoksCatalog.Issue] = []
        var withoutCover: [Int] = []
        for entry in entries {
            func alive(_ url: String) -> Bool {
                fetcher.recordedProbe(url)?.status == 200
            }
            // Measured on several pages and the largest kept. The grid belongs
            // to the page rather than to the issue, and nothing promises every
            // page of an issue was scanned alike — so one page's answer is not
            // the issue's, and the largest is the only one that is safe to
            // record: too small crops, too large merely costs a request.
            var columns = 0, rows = 0
            var perPage: [String] = []
            for page in sampled(entry) {
                var wide = 0, tall = 0
                for line in measuringLines {
                    var w = 0
                    while w <= columnLimit,
                          alive(magazine.tileURL(issue: entry.id, page: page,
                                                 column: w, row: line)) { w += 1 }
                    var t = 0
                    while t <= rowLimit,
                          alive(magazine.tileURL(issue: entry.id, page: page,
                                                 column: line, row: t)) { t += 1 }
                    wide = max(wide, w)
                    tall = max(tall, t)
                }
                columns = max(columns, wide)
                rows = max(rows, tall)
                perPage.append("p\(page) \(wide)x\(tall)")
            }
            // Said out loud: an issue whose pages are not all one shape is
            // the case this sampling exists for, and it is worth seeing.
            if Set(perPage.map { $0.split(separator: " ")[1] }).count > 1 {
                print("  mixed \(entry.title): " + perPage.joined(separator: ", ")
                    + " -> recording \(columns)x\(rows)")
            }

            if !alive(magazine.coverURL(issue: entry.id)) { withoutCover.append(entry.id) }

            issues.append(PopBoksCatalog.Issue(
                id: entry.id, number: entry.number, label: entry.label,
                title: entry.title, year: entry.year, month: entry.month,
                firstPage: entry.firstPage, pages: entry.pages,
                columns: columns, rows: rows))
        }

        let shapes = Dictionary(grouping: issues) { "\($0.columns)x\($0.rows)" }
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
        print("grids: " + shapes.map { "\($0.key) x\($0.value)" }.joined(separator: ", "))
        // Worth saying out loud rather than only asserting: these are the
        // issues the archive's own reader crops.
        let tall = issues.filter { $0.rows > 7 }
        if !tall.isEmpty {
            print("taller than the site's own viewer draws: "
                + tall.map { "\($0.title) (\($0.rows) rows)" }.joined(separator: ", "))
        }
        if !withoutCover.isEmpty { print("! no cover: \(withoutCover)") }

        let file = PopBoksCatalog(
            version: PopBoksCatalog.currentVersion,
            generated: today(),
            base: PopBoks.base,
            magazine: magazine.rawValue,
            issues: issues.sorted { $0.number < $1.number })

        try validate(file, magazine: magazine, withoutCover: withoutCover)

        let output = root.appendingPathComponent(
            "Sources/SZKit/Resources/\(magazine.resource).json")
        let data = try PopBoksCatalog.encoder().encode(file)
        try data.write(to: output, options: .atomic)
        let tiles = file.issues.reduce(0) { $0 + $1.pages * $1.tilesPerPage }
        print("wrote \(output.lastPathComponent) — \(file.issues.count) issues, "
            + "\(file.issues.reduce(0) { $0 + $1.pages }) pages, "
            + "\(tiles) tiles, \(data.count / 1024) KB")
    }

    // MARK: - Checks

    /// Refuses to write a catalogue that fails its own checks.
    ///
    /// Every tool in this repository does this, and here the stakes are a
    /// little different: a wrong page count or a wrong grid does not produce a
    /// visible error, it produces an issue that downloads two thousand tiles
    /// and then refuses to finish, or one whose pages are quietly cropped.
    static func validate(_ file: PopBoksCatalog,
                         magazine: PopBoks.Magazine,
                         withoutCover: [Int]) throws {
        guard !file.issues.isEmpty else { throw Failure("no issues") }
        guard file.kind == magazine else {
            throw Failure("the catalogue names \(file.magazine), not \(magazine.rawValue)")
        }

        let ids = file.issues.map(\.id)
        guard Set(ids).count == ids.count else {
            throw Failure("two issues share an id")
        }
        // The shelf orders on this, so a repeat puts two issues in one place.
        let numbers = file.issues.map(\.number)
        guard Set(numbers).count == numbers.count else {
            throw Failure("two issues share a number")
        }

        for issue in file.issues {
            let name = "\(issue.title) (id \(issue.id))"
            guard issue.pages > 0 else { throw Failure("\(name) has no pages") }
            guard issue.firstPage >= 1 else { throw Failure("\(name) starts before page 1") }
            guard !issue.title.isEmpty, !issue.label.isEmpty else {
                throw Failure("\(name) is unnamed")
            }
            guard (1974...1995).contains(issue.year) else {
                throw Failure("\(name) is dated \(issue.year)")
            }
            // A grid of zero means every tile probe failed: the issue is
            // listed but its scan is not there, and shipping it would put a
            // row on the shelf that can never open.
            guard issue.columns > 0, issue.rows > 0 else {
                throw Failure("\(name) has no tiles at all")
            }
            // At the ceiling means the edge was never found, so the recorded
            // grid is a floor rather than the truth — and a page stitched to a
            // floor is a page with its edge cut off.
            guard issue.columns <= columnLimit, issue.rows <= rowLimit else {
                throw Failure("\(name) reached the probe limit at "
                            + "\(issue.columns)x\(issue.rows) — raise it and rebuild")
            }
        }

        // Every issue here has artwork, and a row without it is a grey
        // rectangle on the shelf for ever. Fatal rather than a warning: the
        // archive has a thumbnail for every issue it scanned, so one missing
        // means something was measured wrong.
        guard withoutCover.isEmpty else {
            throw Failure("no cover for \(withoutCover)")
        }

        // What the archive held when this was written. A rebuild that finds
        // materially less has almost certainly been served an error page
        // rather than the index, which is exactly the failure that would
        // otherwise ship as a catalogue with half a magazine in it.
        let expected = magazine == .dzuboks ? 183 : 25
        guard file.issues.count >= expected else {
            throw Failure("only \(file.issues.count) issues, expected \(expected) "
                        + "— refusing to ship a short catalogue")
        }
        if file.issues.count > expected {
            print("note: \(file.issues.count) issues, up from \(expected) "
                + "— the archive has grown, update the expectation")
        }
    }

    /// Which pages of an issue to measure.
    ///
    /// The first, the middle and the last. Three rather than one because a
    /// single page can be unrepresentative — page one especially, being the
    /// cover — and three rather than all because measuring every page of both
    /// magazines is 13,626 pages and several hours of probing to catch a case
    /// the download already handles safely: it shrinks a page that comes up
    /// short and refuses loudly if one is taller than recorded.
    ///
    /// What this has to get right is the *maximum*, and no issue has yet had
    /// its tallest page anywhere but its first, middle or last.
    static func sampled(_ entry: PopBoksIndex.Entry) -> [Int] {
        let first = entry.firstPage
        let last = entry.firstPage + entry.pages - 1
        return Array(Set([first, first + entry.pages / 2, last])).sorted()
    }

    // MARK: - Odds and ends

    static func today() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
