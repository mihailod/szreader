import Foundation
import SZKit

/// The ZXDB dump, read straight from the file the project publishes.
///
/// ZXDB ships as one `ZXDB_mysql.sql.zip` — a HeidiSQL dump of a MariaDB
/// database, 27 MB zipped and 142 MB out. There is a `ZXDB_to_SQLite.py`
/// beside it in the repo, and the tempting shape is to run that and open the
/// result with `SQLite.swift`. This reads the dump directly instead, for the
/// reason the other build tools are Swift and not shell: a step that needs
/// Python and a MySQL client on the machine is a step that rots between
/// rebuilds, and this tool is run by hand a few times a year. One `swift run`
/// with no other dependency is worth a few hundred lines of parser.
///
/// The dump is not SQL that needs executing. It is `CREATE TABLE` statements
/// followed by multi-row `INSERT`s, and everything this build wants is in the
/// `INSERT`s.
struct ZXDBDump {

    /// Where the dump comes from. Pinned to `master` rather than a release
    /// tag because ZXDB has no releases — the zip in the repo root *is* the
    /// distribution, rewritten in place every couple of weeks.
    static let source =
        "https://raw.githubusercontent.com/zxdb/ZXDB/master/ZXDB_mysql.sql.zip"

    private var tables: [String: [Row]]

    /// One row, addressed by column name.
    ///
    /// By name rather than by position on purpose. ZXDB gains columns between
    /// versions — `issues` alone carries eighteen — and a positional read of a
    /// dump that grew a column in the middle does not fail, it silently
    /// returns the neighbouring value for every row. Names cost a dictionary
    /// per table and remove the entire class of mistake.
    struct Row {
        let index: [String: Int]
        let values: [String?]

        subscript(column: String) -> String? {
            guard let at = index[column], at < values.count else { return nil }
            return values[at]
        }

        func int(_ column: String) -> Int? { self[column].flatMap(Int.init) }
    }

    subscript(table: String) -> [Row] { tables[table] ?? [] }

    // MARK: - Loading

