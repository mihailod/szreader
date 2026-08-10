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
            library = Library(store: store,
                              paths: try LibraryPaths.standard(),
                              transport: ThrottledTransport(URLSessionTransport(),
                                                            minInterval: 1.5),
                              downloader: URLSessionDownloader())

            #if DEBUG
            seedFromSavedPages(into: store)
            #endif

            issueCount = store.issueCount
            downloadedCount = store.downloadedCount
            diskUsage = library?.diskUsage ?? 0
            search("")
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
                ? try store.recent(limit: 200)
                : try store.search(text, limit: 200)
        } catch {
            status = "search failed: \(error)"
        }
    }

    /// Ingests a page captured from the in-app browser, then refreshes the shelf.
    #if DEBUG
    /// Keeps the raw HTML of the last import, for diagnosing a page that
    /// parses oddly.
    ///
    /// Parsing a forum page is guesswork until you can see the markup: cover
    /// matching for the scanlations failed twice against markup that was
    /// inferred rather than read. Only the last page is kept, so this cannot
    /// grow. Debug-only — a release build never writes it.
    private func dumpForDiagnosis(_ html: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else { return }
        try? html.write(to: docs.appendingPathComponent("last-import.html"),
                        atomically: true, encoding: .utf8)
    }
    #endif

    func importPage(html: String) -> ImportReport? {
        #if DEBUG
        dumpForDiagnosis(html)
        #endif
        guard let store else { return nil }
        do {
            let report = try store.importPage(html: html, source: "webview import")
            refresh(note: report.isEmpty
                    ? "imported nothing new"
                    : "imported \(report.issues) issue\(report.issues == 1 ? "" : "s")")
            search(query)
            return report
        } catch {
            status = "import failed: \(error)"
            return nil
        }
    }

    /// Fetches the archive: resolve a mirror, download, decrypt if needed,
    /// verify it is really an archive. Falls through to the next mirror when
    /// one is dead.
    func download(_ issue: StoredIssue) {
        guard let library, !downloading.contains(issue.id) else { return }
        downloading.insert(issue.id)
        status = "downloading “\(issue.title ?? issue.code ?? "issue")”…"
        Task { [weak self] in
            do {
                let outcome = try await library.fetch(issueID: issue.id)
                await MainActor.run {
                    self?.downloading.remove(issue.id)
                    let mb = Double(outcome.bytes) / 1_048_576
                    self?.refresh(note: String(format: "downloaded %.1f MB (%@)",
                                               mb, outcome.kind.rawValue))
                }
            } catch {
                await MainActor.run {
                    self?.downloading.remove(issue.id)
                    self?.status = "download failed: \(error)"
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
