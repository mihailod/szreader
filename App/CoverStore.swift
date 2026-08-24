import CryptoKit
import Foundation
import ImageIO
import SZKit
import UIKit

/// Decoded cover art, cached in memory and on disk.
///
/// `AsyncImage` was not enough for three reasons, all of which showed up as
/// covers "reloading":
///
///  * it is tied to view identity, so switching grid↔list destroys every image
///    view and re-issues every request;
///  * `URLCache` stores the *bytes*, so each redisplay still re-decodes the
///    JPEG and flashes a placeholder first;
///  * the greyed-out variant was produced by a live `.saturation(0)` filter,
///    re-applied on the GPU for every visible cell on every render.
///
/// This caches the decoded image in both variants, so a redisplay is a
/// dictionary lookup and the greyscale is computed once per cover, ever.
final class CoverStore: @unchecked Sendable {

    static let shared = CoverStore()

    /// Where page-derived covers live. Set once the library is open, because
    /// the path depends on the app container and must not be remembered
    /// across launches.
    nonisolated(unsafe) static var libraryPaths: LibraryPaths?

    /// Told about a cover URL that turned out not to be a cover.
    ///
    /// The shelf is the only place that ever finds this out, and it finds out
    /// for free: it fetches every cover it draws, so a host that has dropped
    /// the image answers here first. Reporting it is what lets the library
    /// stop treating the issue as one that already has artwork — otherwise the
    /// empty frame is permanent, because every query that looks for work to do
    /// sees a URL and moves on.
    ///
    /// Set when the library opens, alongside `libraryPaths`.
    nonisolated(unsafe) static var reportDeadCover: (@Sendable (String) -> Void)?

    private let memory = NSCache<NSString, UIImage>()

