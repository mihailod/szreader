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

    /// Writes a JPEG, for the one image this app keeps rather than decodes:
    /// a cover taken from a comic's own first page.
    @discardableResult
    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination)
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
    /// A comic whose archives are gone, opened from the pages they left.
    ///
    /// Volume directories when it spanned several archives, the work
    /// directory itself when it was one. The unpack marker is what makes this
    /// trustworthy: without it a directory half-filled by an interrupted
    /// extraction would read as a short comic.
    public convenience init(unpackedAt directory: URL) throws {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []

        // An outer archive holding one inner archive — a RAR volume set whose
        // volumes join into a single .cbr, say — is unwrapped into
        // "nested-<depth>-work", and that is where the pages end up. The
        // volume directories then hold the inner archive rather than any
        // pages, so looking there finds a comic with nothing in it.
        let nested = names
            .filter { $0.hasPrefix("nested-") && $0.hasSuffix("-work") }
            .sorted()
            .last
            .map { directory.appendingPathComponent($0, isDirectory: true) }

        let volumes = names
            .filter { $0.hasPrefix("volume-") }
            .sorted { (Int($0.dropFirst(7)) ?? 0) < (Int($1.dropFirst(7)) ?? 0) }
            .map { directory.appendingPathComponent($0, isDirectory: true) }

        let roots: [URL]
        if let nested { roots = [nested] }
        else if !volumes.isEmpty { roots = volumes }
        else { roots = [directory] }
        guard roots.allSatisfy({
            fm.fileExists(atPath: $0.appendingPathComponent(UnpackMarker.name).path)
        }) else { throw ArchiveError.corrupt("not unpacked") }

        // The same rule the archive side applies, because this is now the
        // only side that ever runs: a volume holding nothing the earlier ones
        // did not already have is a second copy of the comic, and once the
        // archives are gone nothing else will ever come back to clear it.
        var readers: [ArchiveReader] = []
        var seen: Set<String> = []
        for root in roots {
            let reader = UnpackedReader(root: root)
            let names = (try? reader.pageNames()) ?? []
            guard !names.isEmpty, !names.allSatisfy(seen.contains) else {
                // Never the work directory itself — that is the comic.
                if roots.count > 1 { try? fm.removeItem(at: root) }
                continue
            }
            seen.formUnion(names)
            readers.append(reader)
        }
        guard !readers.isEmpty else { throw ArchiveError.corrupt("no readable pages unpacked") }

        try self.init(volumes: readers)
    }

    public convenience init(fileURL: URL, workDirectory: URL? = nil) throws {
        let work = workDirectory
            ?? fileURL.deletingPathExtension().appendingPathExtension("unpacked")
        // Every archive of a multi-volume comic gets a directory of its own.
        // The reader indexes a work directory by walking it, so two archives
        // sharing one — or worse, one nested inside the other's — means each
        // sees the other's pages as its own.
        //
        // A single-archive comic keeps the whole directory, as before: giving
        // it a subdirectory would re-unpack every comic already on disk to no
        // purpose.
        let companions = Self.companionFiles(of: fileURL)
        var current: ArchiveReader
        if companions.isEmpty {
            current = try ArchiveOpener.open(fileURL, workDirectory: work)
        } else {
            current = try ArchiveOpener.open(
                fileURL, workDirectory: work.appendingPathComponent("volume-1"))
            Self.discardLooseUnpack(in: work, of: current)
        }

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
        try self.init(volumes: [current] + Self.open(companions, beside: work,
                                                     after: (try? current.pageNames()) ?? []))
    }

    /// Later pieces that turn out to be whole archives of their own.
    ///
    /// Opened rather than judged by name, because the names of the two
    /// conventions are indistinguishable. A piece that will not open is a RAR
    /// fragment, already folded into volume one. A piece that opens with
    /// pages volume one did not have is the rest of the comic. A piece that
    /// opens with the pages volume one already had is dropped upstream, in
    /// `init(volumes:)`.
    /// Clears an unpacked tree sitting in the root of `work`, left by the
    /// layout that gave volume one the whole directory.
    ///
    /// Only files the archive is known to contain are removed, so the
    /// downloaded archives themselves are never at risk. Without this a comic
    /// already on disk keeps a second copy of every page for good: nothing
    /// reads them, and nothing else would ever delete them.
    private static func discardLooseUnpack(in work: URL, of reader: ArchiveReader) {
        let fm = FileManager.default
        let marker = work.appendingPathComponent(UnpackMarker.name)
        guard fm.fileExists(atPath: marker.path) else { return }

        for entry in (try? reader.entries()) ?? [] {
            try? fm.removeItem(at: work.appendingPathComponent(entry))
        }
        try? fm.removeItem(at: marker)

        // The folders those pages sat in, now that they hold nothing.
        let left = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []
        for url in left where !url.lastPathComponent.hasPrefix("volume-") {
            if (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Files that might be later pieces of the same comic, in volume order.
    ///
    /// Decided on names alone, because this has to be known before volume one
    /// is opened — whether they really are pieces is settled afterwards, by
    /// opening them.
    private static func companionFiles(of first: URL) -> [(url: URL, part: Int)] {
        guard let firstPart = MultiPartArchive.partNumber(in: first.lastPathComponent),
              firstPart == 1 else { return [] }

        let stem = MultiPartArchive.stem(of: first.lastPathComponent)
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: first.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isRegularFileKey])) ?? []

        return siblings.compactMap { url -> (URL, Int)? in
            // Unpacked directories carry the names of the archives they came
            // from; only a file can be a second archive.
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true,
                  MultiPartArchive.stem(of: url.lastPathComponent) == stem,
                  let part = MultiPartArchive.partNumber(in: url.lastPathComponent),
                  part > 1
            else { return nil }
            return (url, part)
        }.sorted { $0.1 < $1.1 }
    }

    /// Those of them that turn out to be whole archives of their own.
    ///
    /// Opened rather than judged by name, because the names of the two
    /// conventions are indistinguishable. A piece that will not open is a RAR
    /// fragment, already folded into volume one. A piece that opens with
    /// pages volume one did not have is the rest of the comic. A piece that
    /// opens with the pages volume one already had is dropped upstream, in
    /// `init(volumes:)`.
    private static func open(_ companions: [(url: URL, part: Int)], beside work: URL,
                             after firstPages: [String]) -> [ArchiveReader] {
        var seen = Set(firstPages)
        var readers: [ArchiveReader] = []
        for (url, part) in companions {
            let own = work.appendingPathComponent("volume-\(part)")
            guard let reader = try? ArchiveOpener.open(url, workDirectory: own),
                  let names = try? reader.pageNames(), !names.isEmpty,
                  !names.allSatisfy(seen.contains)
            else {
                // Nothing new here, or nothing readable. Either way whatever
                // was unpacked is dead weight and has to go: a RAR volume set
                // is joined by unrar when the first volume is opened, so
                // extracting the second leaves a whole second copy of the
                // comic on disk — for a 325 MB download, 325 MB wasted.
                try? FileManager.default.removeItem(at: own)
                continue
            }
            seen.formUnion(names)
            readers.append(reader)
        }
        return readers
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
