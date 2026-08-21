import Foundation

/// Asks the server whether each archive is really there, and how big it is.
///
/// The catalogue is built from what the pages *say* exists, and about one link
/// in ten is a file that has since gone. Shipping those means a shelf where a
/// tenth of what you tap fails, which is worse than a shelf a tenth smaller.
///
/// A HEAD carries no body, so this is far cheaper per request than the page
/// walk was — but it is still one request per archive against a hobby server,
/// so the answers are cached and the pace is kept deliberate. Deleting
/// `archive-status.json` is how you ask for fresh ones.
struct Prober {

    struct Answer: Codable, Equatable {
        let status: Int
        let bytes: Int64?
    }

    let file: URL
    let allowNetwork: Bool
    private(set) var known: [String: Answer]

    /// Slower than a browser, faster than the page walk: a HEAD returns
    /// headers alone, and there are eighteen thousand of them to get through.
    static let pause: Duration = .milliseconds(250)

    init(file: URL, allowNetwork: Bool) {
        self.file = file
        self.allowNetwork = allowNetwork
        self.known = (try? JSONDecoder().decode([String: Answer].self,
                                                from: Data(contentsOf: file))) ?? [:]
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(known).write(to: file)
    }

    /// What the server says about one archive, from the record if it is there.
    mutating func answer(for url: String) async -> Answer? {
        if let cached = known[url] { return cached }
        guard allowNetwork, let remote = URL(string: url) else { return nil }

        try? await Task.sleep(for: Self.pause)
        var request = URLRequest(url: remote)
        request.httpMethod = "HEAD"
        request.setValue(PageCache.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }

        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
        let answer = Answer(status: http.statusCode, bytes: length)
        known[url] = answer
        return answer
    }
}
