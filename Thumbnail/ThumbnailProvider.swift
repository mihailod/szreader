import CoreGraphics
import Foundation
import OSLog
import QuickLookThumbnailing
import SZKit

/// Draws the cover of a comic file for the Files app.
///
/// Why this exists at all: iOS has no thumbnailer for comic archives, so a
/// `.cbz` in Files falls back to a static document icon unless some installed
/// app supplies one. Any app can — which means the picture a reader sees of
/// their own comics belongs to whichever reader they happen to have installed,
/// and goes away when they delete it. StreamZine declares `Owner` on these
/// three types; drawing them is the other half of that claim.
///
/// The whole of the work is `FirstPage`, and the reason it is a separate path
/// from `ComicDocument` is this class's budget. A thumbnail extension gets a
/// fraction of an app's memory and a few seconds before it is killed, and it
/// is asked again for every file the reader scrolls past. Opening a comic the
/// way the reader does — unpacking a RAR whole, because page two is coming —
/// would blow both limits on the first 300 MB file in the folder.
final class ThumbnailProvider: QLThumbnailProvider {

    /// There is no other way to see inside this.
    ///
    /// The extension is a process of its own, launched on demand by Quick Look
    /// and killed straight after. A failure in it reaches the reader as a
    /// blank tile and reaches the log as nothing at all — which is how the
    /// first version of this file failed, silently, past two rebuilds and a
    /// reboot. Kept rather than removed now that it works, because whatever
    /// goes wrong here next will be just as invisible.
    ///
    ///     xcrun simctl spawn booted log stream --level info \
    ///         --predicate 'subsystem == "com.mihailod.szreader.thumbnail"'
    private static let log = Logger(subsystem: "com.mihailod.szreader.thumbnail",
                                    category: "thumbnail")

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        // The file is handed over already readable in the ordinary case, but a
        // scoped URL costs nothing to ask for and fails as a missing file when
        // it is needed and not taken.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let readable = FileManager.default.isReadableFile(atPath: url.path)
        Self.log.info("asked \(url.lastPathComponent, privacy: .public) scoped=\(scoped) readable=\(readable) max=\(request.maximumSize.width)x\(request.maximumSize.height) scale=\(request.scale)")

        // Points to pixels: `maximumSize` is what the tile measures, `scale`
        // is the screen it is on. Decoding beyond that is memory spent on
        // detail no tile can show — the same bargain `PageRenderer` makes for
        // the reader, on a much tighter budget.
        let longest = max(request.maximumSize.width, request.maximumSize.height)
        let pixels = Int((longest * request.scale).rounded())

        // Its own directory under the extension's temp, because several of
        // these run at once — a folder of comics is a folder of simultaneous
        // requests — and two sharing a scratch would delete each other's page
        // mid-decode. `FirstPage` removes it before returning.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(UUID().uuidString)", isDirectory: true)

        guard let page = FirstPage.render(of: url, maxPixelSize: pixels,
                                          scratch: scratch) else {
            // No page in it, or not a comic. Reported as a failure rather than
            // an empty reply, which is what makes Quick Look fall back to the
            // document icon instead of drawing nothing at all.
            Self.log.error("no page from \(url.lastPathComponent, privacy: .public) at \(pixels)px")
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }

        let size = Self.fit(width: page.width, height: page.height,
                            into: request.maximumSize)
        Self.log.info("drew \(url.lastPathComponent, privacy: .public) page=\(page.width)x\(page.height) reply=\(size.width)x\(size.height)")
        // `drawing:` is written out rather than left to a trailing
        // closure, and that is not style. Quick Look offers two initialisers
        // that differ *only* in the arity of their block — this one, which
        // hands over a Core Graphics context, and `currentContextDrawing:`,
        // which sets up a UIKit one and passes nothing. Picking the wrong one
        // is not a compile error and not a runtime error either. It is a
        // blank thumbnail: `UIImage.draw(in:)` silently paints nothing when
        // there is no current UIKit context, which is exactly what this line
        // did in its first version, and what the Files app showed for it —
        // an empty rectangle of the right shape, with nothing in the log.
        //
        // Drawing through the context directly also means no flip: the block
        // is documented as Core Graphics' own coordinate system, and a
        // CGImage drawn into a CG context comes out upright. The upside-down
        // page is the UIKit hazard, and this variant does not have it.
        handler(QLThumbnailReply(contextSize: size, drawing: { context in
            context.draw(page, in: CGRect(origin: .zero, size: size))
            return true
        }), nil)
    }

    /// The page's own shape, as large as it can be drawn.
    ///
    /// Scans are not one shape: an album page, a magazine and a double-page
    /// spread differ enough that filling the requested box would visibly
    /// stretch a cover. The box is a maximum, and a reply may be smaller than
    /// it — so the aspect is kept and the tile takes the shape of the comic.
    static func fit(width: Int, height: Int, into box: CGSize) -> CGSize {
        guard width > 0, height > 0, box.width > 0, box.height > 0 else { return box }
        let scale = min(box.width / CGFloat(width), box.height / CGFloat(height))
        return CGSize(width: max(1, (CGFloat(width) * scale).rounded()),
                      height: max(1, (CGFloat(height) * scale).rounded()))
    }
}
