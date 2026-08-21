import Foundation

/// Pages, fetched once and remembered.
///
/// Sequential and paced. This is one person's server, asked to serve a tree it
/// has told crawlers to leave alone; the least the tool can do is take it
/// slowly and never ask twice. Deleting `.bombjack-cache/` is how you ask for
/// fresh copies, and that being deliberate is the point.
struct PageCache {

    let directory: URL
    let allowNetwork: Bool
    /// One page a second. Slow enough to be unnoticeable on the far end.
    static let pause: Duration = .milliseconds(1000)
    /// Named rather than left to URLSession, which would otherwise announce
    /// this as a Swift process to a server that has asked for no crawlers.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

    init(directory: URL, allowNetwork: Bool) {
        self.directory = directory
        self.allowNetwork = allowNetwork
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Keyed by a digest of the URL rather than by its path: the tree contains
    /// query strings, escaped spaces and mixed case, none of which make a safe
    /// filename, and two URLs differing only in escaping are two pages.
    private func file(for url: String) -> URL {
        directory.appendingPathComponent("\(Digest.hex(url)).html")
    }

    /// Nil when the page is missing, not HTML, or the site refused it — all of
    /// which are ordinary in a tree this old, and none of which should stop a
    /// build that has thousands of other pages to read.
    func page(_ url: String) async throws -> String? {
        let cached = file(for: url)
        if let data = try? Data(contentsOf: cached) {
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        }
        guard allowNetwork, let remote = URL(string: url) else { return nil }

        try? await Task.sleep(for: Self.pause)
        var request = URLRequest(url: remote)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Without this a single stalled connection hangs the whole build:
        // `URLSession`'s default resource timeout is measured in days, and a
        // rebuild that should read from disk sat at 0% CPU for eleven minutes
        // waiting on one page that never answered.
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }

        try? data.write(to: cached)
        // These pages are twenty years of hand-edited HTML and not all of it
        // is UTF-8; Latin-1 is what the rest of it is.
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

/// A short stable digest, without pulling in CryptoKit for a filename.
enum Digest {
    static func hex(_ s: String) -> String {
        var h1: UInt64 = 0xcbf29ce484222325, h2: UInt64 = 0x84222325cbf29ce4
        for byte in s.utf8 {
            h1 = (h1 ^ UInt64(byte)) &* 0x100000001b3
            h2 = (h2 &+ UInt64(byte)) &* 0x9e3779b97f4a7c15
        }
        return String(format: "%016lx%016lx", h1, h2)
    }
}
