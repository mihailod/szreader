import Foundation
import SwiftUI
import SZKit

@main
struct SZReaderApp: App {
    @StateObject private var model = AppModel()

    init() {
        // AsyncImage goes through URLSession.shared -> URLCache.shared, whose
        // iOS default disk budget (~10 MB) barely holds one page of covers and
        // is shared with everything else. The covers are small and the server
        // sends max-age=604800, so a generous cache means they are fetched
        // once and then come from disk on every later launch.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20,
                                   diskCapacity: 512 << 20,
                                   directory: nil)
    }

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model)
        }
    }
}

/// Owns the store and the one-time seed import.
@MainActor
final class AppModel: ObservableObject {

    @Published var results: [StoredIssue] = []
    @Published var query = ""
    @Published var status = "starting…"
    @Published var issueCount = 0
    @Published var downloadedCount = 0
    /// 0...1 per issue being fetched, for the progress bar.
    @Published var progress: [Int: Double] = [:]
    /// Show only comics whose archive is actually on disk.
    @AppStorage("downloadedOnly") var downloadedOnly = false {
        didSet { search(query) }
    }
    /// A failure worth interrupting for. The status line is too easy to miss,
    /// and a download that silently does nothing looks like a broken app.
    @Published var failure: String?

    /// The comic currently open in the reader.
    @Published var reading: OpenComic?
    /// Issue whose archive is being unpacked, so the cover can show a spinner.
    @Published var opening: Int?
    /// True while filenames are being probed to name untitled issues.
    @Published var resolving = false

    /// Kept so the backfill uses the same throttled transport as downloads.
    private var transport: Transport?
    @Published var diskUsage: Int64 = 0


    /// Issues currently being fetched, so the row can show progress instead of
    /// a Download button.
    @Published var downloading: Set<Int> = []

    private var store: Store?
    private var library: Library?

    init() { start() }

