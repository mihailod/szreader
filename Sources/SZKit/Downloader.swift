import Foundation

public struct DownloadProgress: Equatable, Sendable {
    public let received: Int64
    public let expected: Int64      // -1 when the server sends no length
}

/// Fetches bytes for a resolved link. Injectable so the queue is testable
/// without a network.
public protocol FileDownloader: Sendable {
    /// Writes the (still encrypted, if applicable) bytes to `destination`.
    ///
    /// `check` is handed the declared content length once, before any bytes are
    /// written, and aborts the transfer by throwing. That is where the free
    /// space guard lives: the size arrives in the response headers of the
    /// transfer itself, so nothing has to ask the host a second question — and
    /// a second request moments after resolving a link is exactly what looks
    /// like scraping.
    func download(_ link: DirectLink, to destination: URL,
                  progress: (@Sendable (DownloadProgress) -> Void)?,
                  check: (@Sendable (Int64) throws -> Void)?) async throws
}

public extension FileDownloader {
    /// Most callers do not care about the size up front.
    func download(_ link: DirectLink, to destination: URL,
                  progress: (@Sendable (DownloadProgress) -> Void)?) async throws {
        try await download(link, to: destination, progress: progress, check: nil)
    }
}

public enum DownloadError: Error, CustomStringConvertible {
    case allMirrorsFailed([String])
    case badStatus(Int)
    case emptyFile
    case notAnArchive(String)
    case insufficientSpace(required: Int64, available: Int64)
    /// The server asked to be left alone for a while, and said so.
    case rateLimited(host: String, retryAfter: TimeInterval?)

    public var description: String {
        switch self {
        case .allMirrorsFailed(let reasons):
            return "every mirror failed: " + reasons.joined(separator: "; ")
        case .badStatus(let c): return "HTTP \(c)"
        case .emptyFile: return "server returned no bytes"
        case .notAnArchive(let m): return "not a CBZ/CBR archive: \(m)"
        case .insufficientSpace:
            return "No free space on device — make room or remove some downloads"
        case .rateLimited(let host, let wait):
            // Written to be read by whoever tapped Download, because that is
            // who has to act on it: the answer is to wait, and the only useful
            // thing this can say is how long.
            guard let wait, wait > 0 else {
                return "\(host) is asking for a pause — too many requests. "
                     + "Wait a few minutes before trying again."
            }
            return "\(host) is asking for a pause — too many requests. "
                 + "Wait \(RetryAfter.phrase(wait)) before trying again."
        }
    }
}

extension DownloadError {
    var isInsufficientSpace: Bool {
        if case .insufficientSpace = self { return true }
        return false
    }

    /// Whether this is the server asking to be left alone.
    ///
    /// Its own question because it is the one failure that must not be
    /// retried, must not be blamed on the mirror, and must not mark the issue
    /// as failed on the shelf: nothing is wrong with the link. Public because
    /// the last of those three is the app's call, not the library's — the
    /// shelf mark and the alert both live up there.
    public var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
    }

    /// A status that says the server is having a moment rather than that the
    /// file is gone.
    ///
    /// Worth telling apart because only one of them is worth trying again.
    /// archive.org's item servers answer 500 to roughly one request in three —
    /// measured against a single URL that served fine on the attempts either
    /// side of each failure — and an issue there has exactly one mirror, so
    /// without a second try a third of downloads fail outright.
    var isServerError: Bool {
        if case .badStatus(let code) = self { return (500..<600).contains(code) }
        return false
    }
}

/// `Retry-After`, which is two headers wearing one name.
///
/// RFC 9110 allows either a number of seconds or an HTTP date, and the hosts
/// here use both — a CDN in front of an archive tends to send seconds, an
/// origin under load tends to send a date. Reading only one of them would turn
/// half of all rate limits into an unexplained failure.
public enum RetryAfter {

    /// How long the server asked for, or nil if it did not say.
    ///
    /// A date in the past — a clock skewed, or a response that sat in a queue —
    /// is nil rather than a negative wait, because "wait -4 seconds" is not
    /// something to put in front of a reader.
    public static func seconds(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty
        else { return nil }
        if let delta = TimeInterval(header) { return delta > 0 ? delta : nil }
        guard let date = httpDate.date(from: header) else { return nil }
        let wait = date.timeIntervalSince(now)
        return wait > 0 ? wait : nil
    }

