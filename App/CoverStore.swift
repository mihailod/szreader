import CryptoKit
import Foundation
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

    private let memory = NSCache<NSString, UIImage>()
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

        lock.lock()
        let existing = inFlight[url]
        let task: Task<UIImage?, Never>
        if let existing {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.fetchAndDecode(url) ?? nil
            }
            inFlight[url] = task
        }
        lock.unlock()

        _ = await task.value
        lock.lock(); inFlight[url] = nil; lock.unlock()
        return cached(url, grayscale: grayscale)
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

        var data = try? Data(contentsOf: file)
        if data == nil, let remote = URL(string: url) {
            data = try? await session.data(from: remote).0
            if let data { try? data.write(to: file, options: .atomic) }
        }
        guard let data, let color = UIImage(data: data) else { return nil }

        // Force the decode now, off the main thread, rather than lazily at
        // draw time on the first scroll.
        let decoded = color.preparingForDisplay() ?? color
        store(decoded, url: url, grayscale: false)
        if let gray = desaturate(decoded) { store(gray, url: url, grayscale: true) }
        return decoded
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