    private func start() {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let store = try Store(path: support.appendingPathComponent("library.sqlite").path)
            self.store = store

            // Deliberately blank: the counts are shown on the left and the
            // empty-library case is covered by the empty state view.
            status = ""
            // Real downloads: throttled because these are third-party file
            // hosts that rate-limit, and a burst is what gets an IP blocked.
            // One throttled transport for downloads and probes alike: these
            // are third-party hosts that rate-limit, and a burst is what gets
            // an IP blocked.
            let transport = ThrottledTransport(URLSessionTransport(), minInterval: 1.5)
            self.transport = transport
            library = Library(store: store,
                              paths: try LibraryPaths.standard(),
                              transport: transport,
                              downloader: URLSessionDownloader())

            #if DEBUG
            seedFromSavedPages(into: store)
            #endif

            issueCount = store.issueCount
            downloadedCount = store.downloadedCount
            diskUsage = library?.diskUsage ?? 0
            search("")
            resolveTitles()
        } catch {
            status = "failed: \(error)"
        }
    }

    func search(_ text: String) {
        guard let store else { return }
        query = text
        do {
            // Empty query lists the start of the library rather than nothing,
            // so the shelf is never blank on launch.
            results = text.trimmingCharacters(in: .whitespaces).isEmpty
                ? try store.recent(limit: 200, downloadedOnly: downloadedOnly)
                : try store.search(text, limit: 200, downloadedOnly: downloadedOnly)
        } catch {
            status = "search failed: \(error)"
        }
    }

    #if DEBUG
    /// Imports the saved topic pages so the simulator has a real library.
    ///
    /// The simulator cannot log in to the forum, so without this the only way
    /// to look at the app with content in it is on the device. Debug-only, and
    /// gated on a path handed in at launch, so it cannot reach a real build.
    ///
    /// Skipped once the library has anything in it, so it never fights with a
    /// genuine import.
    private func seedFromSavedPages(into store: Store) {
        guard store.issueCount == 0,
              let dir = ProcessInfo.processInfo.environment["SZ_SEED_PAGES"],
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir)
        else { return }

        var pages = 0
        for name in names.sorted() where name.hasSuffix(".html") {
            guard let html = try? String(contentsOfFile: dir + "/" + name,
                                         encoding: .utf8) else { continue }
            if (try? store.importPage(html: html, source: "seed: " + name)) != nil { pages += 1 }
        }
        if pages > 0 { status = "seeded \(pages) saved page\(pages == 1 ? "" : "s")" }
    }
    #endif

    /// Keeps the raw HTML of the last import, for diagnosing a page that
    /// parses oddly.
    ///
    /// Parsing a forum page is guesswork until you can see the markup: cover
    /// matching for the scanlations failed twice against markup that was
    /// inferred rather than read. Only the last page is kept, so this cannot
    /// grow.
    private func dumpForDiagnosis(_ html: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return }
        try? html.write(to: docs.appendingPathComponent("last-import.html"),
                        atomically: true, encoding: .utf8)
    }

    /// Ingests a page captured from the in-app browser, then refreshes the shelf.
    func importPage(html: String) throws -> ImportReport {
        dumpForDiagnosis(html)
        guard let store else { throw ImportFailure.notReady }
        do {
            let report = try store.importPage(html: html, source: "webview import")
            refresh(note: report.isEmpty
                    ? "imported nothing new"
                    : "imported \(report.issues) issue\(report.issues == 1 ? "" : "s")")
            search(query)
            // A freshly imported page may be all codes and no titles.
            resolveTitles()
            return report
        } catch {
            status = "import failed: \(Library.reason(error))"
            throw error
        }
    }

    /// A comic handed to the reader. Identifiable so it can drive a cover.
    struct OpenComic: Identifiable {
        let id: Int
        let document: ComicDocument
        let title: String
    }

    enum ImportFailure: Error, CustomStringConvertible {
        case notReady
        var description: String { "the library is still opening — try again in a moment" }
    }

    /// Opens a downloaded comic in the reader.
    ///
    /// Unpacking happens off the main thread: a solid RAR of 80 MB takes long
    /// enough that doing it inline freezes the shelf mid-tap.
    func read(_ issue: StoredIssue) {
        guard let library, issue.isDownloaded, opening == nil else { return }
        opening = issue.id
        let name = issue.title ?? issue.code ?? "Comic"
        Task { [weak self] in
            do {
                let document = try library.document(forIssue: issue.id)
                await MainActor.run {
                    self?.opening = nil
                    self?.reading = OpenComic(id: issue.id, document: document, title: name)
                }
            } catch {
                await MainActor.run {
                    self?.opening = nil
                    self?.failure = "“\(name)” could not be opened.\n\n"
                        + Library.reason(error)
                }
            }
        }
    }

    /// Names issues the forum post never named.
    ///
    /// Some topics list only a code — Mister No's post is 120 lines of
    /// `MN_LMS_511` and a link, with no titles anywhere on the page. The title
    /// is in the file itself though ("LMS - 511 - Mister No - DIJAMANTSKA
    /// KLOPKA"), so probing the mirror for its filename recovers it without
    /// downloading anything.
    ///
    /// Runs in batches and reports as it goes, because probing is throttled and
    /// a large import takes minutes. Results are permanent, so an interrupted
    /// run simply resumes next launch.
    func resolveTitles() {
        guard let store, let transport, !resolving else { return }
        // Fixed denominator: the work in front of us when the run started, so
        // the readout counts up instead of chasing a moving target.
        let total = store.untitledIssueCount
        guard total > 0 else { return }

        resolving = true
        // Posted before the first probe, not after it. A batch is five probes
        // at 1.5s apiece, so waiting for one to finish left the shelf silent
        // for the better part of ten seconds while work was already underway.
        status = "Resolving names: 0/\(total)"

        Task { [weak self] in
            var named = 0
            var remaining = total
            while remaining > 0 {
                // Small batches: at 1.5s a probe this refreshes the shelf every
                // few seconds rather than every half minute.
                guard let batch = try? await store.backfillTitles(via: transport, limit: 5),
                      batch.probed > 0 else { break }
                named += batch.titled
                // Stop when a batch makes no dent. A probe that yields no
                // filename leaves the mirror unresolved, so looping on the
                // count alone would re-probe the same rows for ever and hammer
                // the host.
                let now = store.untitledIssueCount
                guard now < remaining else { break }
                remaining = now
                await MainActor.run {
                    self?.status = "Resolving names: \(total - remaining)/\(total)"
                    self?.search(self?.query ?? "")
                }
            }
            await MainActor.run {
                self?.resolving = false
                self?.refresh(note: named > 0
                              ? "named \(named) issue\(named == 1 ? "" : "s")"
                              : "")
            }
        }
    }

    /// Fetches the archive: resolve a mirror, download, decrypt if needed,
    /// verify it is really an archive. Falls through to the next mirror when
    /// one is dead.
    func download(_ issue: StoredIssue) {
        guard let library, !downloading.contains(issue.id) else { return }
        downloading.insert(issue.id)
        progress[issue.id] = 0
        status = "downloading “\(issue.title ?? issue.code ?? "issue")”…"
        Task { [weak self] in
            do {
                let outcome = try await library.fetch(issueID: issue.id) { p in
                    // expected is -1 when the server sends no length; with no
                    // total there is no fraction to show.
                    guard p.expected > 0 else { return }
                    let fraction = Double(p.received) / Double(p.expected)
                    Task { @MainActor [weak self] in self?.progress[issue.id] = fraction }
                }
                await MainActor.run {
                    self?.downloading.remove(issue.id)
                    self?.progress[issue.id] = nil
                    let mb = Double(outcome.bytes) / 1_048_576
                    // refresh() re-runs the search, so the row rebuilds with
                    // isDownloaded true and the cover turns colour at once.
                    self?.refresh(note: String(format: "downloaded %.1f MB (%@)",
                                               mb, outcome.kind.rawValue))
                }
            } catch {
                await MainActor.run {
                    self?.downloading.remove(issue.id)
                    self?.progress[issue.id] = nil
                    let name = issue.title ?? issue.code ?? "issue"
                    self?.status = "download failed"
                    // Summarised, not dumped: interpolating the raw error
                    // filled the alert with NSError userInfo and buried the
                    // one sentence that says what went wrong.
                    self?.failure = "“\(name)” could not be downloaded.\n\n"
                        + Library.reason(error)
                }
            }
        }
    }

    /// Drops the archive but keeps the metadata, so it can be fetched again
    /// without spending another Like on a re-import.
    func deleteDownload(_ issue: StoredIssue) {
        guard let store else { return }
        do {
            removeFromDisk(try store.deleteDownload(issueID: issue.id))
            refresh(note: "removed download for “\(issue.title ?? issue.code ?? "issue")”")
        } catch {
            status = "delete failed: \(error)"
        }
    }

    /// Removes one issue, plus its downloaded archive and unpacked pages.
    func delete(_ issue: StoredIssue) {
        guard let store else { return }
        do {
            let orphan = try store.delete(issueID: issue.id)
            removeFromDisk(orphan)
            refresh(note: "deleted “\(issue.title ?? issue.code ?? "issue")”")
        } catch {
            status = "delete failed: \(error)"
        }
    }

    /// Clears every download, leaving the catalogue intact — covers grey out
    /// again and each comic can be re-fetched without a re-import.
    func removeAllDownloads() {
        guard let store else { return }
        do {
            let files = try store.deleteAllDownloads()
            for file in files { removeFromDisk(file) }
            refresh(note: "removed \(files.count) download\(files.count == 1 ? "" : "s")")
        } catch {
            status = "remove failed: \(error)"
        }
    }

    func deleteEverything() {
        guard let store else { return }
        do {
            let count = store.issueCount
            for file in try store.deleteAll() { removeFromDisk(file) }
            refresh(note: "deleted all \(count) issues")
        } catch {
            status = "delete failed: \(error)"
        }
    }

    /// The archive and the directory it was unpacked into. Removing the row
    /// without the bytes would silently keep the disk full.
    private func removeFromDisk(_ file: URL?) {
        guard let file else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: file)
        try? fm.removeItem(at: file.deletingLastPathComponent())
    }

    private func refresh(note: String) {
        issueCount = store?.issueCount ?? 0
        downloadedCount = store?.downloadedCount ?? 0
        diskUsage = library?.diskUsage ?? 0
        search(query)
        status = note
    }

    func mirrors(for issue: StoredIssue) -> [MirrorLink] {
        (try? store?.mirrors(forIssue: issue.id)) as? [MirrorLink] ?? []
    }
}
