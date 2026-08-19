import Foundation
import Network

/// A one-file web server, so a direct download can be tested against a real
/// socket instead of a stub.
///
/// `DirectHost` is almost all absence — it resolves nothing, signs nothing and
/// asks nobody anything. That makes a unit test of it nearly vacuous: the
/// interesting claim is not what the host returns but that a plain URL travels
/// all the way through `Library.fetch`, `URLSessionDownloader` and the archive
/// sniff to a readable comic on disk. Only a real server proves that.
///
/// Serves `HTTP/1.0` with an explicit `Content-Length` and closes the
/// connection after each response, which is the least protocol that
/// `URLSession` will accept without keep-alive bookkeeping.
final class TinyHTTPServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "tiny-http")
    private let routes: [String: Data]
    private let omitContentLength: Bool
    /// How many of the first requests to answer with a 500 before serving.
    ///
    /// Not a fault-injection framework — one counter, because one archive
    /// really does behave this way: archive.org's item servers answer 500 to
    /// roughly a third of requests for a file they then serve fine.
    private let failFirst: Int
    /// When set, every request is refused with 429 and this `Retry-After`.
    private let refuseWith: String?
    private(set) var port: UInt16 = 0
    /// Paths that were actually requested, in order.
    private(set) var requested: [String] = []
    private let lock = NSLock()

    /// - Parameters:
    ///   - routes: path (with leading slash) to body. Anything not listed is a
    ///     404, which is what the eight dead archives look like.
    ///   - failFirst: answer this many requests with 500 first.
    ///   - refuseWith: answer every request 429 with this `Retry-After` value.
    ///   - omitContentLength: answer without a `Content-Length`, closing the
    ///     connection to mark the end instead. Comic Book Plus serves its
    ///     downloads from a streaming script that does exactly this, and it is
    ///     the case where `expectedContentLength` arrives as -1 and nothing
    ///     downstream can learn a total.
    init(routes: [String: Data], failFirst: Int = 0, refuseWith: String? = nil,
         omitContentLength: Bool = false) throws {
        self.routes = routes
        self.failFirst = failFirst
        self.refuseWith = refuseWith
        self.omitContentLength = omitContentLength
        listener = try NWListener(using: .tcp, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else {
            listener.cancel()
            throw Failure("the test server never came up")
        }
    }

    var base: String { "http://127.0.0.1:\(port)" }

    func stop() { listener.cancel() }

    // MARK: - Serving

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // One read is enough: these requests are a couple of hundred bytes
        // and arrive in a single segment. A server that had to handle bodies
        // would need to keep reading; this one never sees a POST.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = Self.path(ofRequest: request)

            self.lock.lock()
            self.requested.append(path)
            let sulk = self.requested.count <= self.failFirst
            self.lock.unlock()

            let response: Data
            if let after = self.refuseWith {
                response = Self.reply(status: "429 Too Many Requests",
                                      body: Data("slow down".utf8),
                                      headers: ["Retry-After": after])
            } else if sulk {
                response = Self.reply(status: "500 Internal Server Error",
                                      body: Data("later".utf8))
            } else if let body = self.routes[path] {
                response = Self.reply(status: "200 OK", body: body,
                                      omitLength: self.omitContentLength)
            } else {
                response = Self.reply(status: "404 Not Found", body: Data("no".utf8))
            }
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// "GET /a/b.zip HTTP/1.1" -> "/a/b.zip"
    private static func path(ofRequest request: String) -> String {
        let parts = request.split(separator: "\r\n").first?.split(separator: " ") ?? []
        return parts.count >= 2 ? String(parts[1]) : ""
    }

    private static func reply(status: String, body: Data,
                              headers: [String: String] = [:],
                              omitLength: Bool = false) -> Data {
        let extra = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        // HTTP/1.0 with `Connection: close` is a body delimited by the close
        // itself, which is a legal way to answer without a length and is what
        // a streaming script amounts to.
        let length = omitLength ? "" : "Content-Length: \(body.count)\r\n"
        var out = Data("""
            HTTP/1.0 \(status)\r
            Content-Type: application/zip\r
            \(length)\(extra)Connection: close\r
            \r\n
            """.utf8)
        out.append(body)
        return out
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
