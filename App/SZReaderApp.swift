import SwiftUI
import SZKit

@main
struct SZReaderApp: App {
    @StateObject private var model = AppModel()

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

            status = store.issueCount == 0
                ? "empty — tap Import to add a topic page"
                : "\(store.issueCount) issues in library"
            // Real downloads: throttled because these are third-party file
            // hosts that rate-limit, and a burst is what gets an IP blocked.
            library = Library(store: store,
                              paths: try LibraryPaths.standard(),
                              transport: ThrottledTransport(URLSessionTransport(),
                                                            minInterval: 1.5),
                              downloader: URLSessionDownloader())

            issueCount = store.issueCount
            downloadedCount = store.downloadedCount
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
    func importPage(html: String) -> ImportReport? {
        guard let store else { return nil }
        do {
            let report = try store.importPage(html: html, source: "webview import")
            issueCount = store.issueCount
            downloadedCount = store.downloadedCount
            status = "\(store.issueCount) issues in library"
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
        search(query)
        status = note
    }

    func mirrors(for issue: StoredIssue) -> [MirrorLink] {
        (try? store?.mirrors(forIssue: issue.id)) as? [MirrorLink] ?? []
    }
}
