import CUnrar
import Foundation

/// Reads RAR (and RAR5) archives via the vendored unrar sources.
///
/// 98% of resolved filenames in the corpus are `.cbr`/`.rar`, so this is the
/// main path, not a fallback.
///
/// Unlike `ZipReader`, this unpacks everything on construction rather than
/// serving entries lazily. RAR archives are frequently *solid* — entries share
/// compression state, so reaching entry N means decompressing everything before
/// it. One ordered pass is the only sane access pattern, and it matches the
/// library layout anyway, where the archive is unpacked once and then deleted.
public struct RarReader: ArchiveReader {

    private let root: URL
    private let names: [String]

    /// Entry names without unpacking. Cheap enough to use for validation.
    public static func list(archiveAt url: URL) throws -> [String] {
        var needed = 0
        var code = szunrar_list(url.path, nil, 0, &needed)
        guard code == SZUNRAR_OK else { throw ArchiveError.rar(code) }
        guard needed > 0 else { return [] }

        var buffer = [CChar](repeating: 0, count: needed)
        code = szunrar_list(url.path, &buffer, needed, &needed)
        guard code == SZUNRAR_OK else { throw ArchiveError.rar(code) }

        // Names are packed back to back, each NUL-terminated.
        return buffer.split(separator: 0, omittingEmptySubsequences: true).map {
            String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// Written once extraction has finished, so a directory left behind by an
    /// interrupted unpack is not mistaken for a complete one.
    private static let doneMarker = ".szunpacked"

    /// Unpacks `url` beneath `workDirectory` and indexes the result.
    ///
    /// Unpacking is skipped when the directory already holds a finished
    /// extraction. It used to run on every open: re-unpacking 90 MB to read a
    /// comic already sitting unpacked on disk is most of the delay between
    /// tapping a cover and seeing a page.
    public init(url: URL, workDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let marker = workDirectory.appendingPathComponent(Self.doneMarker)
        if !fm.fileExists(atPath: marker.path) {
            let code = szunrar_extract_all(url.path, workDirectory.path)
            guard code == SZUNRAR_OK else { throw ArchiveError.rar(code) }
            fm.createFile(atPath: marker.path, contents: nil)
        }

        self.root = workDirectory
        self.names = Self.walk(workDirectory).filter { $0 != Self.doneMarker }

        // unrar accepts a bare RAR signature with no headers as an "empty
        // archive" and reports success, so a truncated download would otherwise
        // arrive as a silent 0-page comic. No real comic archive is empty.
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
        return try Data(contentsOf: root.appendingPathComponent(entry), options: .mappedIfSafe)
    }

    /// Where the unpacked pages live, so a caller can delete them on eviction.
    public var unpackedDirectory: URL { root }
}
