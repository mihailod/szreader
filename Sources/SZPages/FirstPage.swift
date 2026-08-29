import C7z
import CoreGraphics
import CUnrar
import Foundation

/// Page one of a comic file, for something that only wants page one.
///
/// The reader opens a comic and then asks it for page after page, so
/// `ComicDocument` is built to make the *second* page cheap: RAR and 7z unpack
/// themselves once, up front, and every page after that is a file on disk.
/// That bargain is right for a reader and wrong for everything else. A Quick
/// Look thumbnail wants one page, once, from a file it will never open again —
/// and paying for a 300 MB unpack to draw a 64-point picture, inside an
/// extension with a few seconds to live and a fraction of an app's memory, is
/// not a slow version of the right answer. It is the wrong answer.
///
/// So this is the other path, and it is narrow on purpose: one page, decoded
/// at the size it will be shown, with nothing left behind.
///
/// The solid-archive argument that shapes `ComicDocument` is what makes this
/// possible rather than what stands in its way. Entry N costs everything ahead
/// of it, which is exactly why entry *zero* is the one entry a solid archive
/// gives up cheaply.
public enum FirstPage {

    /// Draws the first page of the comic at `url`, at most `maxPixelSize` on
    /// the long edge.
    ///
    /// `scratch` is a directory this may write into and is emptied before
    /// returning — the RAR and 7z paths go through the filesystem because
    /// that is the shape of both C APIs. Nil when the file holds no page, or
    /// is not a comic at all; a caller drawing a thumbnail wants a fallback
    /// icon for both, not an error to report.
    public static func render(of url: URL, maxPixelSize: Int,
                              scratch: URL) -> CGImage? {
        switch ArchiveKind.sniff(url) {
        case .zip:      return fromZip(url, maxPixelSize: maxPixelSize)
        case .rar:      return fromRar(url, maxPixelSize: maxPixelSize, scratch: scratch)
        case .sevenZip: return fromSevenZip(url, maxPixelSize: maxPixelSize, scratch: scratch)
        case .pdf:      return PDFComic(fileURL: url)?.image(0, maxPixelSize: maxPixelSize)
        case .unknown:  return nil
        }
    }

    /// Zip needs none of this machinery.
    ///
    /// `ZipReader` memory-maps the file and inflates one entry at a time, so
    /// the cheap path was always there — and because listing is cheap too,
    /// this is the one format where the page drawn is the page `PageManifest`
    /// says comes first, rather than whichever image the archive happens to
    /// store first.
    private static func fromZip(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let reader = try? ZipReader(url: url),
              let first = try? reader.pageNames().first,
              let data = try? reader.data(for: first) else { return nil }
        return PageRenderer.downsample(data: data, maxPixelSize: maxPixelSize)
    }

    private static func fromRar(_ url: URL, maxPixelSize: Int, scratch: URL) -> CGImage? {
        extracted(into: scratch) { directory, name, capacity in
            szunrar_extract_first_image(url.path, directory, name, capacity)
        }
        .flatMap { PageRenderer.downsample(data: $0, maxPixelSize: maxPixelSize) }
    }

    private static func fromSevenZip(_ url: URL, maxPixelSize: Int, scratch: URL) -> CGImage? {
        extracted(into: scratch) { directory, name, capacity in
            sz7z_extract_first_image(url.path, directory, name, capacity)
        }
        .flatMap { PageRenderer.downsample(data: $0, maxPixelSize: maxPixelSize) }
    }

    /// Longest entry name either shim will hand back.
    ///
    /// Both refuse rather than truncate when a name will not fit, so this is a
    /// limit on what can be thumbnailed, not a buffer that can be overrun. A
    /// kilobyte is far past any real scan's filename.
    private static let nameCapacity = 1024

    /// Runs one of the two extract-a-single-entry shims and reads back what it
    /// wrote.
    ///
    /// The scratch directory is removed on every exit, success or not. It
    /// holds one page for the length of one decode; leaving it behind would
    /// mean a thumbnail cache of full-size scans accumulating somewhere nobody
    /// looks, which is the cost this whole file exists to avoid.
    private static func extracted(
        into scratch: URL,
        _ extract: (_ directory: String, _ name: UnsafeMutablePointer<CChar>,
                    _ capacity: Int) -> Int32
    ) -> Data? {
        let fm = FileManager.default
        try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        var name = [CChar](repeating: 0, count: nameCapacity)
        let code = extract(scratch.path, &name, nameCapacity)
        guard code == 0 else { return nil }

        let entry = String(decoding: name.prefix(while: { $0 != 0 })
                               .map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !entry.isEmpty else { return nil }
        return try? Data(contentsOf: scratch.appendingPathComponent(entry),
                         options: .mappedIfSafe)
    }
}