    /// "4 minutes", "30 seconds" — a wait as someone would say it.
    ///
    /// Rounded up, never down: a message that says one minute for a 90-second
    /// limit sends the reader back early to the same refusal.
    public static func phrase(_ seconds: TimeInterval) -> String {
        if seconds < 90 {
            let whole = max(1, Int(seconds.rounded(.up)))
            return "\(whole) second\(whole == 1 ? "" : "s")"
        }
        if seconds < 5400 {
            let minutes = max(1, Int((seconds / 60).rounded(.up)))
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        let hours = max(1, Int((seconds / 3600).rounded(.up)))
        return "\(hours) hour\(hours == 1 ? "" : "s")"
    }

    /// Fixed to the format and locale the header is defined in, not the
    /// device's — an iPad set to Croatian would otherwise fail to read a date
    /// that is always written in English.
    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// The refusal a response amounts to, if it is one.
    ///
    /// 429 is the header for it and always counts, with or without a stated
    /// wait. A 503 counts only when it carries one: a bare 503 is a server
    /// having a moment, which is retried, while a 503 that names a wait is the
    /// same server asking not to be.
    ///
    /// Public because one source fetches its own bytes from the app layer:
    /// BatCave has no archive to hand a file host, so its pages are requested
    /// outside `URLSessionDownloader` entirely and would otherwise have no way
    /// to read a refusal — or would grow a second, subtly different copy of
    /// this, which is the failure this app has already had once with the
    /// two spellings of a source name.
    public static func refusal(status: Int, header: String?, host: String) -> DownloadError? {
        let wait = seconds(header)
        if status == 429 { return .rateLimited(host: host, retryAfter: wait) }
        if status == 503, wait != nil { return .rateLimited(host: host, retryAfter: wait) }
        return nil
    }
}

public final class URLSessionDownloader: NSObject, FileDownloader, @unchecked Sendable {

    private let userAgent: String

    /// A *background* configuration is what keeps a 90 MB transfer alive while
    /// the app is suspended. It is also why Mega decryption is a separate pass:
    /// the system writes the raw bytes out of process, so nothing can transform
    /// the stream in flight.
    public init(userAgent: String = UserAgent.browser) {
        self.userAgent = userAgent
    }

    public func download(_ link: DirectLink, to destination: URL,
                         progress: (@Sendable (DownloadProgress) -> Void)?,
                         check: (@Sendable (Int64) throws -> Void)? = nil) async throws {
        var request = URLRequest(url: link.url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in link.headers { request.setValue(v, forHTTPHeaderField: k) }

        let session = URLSession(configuration: .default)
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Asked before the status is reported as a plain failure: a
            // refusal names a wait, and the wait is the whole answer.
            if let refusal = RetryAfter.refusal(
                status: http.statusCode,
                header: http.value(forHTTPHeaderField: "Retry-After"),
                host: link.url.host ?? "the server") {
                throw refusal
            }
            throw DownloadError.badStatus(http.statusCode)
        }
        // What the server says, or what the host knew in advance when it says
        // nothing. A streaming script sends no length and reports -1, which
        // leaves the reader watching a bar that cannot move and a free-space
        // check with nothing to check.
        let declared = response.expectedContentLength
        let expected = declared > 0 ? declared : (link.expectedBytes ?? declared)

        // Before the file is created, so a refusal leaves nothing behind.
        try check?(expected)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                handle.write(buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress?(DownloadProgress(received: received, expected: expected))
            }
        }
        if !buffer.isEmpty {
            handle.write(buffer)
            received += Int64(buffer.count)
        }
        progress?(DownloadProgress(received: received, expected: expected))
        if received == 0 { throw DownloadError.emptyFile }
    }
}

/// Archive sniffing.
///
/// A large share of scene `.cbr` files are actually zips and vice versa, so the
/// extension is not evidence. This is also the cheapest check that a Mega
/// decrypt produced real bytes rather than noise.
public enum ArchiveKind: String, Sendable {
    case zip, rar, sevenZip, pdf, unknown

    public static func sniff(_ url: URL) -> ArchiveKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 8)
        return sniff(magic)
    }

    public static func sniff(_ magic: Data) -> ArchiveKind {
        if magic.starts(with: [0x50, 0x4B, 0x03, 0x04]) ||        // PK\x03\x04
           magic.starts(with: [0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if magic.starts(with: [0x52, 0x61, 0x72, 0x21]) { return .rar }   // "Rar!"
        // 7z's signature is six bytes, which is why the sniff reads eight.
        if magic.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        // A comic can arrive as a PDF rather than a container of scans.
        if magic.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }   // "%PDF"
        return .unknown
    }
}
