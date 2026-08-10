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

    private var store: Store?

    init() { start() }

    private func start() {
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let store = try Store(path: support.appendingPathComponent("library.sqlite").path)
            self.store = store

            // First launch: ingest the topic page bundled with the app. This is
            // the same parser path the WebView import will use later.
            if store.issueCount == 0,
               let seed = Bundle.main.url(forResource: "seed", withExtension: "html"),
               let html = try? String(contentsOf: seed, encoding: .utf8) {
                let added = try store.ingest(html: html, source: "bundled seed")
                status = "imported \(added.issues) issues, \(added.mirrors) mirrors"
            } else if store.issueCount == 0 {
                status = "no seed bundled — import a page to begin"
            } else {
                status = "\(store.issueCount) issues in library"
            }
            issueCount = store.issueCount
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
            status = "\(store.issueCount) issues in library"
            search(query)
            return report
        } catch {
            status = "import failed: \(error)"
            return nil
        }
    }

    func mirrors(for issue: StoredIssue) -> [MirrorLink] {
        (try? store?.mirrors(forIssue: issue.id)) as? [MirrorLink] ?? []
    }
}
