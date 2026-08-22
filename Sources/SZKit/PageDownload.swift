import Foundation

/// The bytes of one page, checked before they are written.
///
/// This exists because of the gate in front of the site. Every request for a
/// page image can be answered with a challenge page, an error page or an
/// advertisement instead of a picture, and all three arrive as HTTP 200 with a
/// body. Written blind, they become files named `0007.jpg` that hold HTML —
/// and the comic then has a blank page in it that nothing later explains.
///
/// A magic number is the cheapest thing that tells them apart, and it is
/// decisive: no image format begins with `<`.
public enum ImageBytes {

    /// Whether these bytes begin like an image this app can draw.
    ///
    /// The formats are the ones `PageManifest` already treats as pages, minus
    /// the ones no web reader serves. Anything unrecognised is refused rather
    /// than written, which is the safe direction: a page wrongly refused is a
    /// retry, a page wrongly accepted is a hole in the comic.
    public static func looksLikeImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return false }

        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }             // JPEG
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }       // PNG
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }       // GIF87a/89a
        if bytes.starts(with: [0x42, 0x4D]) { return true }                   // BMP
        // WEBP is a RIFF container that names itself at offset 8.
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return true }
        // HEIC and AVIF are ISO base media files: a `ftyp` box at offset 4.
        if bytes.count >= 8, Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] { return true }
        return false
    }
}

/// One issue's pages, on their way to disk.
///
/// A BatCave download is not a file — the site serves no archive — so there is
/// nothing to unpack afterwards. The pages are written straight into the
/// issue's directory in the layout `ComicDocument(unpackedAt:)` already reads,
/// which is what lets a source with no archive at all produce a comic the rest
/// of the app cannot tell apart from a downloaded one.
///
/// **The marker is written last, and that is the whole safety property.**
/// `ComicDocument(unpackedAt:)` refuses a directory without `.szunpacked`,
/// specifically so a half-filled one is not mistaken for a short comic. A
/// fetch that stops at page 40 of 94 therefore leaves an unreadable directory
/// rather than a comic missing its second half — and `finish()` will not write
/// the marker until every page is actually there.
public final class PageDownload {

    private let directory: URL
    private let images: [String]
    private let fileManager = FileManager.default

    /// - Parameter directory: the issue's own folder, `comics/<issue id>`.
    public init(directory: URL, images: [String]) throws {
        self.directory = directory
        self.images = images
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var pageCount: Int { images.count }

    /// What page `n` is called on disk. One-based, matching how the site and a
    /// reader both count.
    ///
    /// Zero-padded to four digits, which covers anything the site holds and
    /// makes the folder list in reading order — worth a great deal the first
    /// time you look inside one. `PageManifest.naturalLess` would sort these
    /// correctly unpadded too; this is for the human.
    ///
    /// The extension comes from the address, and only when it is one this app
    /// recognises as a page: `UnpackedReader` finds pages by extension, so a
    /// file saved as `.php` or with no extension at all would be invisible to
    /// the reader even though the bytes are a perfectly good JPEG.
    public func name(page: Int) -> String {
        let ext = Self.extension(of: images[page - 1])
        return String(format: "%04d.%@", page, ext)
    }

    static func `extension`(of address: String) -> String {
        let path = URL(string: address)?.pathExtension.lowercased() ?? ""
        return PageManifest.imageExtensions.contains(path) ? path : "jpg"
    }

    private func url(page: Int) -> URL {
        directory.appendingPathComponent(name(page: page))
    }

    /// The address to fetch for page `n`.
    public func address(page: Int) -> String { images[page - 1] }

    /// Whether this page is already on disk from an earlier attempt.
    ///
    /// A download interrupted at page 60 of 200 should cost the reader — and
    /// the site — sixty requests less the second time. Trustworthy because
    /// `write` renames a complete temporary file into place, so a file that
    /// exists is a file that finished.
    public func has(page: Int) -> Bool {
        fileManager.fileExists(atPath: url(page: page).path)
    }

    /// Writes one page.
    ///
    /// Through a temporary file and an atomic rename, so an interruption
    /// leaves either nothing or a whole page — never a truncated one that
    /// `has` would then skip for ever.
    public func write(_ data: Data, page: Int) throws {
        guard !data.isEmpty else {
            throw PageFetchError.pageFailed(page: page, reason: "no bytes")
        }
        guard ImageBytes.looksLikeImage(data) else {
            // Named for what it most likely is. The site answers a request it
            // does not like with a page of HTML and a 200.
            throw PageFetchError.pageFailed(
                page: page, reason: "the server sent something that is not an image")
        }
        let destination = url(page: page)
        let temporary = directory.appendingPathComponent(".\(name(page: page)).part")
        try? fileManager.removeItem(at: temporary)
        try data.write(to: temporary)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporary, to: destination)
    }

    /// Marks the directory complete and reports what it holds.
    ///
    /// Refuses unless every page is present, because the marker is what tells
    /// the rest of the app this is a whole comic.
    ///
    /// - Parameter absentFromSource: pages the source itself does not have.
    ///   Not the same thing as a page that failed to arrive, and the
    ///   difference is the whole point of this parameter: a page the site is
    ///   missing will never arrive however many times it is asked for, so
    ///   refusing to finish would mean that comic could never be read at all.
    ///   A page that merely failed is still expected, and still refuses.
    ///
    ///   Stripovi.com has exactly this: its own page menu counts twenty pages
    ///   and its own markup links the eighteenth, and that file is not on the
    ///   server. Twenty-four pages of a twenty-five page comic is worth having;
    ///   nothing at all is not.
    @discardableResult
    public func finish(absentFromSource: Set<Int> = []) throws -> Int64 {
        guard pageCount > 0 else { throw PageFetchError.noPages }
        let expected = (1...pageCount).filter { !absentFromSource.contains($0) }
        let missing = expected.filter { !has(page: $0) }
        guard missing.isEmpty else {
            throw PageFetchError.pageFailed(
                page: missing[0],
                reason: "\(missing.count) of \(pageCount) pages did not arrive")
        }
        // Every page this comic will ever have is gone, so there is no comic —
        // and a marker written over an empty directory would claim otherwise.
        guard !expected.isEmpty else { throw PageFetchError.noPages }

        var total: Int64 = 0
        for page in expected {
            let size = (try? fileManager.attributesOfItem(atPath: url(page: page).path)[.size])
            total += Int64((size as? NSNumber)?.intValue ?? 0)
        }
        // Last, and only now.
        try Data().write(to: directory.appendingPathComponent(UnpackMarker.name))
        return total
    }

    /// The file a download is recorded against.
    ///
    /// Every other source records the archive it arrived in. There is no
    /// archive here, so the first page stands for the download — it is inside
    /// the directory, it exists exactly when the download succeeded, and
    /// `Store.downloadedFile` resolves it the same way.
    public var recordedFile: URL { url(page: 1) }
}
