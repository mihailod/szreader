import C7z
import Foundation

/// Reads a `.7z` archive by unpacking it, like the RAR reader and for the same
/// reason: 7z archives are usually solid, so entry N costs decompressing
/// everything before it. Unpacking once, in order, is the only sane access
/// pattern.
public final class SevenZipReader: ArchiveReader {

    private let root: URL
    private let names: [String]

    /// Written once extraction has finished, so a directory left behind by an
    /// interrupted unpack is not mistaken for a complete one.
    private static let doneMarker = ".szunpacked"

    /// Unpacks `url` beneath `workDirectory` and indexes the result.
    ///
    /// Unpacking is skipped when the directory already holds a finished
    /// extraction — the same bargain as RAR, where re-unpacking a comic that is
    /// already on disk is most of the delay before a page appears.
    public init(url: URL, workDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let marker = workDirectory.appendingPathComponent(Self.doneMarker)
        if !fm.fileExists(atPath: marker.path) {
            let code = sz7z_extract_all(url.path, workDirectory.path)
            guard code == SZ7Z_OK else { throw ArchiveError.sevenZip(code) }
            fm.createFile(atPath: marker.path, contents: nil)
        }

        self.root = workDirectory
        self.names = Self.walk(workDirectory).filter { $0 != Self.doneMarker }

        // An archive the SDK opens but finds nothing in is a truncated
        // download, not a comic with no pages.
        guard !names.isEmpty else {
            throw ArchiveError.corrupt("archive contains no files (truncated or empty)")
        }
    }

    /// Relative paths of every extracted file, in no particular order —
    /// `PageManifest` does the ordering.
    private static func walk(_ root: URL) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        var out: [String] = []
        let prefix = root.standardizedFileURL.path
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            var path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
            out.append(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        }
        return out
    }

    public func entries() throws -> [String] { names }

    public func data(for entry: String) throws -> Data {
        guard names.contains(entry) else { throw ArchiveError.entryNotFound(entry) }
        return try Data(contentsOf: root.appendingPathComponent(entry))
    }

    /// Where the unpacked pages live, so a caller can delete them.
    public var unpackedDirectory: URL { root }
}
