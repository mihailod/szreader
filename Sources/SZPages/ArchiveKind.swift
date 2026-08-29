import Foundation

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
