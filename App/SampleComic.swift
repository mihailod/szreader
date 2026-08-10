import CoreGraphics
import Foundation
import ImageIO
import SZKit
import UIKit

/// A generated comic, so the reader can be exercised without downloading
/// anything. It goes through exactly the same path a real archive does:
/// `ArchiveReader` -> `PageManifest` ordering -> `PageRenderer` downsampling.
enum SampleComic {

    /// Entry names are deliberately out of order and include the junk a real
    /// archive carries, so `PageManifest` has something to actually do.
    static func document() -> ComicDocument {
        var files: [String: Data] = [
            "__MACOSX/._p1.jpg": Data("junk".utf8),
            "Thumbs.db": Data("junk".utf8),
            "readme.txt": Data("not a page".utf8),
        ]
        for number in [10, 2, 1, 3, 4, 5, 6, 7, 8, 9] {
            files["pages/p\(number).jpg"] = render(number: number, of: 10)
        }
        // Force-try is fine here: the archive is built in memory just above.
        return try! ComicDocument(archive: InMemoryArchive(files: files))
    }

    /// A page-sized JPEG at real scan dimensions, so downsampling is doing
    /// genuine work rather than being a no-op.
    private static func render(number: Int, of total: Int) -> Data {
        let width = 1600, height = 2400
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        let image = renderer.image { ctx in
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            let hue = CGFloat(number) / CGFloat(total)
            UIColor(hue: hue, saturation: 0.25, brightness: 0.96, alpha: 1).setFill()
            ctx.fill(rect)

            UIColor(white: 0.1, alpha: 1).setStroke()
            let panel = rect.insetBy(dx: 90, dy: 120)
            let path = UIBezierPath(roundedRect: panel, cornerRadius: 18)
            path.lineWidth = 8
            path.stroke()

            let title = "PAGE \(number)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 190, weight: .heavy),
                .foregroundColor: UIColor(white: 0.12, alpha: 1),
            ]
            let size = title.size(withAttributes: attrs)
            title.draw(at: CGPoint(x: (CGFloat(width) - size.width) / 2,
                                   y: CGFloat(height) / 2 - size.height / 2),
                       withAttributes: attrs)

            let caption = "\(width)x\(height) — downsampled for this screen"
            let cAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 54, weight: .regular),
                .foregroundColor: UIColor(white: 0.35, alpha: 1),
            ]
            let cSize = caption.size(withAttributes: cAttrs)
            caption.draw(at: CGPoint(x: (CGFloat(width) - cSize.width) / 2,
                                     y: CGFloat(height) - 260),
                         withAttributes: cAttrs)
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }
}

/// Minimal in-memory `ArchiveReader`, used only by the sample.
struct InMemoryArchive: ArchiveReader {
    let files: [String: Data]
    func entries() throws -> [String] { Array(files.keys) }
    func data(for entry: String) throws -> Data {
        guard let d = files[entry] else { throw ArchiveError.entryNotFound(entry) }
        return d
    }
}
