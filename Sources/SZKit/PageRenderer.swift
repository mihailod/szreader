import CoreGraphics
import Foundation
import ImageIO

/// Decodes comic pages at the size they will actually be shown.
///
/// Scans are commonly 2000-3000px on the long edge. A 2500x3500 page decodes to
/// roughly 35 MB in memory, so holding a handful of full-resolution pages is
/// enough to get an app jetsammed on a base-model iPad. ImageIO's thumbnail
/// path decodes straight to the target size instead of decoding full and then
/// scaling down.
public enum PageRenderer {

    /// Pixel dimensions without decoding the image.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Decodes at most `maxPixelSize` on the long edge, preserving aspect.
    ///
    /// Pass the screen's long edge in *pixels* (points x scale). Anything more
    /// is memory spent on detail the panel cannot show.
    public static func downsample(data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF rotation
            kCGImageSourceShouldCacheImmediately: true,         // decode now, not at draw time
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Whether the bytes decode as an image at all — a page that fails this is
    /// a corrupt entry rather than a page.
    public static func isDecodable(_ data: Data) -> Bool {
        pixelSize(of: data) != nil
    }
}

/// A comic that has been downloaded and opened.
///
/// Pages are pulled from the archive on demand. Extracting all of them up front
/// would cost a second copy of a 90 MB file on disk for no benefit, since the
/// reader only ever shows a handful at a time.
public final class ComicDocument {

    /// One entry per archive the comic spans, in reading order.
    ///
    /// Usually one. Two conventions on the forum look identical from the
    /// filename and are not the same thing:
    ///
    ///   - `….part1.rar` / `….part2.rar` are *volumes* of one archive. Only
    ///     the first opens; unrar reads the rest itself, and volume one
    ///     already yields the whole comic.
    ///   - `…_1_deo.7z` / `…_2_deo.7z` are two complete archives with half
    ///     the pages in each. ("deo" is Serbian for part.) 7z has its own
    ///     multi-volume format — `.7z.001`, `.7z.002` — and this is not it;
    ///     whoever posted these packed the comic twice over, deliberately.
    ///     The first opens perfectly well and simply stops halfway.
    ///
    /// So a piece that opens on its own is not evidence of anything by
    /// itself. What separates the cases is whether its pages are *new*.
    private let volumes: [(reader: ArchiveReader, pages: [String])]

    /// Every page across every volume, in order.
    public let pages: [String]

    /// The first archive, which is what a caller inspecting the container
    /// means by "the archive".
    public var archive: ArchiveReader { volumes[0].reader }

    public convenience init(archive: ArchiveReader) throws {
        try self.init(volumes: [archive])
    }

    public init(volumes readers: [ArchiveReader]) throws {
        precondition(!readers.isEmpty, "a comic needs at least one archive")
        var built: [(ArchiveReader, [String])] = []
        var seen: Set<String> = []
        for reader in readers {
            let names = try reader.pageNames()
            guard !names.isEmpty else { continue }
            // A later volume that lists nothing new is the same content over
            // again, not a second half. That is what a RAR volume looks like
            // when unrar consents to open it out of order: volume one has
            // already yielded these pages, and appending them would show the
            // comic twice.
            guard !names.allSatisfy(seen.contains) else { continue }
            seen.formUnion(names)
            built.append((reader, names))
        }
        self.volumes = built.isEmpty ? [(readers[0], [])] : built
        self.pages = self.volumes.flatMap(\.1)

        guard !pages.isEmpty else {
            // Say what is actually in there. A reader handed zero pages shows
            // an empty frame and a spinner that never resolves, which looks
            // like a hang rather than an unreadable file.
            let entries = (try? readers[0].entries()) ?? []
            let sample = entries.prefix(3).joined(separator: ", ")
            throw ArchiveError.corrupt(
                "no readable pages in archive (\(entries.count) entries: \(sample))")
        }
    }

