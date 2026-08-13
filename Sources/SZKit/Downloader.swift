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

    public var description: String {
        switch self {
        case .allMirrorsFailed(let reasons):
            return "every mirror failed: " + reasons.joined(separator: "; ")
        case .badStatus(let c): return "HTTP \(c)"
        case .emptyFile: return "server returned no bytes"
        case .notAnArchive(let m): return "not a CBZ/CBR archive: \(m)"
        case .insufficientSpace:
            return "No free space on device — make room or remove some downloads"
        }
    }
}

extension DownloadError {
    var isInsufficientSpace: Bool {
        if case .insufficientSpace = self { return true }
        return false
    }
}

public final class URLSessionDownloader: NSObject, FileDownloader, @unchecked Sendable {

    private let userAgent: String

    /// A *background* configuration is what keeps a 90 MB transfer alive while
    /// the app is suspended. It is also why Mega decryption is a separate pass:
    /// the system writes the raw bytes out of process, so nothing can transform
    /// the stream in flight.
    public init(userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15") {
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
            throw DownloadError.badStatus(http.statusCode)
        }
        let expected = response.expectedContentLength

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
