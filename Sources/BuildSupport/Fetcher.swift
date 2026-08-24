import Foundation

/// Fetches pages and file headers, remembering everything it is told.
///
/// Shared by the build tools that read a static archive of PDFs — Atarimania
/// and Vintage Apple — rather than copied into each. RetroSpec keeps its own,
/// which predates this and reads a different kind of page.
///
/// RetroSpec's fetcher with one difference: the size pass here is a couple of
/// thousand requests rather than 653, and each is a HEAD whose cost is latency
/// alone. Sequentially that is half an hour of waiting for nothing; five at a
/// time makes it a few minutes and asks the site for exactly the same set of
/// things. The page pass stays sequential — a few dozen requests, run once.
public struct Fetcher: Sendable {

    /// What a HEAD on a PDF came back with.
    public struct Probe: Codable, Equatable, Sendable {
        public let status: Int
        public let bytes: Int64?
    }

    public let directory: URL
    public let allowNetwork: Bool

    private var probeFile: URL { directory.appendingPathComponent("pdf-sizes.json") }

    public init(directory: URL, allowNetwork: Bool) {
        self.directory = directory
        self.allowNetwork = allowNetwork
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Pages

    /// A page, from the cache if it is there and from the site if it is not.
    ///
    /// Never invalidated by age. Deleting `.atarimania-cache/` is how you ask
    /// for fresh copies, which keeps a rebuild reproducible until you say
    /// otherwise.
    public func page(at url: String, key: String) async throws -> String {
        let file = directory.appendingPathComponent(key)
        if let cached = try? Data(contentsOf: file) {
            return String(decoding: cached, as: UTF8.self)
        }
        guard allowNetwork else {
            throw Missing("\(key) is not cached and --no-network was given")
        }
        guard let remote = URL(string: url) else { throw Missing("bad URL: \(url)") }

        var request = URLRequest(url: remote)
        // Atarimania is a rendered React app behind a CDN and answers a bare
        // URLSession user agent with a challenge page. Vintage Apple does not
        // care, and sending it costs nothing.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Missing("\(url) returned "
                          + "\((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        try await Task.sleep(nanoseconds: 250_000_000)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Sizes

    /// Every recorded size, keyed by URL. Read once and written once per pass
    /// rather than a file per PDF.
    private func known() -> [String: Probe] {
        (try? Data(contentsOf: probeFile))
            .flatMap { try? JSONDecoder().decode([String: Probe].self, from: $0) } ?? [:]
    }

    public func recordedProbe(_ url: String) -> Probe? { known()[url] }

    /// Ask every URL its size, a few at a time, and write the lot down once.
    public func probeAll(_ urls: [String], width: Int) async {
        var have = known()
        let wanted = urls.filter { have[$0] == nil }
        guard !wanted.isEmpty else {
            print("  all \(urls.count) sizes already recorded")
            return
        }

        let results = await withTaskGroup(of: (String, Probe?).self) { group -> [String: Probe] in
            var out: [String: Probe] = [:]
            var next = 0
            var done = 0
            while next < min(width, wanted.count) {
                let url = wanted[next]; next += 1
                group.addTask { (url, await Self.head(url)) }
            }
            while let (url, probe) = await group.next() {
                done += 1
                if let probe { out[url] = probe }
                if done % 200 == 0 { print("  \(done)/\(wanted.count)") }
                if next < wanted.count {
                    let url = wanted[next]; next += 1
                    group.addTask { (url, await Self.head(url)) }
                }
            }
            return out
        }

        have.merge(results) { _, new in new }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(have).write(to: probeFile, options: .atomic)
        let missing = results.values.filter { $0.status != 200 }.count
        print("  recorded \(results.count) sizes, \(missing) not found")
    }

    /// The size one PDF reports, without downloading a byte of it.
    private static func head(_ url: String) async -> Probe? {
        guard let remote = URL(string: url) else { return nil }
        var request = URLRequest(url: remote)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                         forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            try? await Task.sleep(nanoseconds: 150_000_000)
            let http = response as? HTTPURLResponse
            let length = http?.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
            return Probe(status: http?.statusCode ?? -1,
                         bytes: http?.statusCode == 200 ? length : nil)
        } catch {
            return nil
        }
    }

    public struct Missing: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }
}
