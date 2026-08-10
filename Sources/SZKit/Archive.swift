import Compression
import Foundation

public enum ArchiveError: Error, CustomStringConvertible {
    case notAnArchive
    case corrupt(String)
    case unsupportedCompression(UInt16)
    case entryNotFound(String)
    /// RAR needs a real decompressor; see `RarReader`.
    case rarSupportMissing

    public var description: String {
        switch self {
        case .notAnArchive: return "file is neither zip nor rar"
        case .corrupt(let m): return "corrupt archive: \(m)"
        case .unsupportedCompression(let m): return "unsupported zip compression method \(m)"
        case .entryNotFound(let n): return "no such entry: \(n)"
        case .rarSupportMissing:
            return "RAR archives need a decompressor linked into the app target "
                 + "(UnrarKit or libarchive) — see RarReader"
        }
    }
}

public protocol ArchiveReader {
    func entries() throws -> [String]
    func data(for entry: String) throws -> Data
}

extension ArchiveReader {
    /// Image entries in reading order.
    public func pageNames() throws -> [String] {
        PageManifest.pages(from: try entries())
    }
}

/// Opens whichever container the bytes actually are.
public enum ArchiveOpener {
    public static func open(_ url: URL) throws -> ArchiveReader {
        switch ArchiveKind.sniff(url) {
        case .zip: return try ZipReader(url: url)
        case .rar: return RarReader()
        case .unknown: throw ArchiveError.notAnArchive
        }
    }
}

/// Minimal zip reader, dependency-free.
///
/// Only the central directory is parsed, so entry listing is cheap and page
/// extraction is random-access — which matters because the reader pulls single
/// pages on demand rather than unpacking 120 of them up front.
public struct ZipReader: ArchiveReader {

    private struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private let index: [String: Entry]
    private let order: [String]

    public init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        self.data = data
        guard let eocd = Self.findEOCD(data) else {
            throw ArchiveError.corrupt("no end-of-central-directory record")
        }
        let count = Int(data.u16(eocd + 10))
        var offset = Int(data.u32(eocd + 16))

        var index: [String: Entry] = [:]
        var order: [String] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(offset) == 0x02014b50 else {
                throw ArchiveError.corrupt("bad central directory header")
            }
            let nameLength = Int(data.u16(offset + 28))
            let extraLength = Int(data.u16(offset + 30))
            let commentLength = Int(data.u16(offset + 32))
            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else {
                throw ArchiveError.corrupt("truncated entry name")
            }
            let name = String(decoding: data[nameStart..<nameStart + nameLength], as: UTF8.self)
            let entry = Entry(name: name,
                              method: data.u16(offset + 10),
                              compressedSize: Int(data.u32(offset + 20)),
                              uncompressedSize: Int(data.u32(offset + 24)),
                              localHeaderOffset: Int(data.u32(offset + 42)))
            if index[name] == nil { order.append(name) }
            index[name] = entry
            offset = nameStart + nameLength + extraLength + commentLength
        }
        self.index = index
        self.order = order
    }

    public func entries() throws -> [String] { order }

    public func data(for entry: String) throws -> Data {
        guard let e = index[entry] else { throw ArchiveError.entryNotFound(entry) }
        // The local header repeats the name/extra lengths, and they can differ
        // from the central directory's, so they must be read here.
        let lh = e.localHeaderOffset
        guard lh + 30 <= data.count, data.u32(lh) == 0x04034b50 else {
            throw ArchiveError.corrupt("bad local header for \(entry)")
        }
        let start = lh + 30 + Int(data.u16(lh + 26)) + Int(data.u16(lh + 28))
        guard start + e.compressedSize <= data.count else {
            throw ArchiveError.corrupt("truncated data for \(entry)")
        }
        let payload = data.subdata(in: start..<start + e.compressedSize)

        switch e.method {
        case 0: return payload                                   // stored
        case 8:
            guard let out = Self.inflate(payload, expectedSize: e.uncompressedSize) else {
                throw ArchiveError.corrupt("inflate failed for \(entry)")
            }
            return out
        default:
            throw ArchiveError.unsupportedCompression(e.method)
        }
    }

    /// Apple's COMPRESSION_ZLIB is raw DEFLATE, which is exactly what zip
    /// stores — no zlib wrapper to strip.
    static func inflate(_ payload: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var out = Data(count: expectedSize)
        let capacity = expectedSize
        let written = out.withUnsafeMutableBytes { dst -> Int in
            payload.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, capacity, s, payload.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        return written == expectedSize ? out : nil
    }

    /// Scans backwards for the EOCD signature; the record sits at the end but
    /// may be followed by a variable-length comment.
    private static func findEOCD(_ data: Data) -> Int? {
        let minimum = 22
        guard data.count >= minimum else { return nil }
        let searchLimit = min(data.count, 65_557)     // max comment + record
        var i = data.count - minimum
        let stop = data.count - searchLimit
        while i >= stop && i >= 0 {
            if data.u32(i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }
}

/// RAR placeholder.
///
/// 98% of resolved filenames in the corpus are `.cbr`/`.rar`, so this is the
/// common case, not an edge case. RAR decompression cannot be implemented here:
/// the format is complex and the unrar licence explicitly forbids using its
/// source to reimplement the algorithm.
///
/// The app target must link a decompressor — UnrarKit (CocoaPods or a manual
/// Xcode integration; it has no SPM manifest) or a vendored libarchive — and
/// provide an `ArchiveReader` that wraps it.
public struct RarReader: ArchiveReader {
    public init() {}
    public func entries() throws -> [String] { throw ArchiveError.rarSupportMissing }
    public func data(for entry: String) throws -> Data { throw ArchiveError.rarSupportMissing }
}

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | (UInt16(self[startIndex + offset + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { acc, i in
            acc | (UInt32(self[startIndex + offset + i]) << (8 * UInt32(i)))
        }
    }
}