    /// Which covers carry no colour of their own.
    ///
    /// Its own cache because `memory` is typed to images, and its own entry
    /// rather than a property on one because the answer outlives any
    /// particular decode — `NSCache` evicts pictures freely, and re-deciding
    /// this while scrolling would mean re-drawing the picture to do it.
    ///
    /// Computed where the colour variant is stored, so every path that
    /// produces a cover answers it once, as a by-product of work already
    /// being done. See `CoverColour`.
    private let colourCast = NSCache<NSString, NSNumber>()
    private let directory: URL
    private let session: URLSession
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// One in-flight fetch per URL, however many cells ask for it.
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Covers are ~150x200, so both variants of one cover cost ~240 KB
        // decoded. This holds a few hundred without pressure.
        memory.countLimit = 800
        memory.totalCostLimit = 96 << 20

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        // The same string every other request in the app sends. Left unset,
        // URLSession fills in CFNetwork's default — which names the app and
        // the OS build, and did so on the most frequent request the app makes:
        // one per cover, several per screen of shelf.
        config.httpAdditionalHeaders = ["User-Agent": UserAgent.browser]
        session = URLSession(configuration: config)
    }

    // MARK: - Lookup

    /// Synchronous cache hit, or nil. Called from `View.init` so a redisplay
    /// paints immediately instead of flashing a placeholder for one frame.
    func cached(_ url: String?, grayscale: Bool) -> UIImage? {
        guard let url else { return nil }
        return memory.object(forKey: key(url, grayscale) as NSString)
    }

    /// Cache, then disk, then network — and populate both variants whichever
    /// path it came from.
    func image(_ url: String?, grayscale: Bool) async -> UIImage? {
        guard let url else { return nil }
        if let hit = cached(url, grayscale: grayscale) { return hit }

        // Scoped rather than lock()/unlock(): the pair is unavailable from an
        // async context, because a lock held across a suspension parks a thread
        // of the cooperative pool. Nothing here awaits inside the lock — the
        // scoped form is what makes that structural instead of a promise.
        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inFlight[url] { return existing }
            let started = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.fetchAndDecode(url) ?? nil
            }
            inFlight[url] = started
            return started
        }

        let produced = await task.value
        lock.withLock { inFlight[url] = nil }
        if let hit = cached(url, grayscale: grayscale) { return hit }

        // Storing is not keeping. `NSCache` evicts whenever it likes, so
        // asking it for something put there a moment ago can come back empty
        // — and this used to return that as the answer, which reads as "there
        // is no cover" when it means "the cache dropped it". A caller that
        // tells those apart on screen would call a perfectly good cover
        // missing, so the decoded image is the fallback.
        guard let produced else { return nil }
        return grayscale ? (desaturate(produced) ?? produced) : produced
    }

    // MARK: - Loading

    private func fetchAndDecode(_ url: String) async -> UIImage? {
        // One cover out of a sheet of six. The sheet is fetched and cached
        // like any other image — under its own URL — so six tiles cost one
        // download between them, and the crop happens once per tile.
        if let tile = CoverTile(reference: url) {
            guard let sheet = await image(tile.sheet, grayscale: false),
                  let cropped = Self.crop(sheet, to: tile) else { return nil }
            store(cropped, url: url, grayscale: false)
            if let gray = desaturate(cropped) { store(gray, url: url, grayscale: true) }
            return cropped
        }
        return await fetchAndDecodeWhole(url)
    }

    /// The tile's rectangle, in the sheet's own pixels.
    ///
    /// Integer division deliberately: a sheet whose width does not divide by
    /// three leaves a column of at most two pixels at the right edge, which is
    /// invisible, where rounding up would read past the end.
    private static func crop(_ sheet: UIImage, to tile: CoverTile) -> UIImage? {
        guard let cg = sheet.cgImage else { return nil }
        let width = cg.width / tile.columns
        let height = cg.height / tile.rows
        guard width > 0, height > 0 else { return nil }
        let rect = CGRect(x: width * tile.column, y: height * tile.row,
                          width: width, height: height)
        guard let cut = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cut, scale: sheet.scale, orientation: sheet.imageOrientation)
    }

    private func fetchAndDecodeWhole(_ url: String) async -> UIImage? {
        // A cover taken from the comic's own first page: already on disk in
        // the library, and nothing to fetch or cache a second time.
        if let issueID = Library.coverIssueID(reference: url) {
            guard let root = Self.libraryPaths,
                  let data = try? Data(contentsOf: root.coverFile(forIssue: issueID)),
                  let page = UIImage(data: data) else { return nil }
            let decoded = page.preparingForDisplay() ?? page
            store(decoded, url: url, grayscale: false)
            if let gray = desaturate(decoded) { store(gray, url: url, grayscale: true) }
            return decoded
        }

        let file = directory.appendingPathComponent(digest(url))

        // Anything cached that no longer decodes is thrown away rather than
        // served: earlier builds wrote whatever came back to this directory,
        // status and all, so a library that has been running a while has
        // "not found" pages sitting in it under a cover's name. Kept, they
        // would answer the question for ever and the fetch below — the only
        // thing that can tell the shelf the cover is gone — would never run.
        var data = try? Data(contentsOf: file)
        if let cached = data, Self.decode(cached) == nil {
            try? FileManager.default.removeItem(at: file)
            data = nil
        }
        if data == nil, let remote = URL(string: url) {
            data = await fetch(remote, to: file, reportingAs: url)
        }
        guard let data, let color = Self.decode(data) else { return nil }

        // Force the decode now, off the main thread, rather than lazily at
        // draw time on the first scroll.
        let decoded = color.preparingForDisplay() ?? color
        store(decoded, url: url, grayscale: false)
        if let gray = desaturate(decoded) { store(gray, url: url, grayscale: true) }
        return decoded
    }

    /// Fetches a cover, and says so when what came back is not one.
    ///
    /// The status used to be ignored entirely: `data(from:)` hands back a
    /// "not found" page as contentedly as a JPEG, and that page was then
    /// written into the cache as though it were artwork. `CoverGuess.isImage`
    /// is the same test the catalogue backfill applies to a guessed URL, which
    /// is the right one here too — the question is identical.
    /// `reportingAs` is the string the library stores, which is what it has to
    /// be told — `URL` round-trips most of them unchanged and would quietly
    /// re-encode the rest into something no row holds.
    private func fetch(_ remote: URL, to file: URL, reportingAs key: String) async -> Data? {
        guard let (data, response) = try? await session.data(from: remote) else { return nil }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        guard CoverGuess.isImage(status: status,
                                 contentType: http?.value(forHTTPHeaderField: "Content-Type"),
                                 body: data) else {
            // Only a definite answer condemns a cover. Nothing clears the dead
            // mark once it is set, so a host that is rate-limiting or having a
            // moment would otherwise blank artwork permanently over an answer
            // that was never about the image — and a shelf that loads six
            // hundred covers at once is exactly what provokes a 429.
            if Self.isFinal(status) { Self.reportDeadCover?(key) }
            return nil
        }
        try? data.write(to: file, options: .atomic)
        return data
    }

    /// Whether a status is the server's last word on this URL.
    ///
    /// A 200 that was not an image counts: the server answered, and what it
    /// has there is not artwork. So does anything in the 4xx range except the
    /// two that mean "not now" — 408 and 429.
    private static func isFinal(_ status: Int) -> Bool {
        if status == 200 { return true }
        if status == 408 || status == 429 { return false }
        return (400..<500).contains(status)
    }

    /// The largest a cover is ever drawn.
    ///
    /// A grid tile is about 150–220pt wide, so 600px covers the tallest of
    /// them at 3x with room over. Matches what `Library.captureCover` writes
    /// for a cover taken from a comic's own first page, so both routes to a
    /// cover produce artwork of the same order.
    private static let maxCoverPixels = 600

    /// Decodes a cover no larger than it will ever be drawn.
    ///
    /// The forum's covers are thumbnails already, and the cache was sized for
    /// them: the note above `countLimit` reckons 240 KB for both variants of
    /// one cover. RetroSpec's are the issue's own first page at 1024x1447,
    /// which is 5.9 MB decoded and 11.8 MB for the pair — so eight of them
    /// filled a cache meant to hold hundreds, and it spent the whole scroll
    /// evicting. Downsampling at decode time puts them back inside the
    /// assumption instead of raising a limit to accommodate artwork nothing
    /// ever draws at that size.
    ///
    /// Only ever downwards: a source smaller than the cap is decoded as-is,
    /// so the forum's covers are untouched by this.
    static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return UIImage(data: data) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard max(width, height) > maxCoverPixels else { return UIImage(data: data) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxCoverPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }

    /// Computed once per cover and cached, instead of a live GPU filter on
    /// every render of every visible cell.
    private func desaturate(_ image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image),
              let filter = CIFilter(name: "CIPhotoEffectMono") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage,
              let cg = ciContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    private func store(_ image: UIImage, url: String, grayscale: Bool) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memory.setObject(image, forKey: key(url, grayscale) as NSString, cost: cost)
        // Only the colour variant can answer this — the grey one is grey by
        // construction and would say every cover in the library is colourless.
        if !grayscale, colourCast.object(forKey: url as NSString) == nil,
           let cg = image.cgImage {
            colourCast.setObject(NSNumber(value: CoverColour.isMonochrome(cg)),
                                 forKey: url as NSString)
        }
    }

    /// Whether this cover is grey enough that showing it in colour says
    /// nothing.
    ///
    /// Answers false until the colour variant has been through `store`, which
    /// is the honest default: unknown artwork gets the ordinary treatment
    /// rather than a badge about a picture nobody has looked at yet.
    func isMonochrome(_ url: String?) -> Bool {
        guard let url else { return false }
        return colourCast.object(forKey: url as NSString)?.boolValue ?? false
    }

    // MARK: - Keys

    private func key(_ url: String, _ grayscale: Bool) -> String {
        grayscale ? url + "#gray" : url
    }

    private func digest(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined() + ".img"
    }

    /// Bytes held by the on-disk cover cache.
    var diskUsage: Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileAllocatedSizeKey]) else { return 0 }
        return files.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileAllocatedSizeKey]))?
                .fileAllocatedSize ?? 0)
        }
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
