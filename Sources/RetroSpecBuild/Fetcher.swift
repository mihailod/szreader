import Foundation

/// Fetches pages and archive headers, remembering everything it is told.
///
/// Sequential on purpose. This talks to one small Apache serving a hobby
/// archive, the whole job is ~1300 requests, and it is run by hand a few
/// times a year — so the polite pace costs a few minutes once and nothing
/// afterwards, and there is no concurrency here to get wrong.
struct Fetcher {

    /// What a HEAD on an archive came back with.
    struct Probe: Codable, Equatable {
        let status: Int
        let bytes: Int64?
    }

    let directory: URL
    let allowNetwork: Bool

    private var probeFile: URL { directory.appendingPathComponent("archive-sizes.json") }

    init(directory: URL, allowNetwork: Bool) {
        self.directory = directory
        self.allowNetwork = allowNetwork
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Pages

    /// A page, from the cache if it is there and from the site if it is not.
    ///
    /// The cache is never invalidated by age. These pages last changed in
    /// 2023 and the whole point of the offline build is that the catalogue is
    /// reproducible; deleting `.retrospec-cache/` is how you ask for fresh
    /// copies, and that is deliberate rather than a missing feature.
    func page(at url: String, key: String) async throws -> Data {
        let file = directory.appendingPathComponent(key)
        if let cached = try? Data(contentsOf: file) { return cached }
        guard allowNetwork else {
            throw Missing("\(key) is not cached and --no-network was given")
        }
        guard let remote = URL(string: url) else { throw Missing("bad URL: \(url)") }

        let (data, response) = try await URLSession.shared.data(from: remote)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Missing("\(url) returned "
                          + "\((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        try await pause()
        return data
    }

    // MARK: - Archives

    /// The size an archive reports, without downloading a byte of it.
    ///
    /// Kept in one file rather than one per archive: 653 tiny files is a
    /// directory nobody wants, and the whole map is read and written at once
    /// anyway.
    func probe(_ url: String, key: String) async throws -> Probe {
        var known = (try? Data(contentsOf: probeFile))
            .flatMap { try? JSONDecoder().decode([String: Probe].self, from: $0) } ?? [:]
        if let hit = known[key] { return hit }
        guard allowNetwork else {
            throw Missing("\(key) has no recorded size and --no-network was given")
        }
        guard let remote = URL(string: url) else { throw Missing("bad URL: \(url)") }

        var request = URLRequest(url: remote)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let length = http?.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        let result = Probe(status: http?.statusCode ?? -1,
                           bytes: http?.statusCode == 200 ? length : nil)

        known[key] = result
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(known).write(to: probeFile, options: .atomic)
        try await pause()
        return result
    }

    /// A beat between requests, so a full build reads as a slow visitor
    /// rather than a scrape.
    private func pause() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    struct Missing: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