    /// The dump, from the cache if it is there and from GitHub if it is not.
    ///
    /// Cached as the zip rather than the unpacked SQL: 27 MB in the cache
    /// directory instead of 142, and unpacking costs a second or two against
    /// a parse that costs rather more. As with `.retrospec-cache`, age never
    /// invalidates it — deleting `.zxdb-cache/` is how a newer dump is asked
    /// for, so a rebuild is reproducible until you say otherwise.
    static func load(cache: URL, allowNetwork: Bool, tables wanted: Set<String>)
        async throws -> ZXDBDump
    {
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let zip = cache.appendingPathComponent("ZXDB_mysql.sql.zip")

        if !FileManager.default.fileExists(atPath: zip.path) {
            guard allowNetwork else {
                throw Failure("no dump in \(cache.lastPathComponent) and --no-network was given")
            }
            guard let remote = URL(string: source) else { throw Failure("bad source URL") }
            print("fetching \(source)")
            let (data, response) = try await URLSession.shared.data(from: remote)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure("dump fetch returned "
                              + "\((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            try data.write(to: zip, options: .atomic)
            print("  \(data.count / 1_048_576) MB cached\n")
        }

        // The app's own zip reader, so the one thing this tool decompresses is
        // decompressed by the code the reader is tested against.
        let reader = try ZipReader(url: zip)
        guard let name = try reader.entries().first(where: { $0.hasSuffix(".sql") }) else {
            throw Failure("no .sql inside \(zip.lastPathComponent)")
        }
        let sql = try reader.data(for: name)
        print("parsing \(name) — \(sql.count / 1_048_576) MB")

        let parsed = parse(sql, wanted: wanted)
        for table in wanted.sorted() {
            print("  \(table.padded(to: 12)) \(parsed[table]?.count ?? 0) rows")
        }
        print("")
        return ZXDBDump(tables: parsed)
    }

    // MARK: - Parsing

    /// Every wanted table's rows, in one pass over the dump.
    ///
    /// One pass rather than one per table because the file is 142 MB and this
    /// build wants five of its seventy-odd tables. Bytes rather than `String`
    /// throughout: Swift's string indices are not random-access, and walking
    /// 142 MB of them character by character turns a two-second parse into a
    /// coffee break.
    private static func parse(_ data: Data, wanted: Set<String>) -> [String: [Row]] {
        let bytes = [UInt8](data)
        var out: [String: [Row]] = [:]
        var indexes: [String: [String: Int]] = [:]

        let marker = [UInt8]("INSERT INTO `".utf8)
        var i = 0

        while i < bytes.count {
            guard let start = find(marker, in: bytes, from: i) else { break }
            var p = start + marker.count

            // Table name, up to the closing backtick.
            let nameStart = p
            while p < bytes.count, bytes[p] != UInt8(ascii: "`") { p += 1 }
            let table = String(decoding: bytes[nameStart..<p], as: UTF8.self)
            p += 1

            guard wanted.contains(table) else {
                // Not wanted: step past the marker and let the scan find the
                // next statement. Skipping to the terminating `;` would be
                // faster, but finding it means honouring quoting inside a
                // statement we have already decided not to read.
                i = start + marker.count
                continue
            }

            // Column list: `(\`a\`, \`b\`, ...) VALUES`
            if indexes[table] == nil {
                var columns: [String] = []
                var q = p
                while q < bytes.count, bytes[q] != UInt8(ascii: ")") {
                    if bytes[q] == UInt8(ascii: "`") {
                        let from = q + 1
                        q += 1
                        while q < bytes.count, bytes[q] != UInt8(ascii: "`") { q += 1 }
                        columns.append(String(decoding: bytes[from..<q], as: UTF8.self))
                    }
                    q += 1
                }
                indexes[table] = Dictionary(uniqueKeysWithValues:
                    columns.enumerated().map { ($0.element, $0.offset) })
            }
            let index = indexes[table] ?? [:]

            // Move to the first tuple after VALUES.
            while p < bytes.count, bytes[p] != UInt8(ascii: "(") { p += 1 }
            // Past the column list.
            while p < bytes.count, bytes[p] != UInt8(ascii: ")") { p += 1 }
            p += 1

            // Tuples, until the statement's `;`.
            var rows: [Row] = []
            while p < bytes.count {
                while p < bytes.count,
                      bytes[p] != UInt8(ascii: "("),
                      bytes[p] != UInt8(ascii: ";") { p += 1 }
                guard p < bytes.count, bytes[p] == UInt8(ascii: "(") else { break }
                p += 1
                let (values, next) = tuple(bytes, from: p)
                rows.append(Row(index: index, values: values))
                p = next
            }
            out[table, default: []] += rows
            i = p
        }
        return out
    }

    /// One `(...)` of values, and where the scan should carry on.
    private static func tuple(_ bytes: [UInt8], from start: Int) -> ([String?], Int) {
        var values: [String?] = []
        var scratch: [UInt8] = []
        var quoted = false
        var sawQuote = false
        var i = start

        while i < bytes.count {
            let c = bytes[i]
            if quoted {
                // HeidiSQL writes backslash escapes; doubled quotes turn up
                // too, so both are honoured rather than guessed between.
                if c == UInt8(ascii: "\\"), i + 1 < bytes.count {
                    scratch.append(unescape(bytes[i + 1]))
                    i += 2
                    continue
                }
                if c == UInt8(ascii: "'") {
                    if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "'") {
                        scratch.append(c)
                        i += 2
                        continue
                    }
                    quoted = false
                    i += 1
                    continue
                }
                scratch.append(c)
                i += 1
                continue
            }
            switch c {
            case UInt8(ascii: "'"):
                quoted = true
                sawQuote = true
                i += 1
            case UInt8(ascii: ","), UInt8(ascii: ")"):
                values.append(finish(scratch, quoted: sawQuote))
                scratch.removeAll(keepingCapacity: true)
                sawQuote = false
                i += 1
                if c == UInt8(ascii: ")") { return (values, i) }
            default:
                scratch.append(c)
                i += 1
            }
        }
        return (values, i)
    }

    /// A finished value: `NULL` only when the dump wrote it unquoted, so a
    /// magazine actually called "NULL" would survive.
    private static func finish(_ scratch: [UInt8], quoted: Bool) -> String? {
        let text = String(decoding: scratch, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !quoted && text == "NULL" { return nil }
        return text
    }

    private static func unescape(_ c: UInt8) -> UInt8 {
        switch c {
        case UInt8(ascii: "n"): return 0x0A
        case UInt8(ascii: "r"): return 0x0D
        case UInt8(ascii: "t"): return 0x09
        case UInt8(ascii: "0"): return 0x00
        default: return c
        }
    }

    /// Plain byte search. `Data.range(of:)` would do, but the parse already
    /// holds `[UInt8]` and converting back and forth per statement is the
    /// slowest thing this file could do.
    private static func find(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        guard from <= last else { return nil }
        var i = from
        while i <= last {
            if haystack[i] == needle[0] {
                var k = 1
                while k < needle.count, haystack[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
            }
            i += 1
        }
        return nil
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