    /// Opens a comic, unwrapping a nested archive if that is what it is.
    ///
    /// Scanlation downloads are frequently a zip whose only entry is the real
    /// `.cbz`. Depth is capped: two levels covers every wrapper seen in the
    /// corpus, and refusing to recurse further means a maliciously nested
    /// archive cannot spin the unpacker.
    public convenience init(fileURL: URL, workDirectory: URL? = nil) throws {
        let work = workDirectory
            ?? fileURL.deletingPathExtension().appendingPathExtension("unpacked")
        Self.discardNestedVolumes(in: work)
        var current = try ArchiveOpener.open(fileURL, workDirectory: work)

        for depth in 0..<2 {
            let entries = try current.entries()
            if !PageManifest.pages(from: entries).isEmpty { break }
            guard let nested = PageManifest.nestedArchives(in: entries).first else { break }

            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let unwrapped = work.appendingPathComponent(
                "nested-\(depth)-" + (nested as NSString).lastPathComponent)
            // Written once. This is a full copy of the inner archive — around
            // 100 MB for a scanlation — and rewriting it on every open is time
            // spent reproducing a file that is already there.
            if !FileManager.default.fileExists(atPath: unwrapped.path) {
                try current.data(for: nested).write(to: unwrapped, options: .atomic)
            }
            current = try ArchiveOpener.open(
                unwrapped, workDirectory: work.appendingPathComponent("nested-\(depth)-work"))
        }
        try self.init(volumes: [current] + Self.companions(of: fileURL, beside: work))
    }

    /// Later pieces that turn out to be whole archives of their own.
    ///
    /// Opened rather than judged by name, because the names of the two
    /// conventions are indistinguishable. A piece that will not open is a RAR
    /// fragment, already folded into volume one. A piece that opens with
    /// pages volume one did not have is the rest of the comic. A piece that
    /// opens with the pages volume one already had is dropped upstream, in
    /// `init(volumes:)`.
    /// Clears volume directories left inside `work` by the build that nested
    /// them, so a comic unpacked by that build is not read as double-length
    /// for ever. Cheap and silent when there are none, which is the normal
    /// case.
    private static func discardNestedVolumes(in work: URL) {
        let fm = FileManager.default
        let stale = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        for url in stale where url.lastPathComponent.hasPrefix("volume-") {
            try? fm.removeItem(at: url)
        }
    }

    private static func companions(of first: URL, beside work: URL) -> [ArchiveReader] {
        guard let firstPart = MultiPartArchive.partNumber(in: first.lastPathComponent),
              firstPart == 1 else { return [] }

        let directory = first.deletingLastPathComponent()
        let stem = MultiPartArchive.stem(of: first.lastPathComponent)
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []

        let ordered = siblings.compactMap { url -> (URL, Int)? in
            let name = url.lastPathComponent
            // Unpacked directories carry the same names as the archives they
            // came from; only a file can be a second archive.
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { return nil }
            guard MultiPartArchive.stem(of: name) == stem,
                  let part = MultiPartArchive.partNumber(in: name), part > 1
            else { return nil }
            return (url, part)
        }.sorted { $0.1 < $1.1 }

        return ordered.compactMap { url, part in
            // A sibling of volume one's work directory, never a child of it.
            // Nested, the second half's pages land *inside* the first half's
            // unpacked tree — harmless on the first open, because volume one
            // has already been indexed by then, but on every open after that
            // volume one walks the directory afresh, finds the second half
            // sitting in it, and reports the whole comic. Volume two then
            // adds its pages again under their own paths, so the comic grows
            // by half every time it is opened.
            let sibling = work.deletingLastPathComponent()
                .appendingPathComponent(work.lastPathComponent + "-volume-\(part)")
            guard let reader = try? ArchiveOpener.open(url, workDirectory: sibling),
                  let names = try? reader.pageNames(), !names.isEmpty
            else { return nil }
            return reader
        }
    }

    public var pageCount: Int { pages.count }

    public func pageData(_ index: Int) throws -> Data {
        guard pages.indices.contains(index) else {
            throw ArchiveError.entryNotFound("page \(index)")
        }
        // Walk the volumes to find which one owns this page: a comic spanning
        // two archives has one page sequence but two sources.
        var remaining = index
        for volume in volumes {
            if remaining < volume.pages.count {
                return try volume.reader.data(for: volume.pages[remaining])
            }
            remaining -= volume.pages.count
        }
        throw ArchiveError.entryNotFound("page \(index)")
    }

    /// Decoded page, sized for the target screen.
    public func page(_ index: Int, maxPixelSize: Int) throws -> CGImage? {
        PageRenderer.downsample(data: try pageData(index), maxPixelSize: maxPixelSize)
    }

    /// Indices worth decoding ahead of `current`.
    ///
    /// Prefetching both directions keeps a back-flip as smooth as a forward
    /// one; the window is small on purpose, because each cached page costs
    /// real memory.
    public func prefetchWindow(around current: Int, radius: Int = 2) -> [Int] {
        let lower = max(0, current - radius)
        let upper = min(pageCount - 1, current + radius)
        guard lower <= upper else { return [] }
        return (lower...upper).filter { $0 != current }
    }
}
