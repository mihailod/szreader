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
    /// The last thing that happened, shown in the status bar.
    ///
    /// Clears itself after a while: it reports an event, and an event that
    /// finished two hours ago reads as current state. Each new message
    /// supersedes the previous one's timer, so a run of updates — the name
    /// resolver counting up, say — is never cut short halfway.
    @Published var status = "starting…" {
        didSet { scheduleStatusClear() }
    }

    /// How long a message stays on screen.
    private static let statusLifetime = Duration.seconds(30)

    /// Identifies the message a pending clear belongs to.
    private var statusGeneration = 0

    private func scheduleStatusClear() {
        guard !status.isEmpty else { return }
        statusGeneration += 1
        let generation = statusGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.statusLifetime)
            // A newer message has taken over; that one owns the timer now.
            guard let self, self.statusGeneration == generation else { return }
            self.status = ""
        }
    }
    @Published var issueCount = 0
    @Published var downloadedCount = 0
    /// 0...1 per issue being fetched, for the progress bar.
    @Published var progress: [Int: Double] = [:]
    /// Series the reader has narrowed to. Empty means every series.
    ///
    /// Persisted as newline-joined text: `AppStorage` cannot hold a Set, and a
    /// newline is the one separator a series name will never contain.
    @AppStorage("seriesFilter") private var seriesFilterRaw = "" {
        didSet { search(query) }
    }

    var selectedSeries: Set<String> {
        get { Set(seriesFilterRaw.split(separator: "\n").map(String.init)) }
        set { seriesFilterRaw = newValue.sorted().joined(separator: "\n") }
    }

    /// Publishers the reader has narrowed to. Empty means every publisher.
    @AppStorage("publisherFilter") private var publisherFilterRaw = "" {
        didSet { search(query) }
    }

    var selectedPublishers: Set<String> {
        get { Set(publisherFilterRaw.split(separator: "\n").map(String.init)) }
        set { publisherFilterRaw = newValue.sorted().joined(separator: "\n") }
    }

    /// Read-state switches. All on, or all off, means show everything —
    /// asking for every state is the same as not asking.
    @AppStorage("showUnread") var showUnread = false { didSet { search(query) } }
    @AppStorage("showReading") var showReading = false { didSet { search(query) } }
    @AppStorage("showRead") var showRead = false { didSet { search(query) } }

    var readStates: Set<ReadState> {
        var states: Set<ReadState> = []
        if showUnread { states.insert(.unread) }
        if showReading { states.insert(.reading) }
        if showRead { states.insert(.read) }
        return states
    }

    /// Heroes the reader has narrowed to. Empty means every hero.
    @AppStorage("heroFilter") private var heroFilterRaw = "" {
        didSet { search(query) }
    }

    var selectedHeroes: Set<String> {
        get { Set(heroFilterRaw.split(separator: "\n").map(String.init)) }
        set { heroFilterRaw = newValue.sorted().joined(separator: "\n") }
    }

    /// Every series in the library, for building the filter menu.
    @Published var availableSeries: [String] = []
    /// Every publisher in the library, likewise.
    @Published var availablePublishers: [String] = []
    /// Every hero in the library, in the spelling the rows hold.
    @Published var availableHeroes: [String] = []

    /// How the shelf is ordered. `imported` keeps the query's own order.
    @AppStorage("shelfSort") var sortOrder: ShelfSort = .imported {
        didSet { search(query) }
    }

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
    /// Free space on the volume the library lives on. Zero when it cannot be
    /// read, which the status bar treats as "say nothing".
    @Published var freeSpace: Int64 = 0


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
            let paths = try LibraryPaths.standard()
            // Covers taken from a comic's own first page live under the
            // library, so whoever loads covers needs to know where that is.
            CoverStore.libraryPaths = paths
            library = Library(store: store,
                              paths: paths,
                              transport: transport,
                              downloader: URLSessionDownloader())

            #if DEBUG
            seedFromSavedPages(into: store)
            #endif

            issueCount = store.issueCount
            downloadedCount = store.downloadedCount
            diskUsage = library?.diskUsage ?? 0
            freeSpace = Self.freeSpace()
            availableSeries = (try? store.editions()) ?? []
            availablePublishers = (try? store.publishers()) ?? []
            availableHeroes = (try? store.heroes()) ?? []
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
                // No cap: the grid and list are lazy, so only visible cells are
                // built, and a silent 200-row ceiling made a 613-issue library
                // look like it ended at 200.
                ? try store.recent(limit: nil, downloadedOnly: downloadedOnly,
                                   editions: selectedSeries,
                                   publishers: selectedPublishers,
                                   heroes: selectedHeroes,
                                   states: readStates)
                : try store.search(text, limit: nil, downloadedOnly: downloadedOnly,
                                   editions: selectedSeries,
                                   publishers: selectedPublishers,
                                   heroes: selectedHeroes,
                                   states: readStates)
            // Applied on top of the query, so the default costs nothing and
            // leaves insertion order when browsing and relevance when
            // searching — each view's own answer to what it was asked.
            if let comparator = StoredIssue.comparator(for: sortOrder) {
                results.sort(by: comparator)
            }
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
    /// A comic handed to the reader.
    ///
    /// The document arrives after the reader is already on screen: opening one
    /// means unpacking an archive, and making the shelf sit there for a second
    /// with a spinner on a cover feels like a tap that did nothing.
    struct OpenComic: Identifiable {
        let id: Int
        var document: ComicDocument?
        let title: String
        /// Where the reader stopped last time.
        let startPage: Int
    }

    enum ImportFailure: Error, CustomStringConvertible {
        case notReady
        var description: String { "the library is still opening — try again in a moment" }
    }

    /// Bytes free on the volume holding the library.
    ///
    /// `volumeAvailableCapacityForImportantUsage` rather than the plain free
    /// count: it reports what iOS will actually hand an app, since the system
    /// reclaims purgeable space on demand. The plain figure understates it,
    /// sometimes badly.
    static func freeSpace() -> Int64 {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first,
              let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return 0 }
        return Int64(capacity)
    }

    /// Opens a downloaded comic in the reader.
    ///
    /// Unpacking happens off the main thread: a solid RAR of 80 MB takes long
    /// enough that doing it inline freezes the shelf mid-tap.
    func read(_ issue: StoredIssue) {
        guard let library, issue.isDownloaded, reading == nil else { return }
        let name = issue.readerTitle
        let resumeAt = (try? store?.lastPage(forIssue: issue.id)) ?? 0

        // On screen straight away, holding nothing but a title and a place.
        // The reader shows its own progress until the pages arrive.
        reading = OpenComic(id: issue.id, document: nil, title: name, startPage: resumeAt)

        Task { @MainActor [weak self] in
            do {
                // Off the main actor: unpacking is the slow part, and the
                // reader has to stay responsive while it runs.
                let document = try await Task.detached(priority: .userInitiated) {
                    try library.document(forIssue: issue.id)
                }.value
                guard let self, self.reading?.id == issue.id else { return }
                self.reading?.document = document
            } catch {
                guard let self else { return }
                self.reading = nil
                self.failure = "“\(name)” could not be opened.\n\n" + Library.reason(error)
            }
        }
    }

    /// Turns one series on or off. Series are additive: several selected means
    /// "any of these", and the Downloaded filter narrows whatever is left.
    func toggleSeries(_ edition: String) {
        var chosen = selectedSeries
        if chosen.contains(edition) { chosen.remove(edition) } else { chosen.insert(edition) }
        selectedSeries = chosen
    }

    func togglePublisher(_ publisher: String) {
        var chosen = selectedPublishers
        if chosen.contains(publisher) { chosen.remove(publisher) } else { chosen.insert(publisher) }
        selectedPublishers = chosen
    }

    /// How much of the progress bar the transfer owns; the rest is unpacking.
    ///
    /// Unpacking is a fraction of the time on a fast connection and most of it
    /// on a slow archive, so any split is a guess. This one keeps the bar
    /// moving for the part that can be measured and leaves a visible remainder
    /// for the part that cannot.
    private static let transferShare = 0.9

    /// Records how far the reader got.
    ///
    /// Not routed through `refresh`: this fires on every page turn, and
    /// rebuilding the shelf underneath the reader for each one would be a
    /// great deal of work nobody can see.
    func rememberPlace(issueID: Int, page: Int) {
        try? store?.setLastPage(page, issueID: issueID)
    }

    /// Marks by id, for the reader — which knows what it has open but not the
    /// row it came from.
    func markRead(issueID: Int) {
        guard let store else { return }
        try? store.setRead(true, issueID: issueID)
        refresh(note: "marked as read")
    }

    /// Marks an issue read or unread and refreshes the shelf, so a row that no
    /// longer matches an active read filter leaves at once.
    func setRead(_ read: Bool, for issue: StoredIssue) {
        guard let store else { return }
        do {
            try store.setRead(read, issueID: issue.id)
            refresh(note: read ? "marked as read" : "marked as unread")
        } catch {
            status = "could not mark: \(Library.reason(error))"
        }
    }

    func toggleHero(_ hero: String) {
        var chosen = selectedHeroes
        if chosen.contains(hero) { chosen.remove(hero) } else { chosen.insert(hero) }
        selectedHeroes = chosen
    }

    func clearSeriesFilter() {
        showRead = false
        showUnread = false
        showReading = false
        selectedHeroes = []
        selectedSeries = []
        selectedPublishers = []
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
    /// Fills in what the forum page did not give: names for issues that
    /// arrived with only a code, and covers the catalogue has but the page
    /// did not link.
    ///
    /// The two are independent. Titles used to gate the whole run, so a page
    /// that names every issue — most of them do — returned before the covers
    /// were even looked at, and the artwork simply never arrived.
    func resolveTitles() {
        guard let store, let transport, !resolving else { return }
        // Fixed denominator: the work in front of us when the run started, so
        // the readout counts up instead of chasing a moving target.
        let total = store.untitledIssueCount
        guard total > 0 || store.coverlessIssueCount > 0 else { return }

        resolving = true
        // Posted before the first probe, not after it. A batch is five probes
        // at 1.5s apiece, so waiting for one to finish left the shelf silent
        // for the better part of ten seconds while work was already underway.
        if total > 0 { status = "Resolving names: 0/\(total)" }

        // Isolated to the main actor for its whole life, rather than a
        // free-floating task that reaches back for `self` through nested
        // `MainActor.run` blocks. Those reads of a weak, non-Sendable model
        // from concurrent code are a data race — the same shape as the one
        // that surfaced as "the library could not be written to" — and an
        // error under the Swift 6 language mode.
        //
        // Nothing is serialised onto the main thread by this: `backfillTitles`
        // is a nonisolated async function, so each await hops off and the
        // probing and database work still happen in the background.
        Task { @MainActor [weak self] in
            var named = 0
            var remaining = total
            while remaining > 0 {
                // Small batches: at 1.5s a probe this refreshes the shelf every
                // few seconds rather than every half minute.
                // Stop only when there is nothing left to ask. Batches that
                // yield no titles still make progress, because every mirror
                // they touch is marked as asked and drops out of the queue.
                //
                // This used to stop the moment a batch produced no titles,
                // which was the only defence against re-probing the same
                // mirrors for ever. The older pages carry long runs of links
                // with no filename behind them, so five duds in a row ended
                // the run and left every issue after them showing its code.
                guard let batch = try? await store.backfillTitles(via: transport, limit: 5),
                      batch.attempted > 0 else { break }
                named += batch.titled
                remaining = store.untitledIssueCount

                // Bound once per pass: if the model has gone, so has the shelf
                // this was updating.
                guard let self else { return }
                self.status = "Resolving names: \(total - remaining)/\(total)"
                self.search(self.query)
            }
            guard let self else { return }
            let covers = await self.resolveCovers(store: store, transport: transport)
            self.resolving = false

            var note = named > 0 ? "named \(named) issue\(named == 1 ? "" : "s")" : ""
            if covers > 0 {
                note += note.isEmpty ? "" : ", "
                note += "found \(covers) cover\(covers == 1 ? "" : "s")"
            }
            self.refresh(note: note)
        }
    }

    /// Asks the catalogue for covers the forum page did not link.
    ///
    /// Runs after the names, on the same throttled transport, because it is
    /// the same bargain: a request per issue against a host that rate-limits,
    /// in exchange for a shelf that shows artwork instead of a number.
    private func resolveCovers(store: Store, transport: Transport) async -> Int {
        var found = 0
        let total = store.coverlessIssueCount
        guard total > 0 else { return 0 }

        while true {
            guard let batch = try? await store.backfillCovers(via: transport, limit: 5),
                  batch.asked > 0 else { break }
            found += batch.found
            status = "Looking for covers: \(total - store.coverlessIssueCount)/\(total)"
            search(query)
        }
        return found
    }

    /// Fetches the archive: resolve a mirror, download, decrypt if needed,
    /// verify it is really an archive. Falls through to the next mirror when
    /// one is dead.
    func download(_ issue: StoredIssue) {
        guard let library, !downloading.contains(issue.id) else { return }
        let issueID = issue.id
        let name = issue.title ?? issue.code ?? "issue"
        downloading.insert(issueID)
        progress[issueID] = 0
        status = "downloading “\(name)”…"

        // Progress crosses threads as plain numbers.
        //
        // The downloader calls back from whichever thread is moving bytes, so
        // its closure must not reach for the model: reading a captured, weak,
        // non-Sendable AppModel from concurrent code is a data race, and an
        // error under the Swift 6 language mode. A stream continuation *is*
        // Sendable, so that is all the closure holds; the fractions are
        // consumed on the main actor, where the model lives.
        var sink: AsyncStream<Double>.Continuation!
        let fractions = AsyncStream<Double> { sink = $0 }
        let continuation = sink!
        let report: @Sendable (DownloadProgress) -> Void = { p in
            // expected is -1 when the server sends no length; with no total
            // there is no fraction to show.
            guard p.expected > 0 else { return }
            // Scaled to leave room for unpacking. The two are one wait as far
            // as the reader is concerned, so they share one bar.
            continuation.yield(Double(p.received) / Double(p.expected) * Self.transferShare)
        }

        Task { @MainActor [weak self] in
            for await fraction in fractions { self?.progress[issueID] = fraction }
        }

        Task { @MainActor [weak self] in
            defer { continuation.finish() }
            do {
                let outcome = try await library.fetch(issueID: issueID, progress: report)

                // Unpack now, inside the wait the reader has already accepted.
                // No byte count to report — extraction is all-or-nothing — so
                // the bar holds near the end rather than pretending to know.
                if let self {
                    self.progress[issueID] = Self.transferShare
                    self.status = "unpacking “\(name)”…"
                }
                try await Task.detached(priority: .userInitiated) {
                    try library.prepareForReading(issueID: issueID)
                }.value

                guard let self else { return }
                self.downloading.remove(issueID)
                self.progress[issueID] = nil
                // A success clears any earlier failure mark.
                try? self.store?.setDownloadFailed(false, issueID: issueID)

                // An issue the forum gave no cover for shows on the shelf as
                // a grey rectangle with its number in it. Now that the comic
                // is here, its own first page is a better answer than the
                // number — and nothing else is ever going to provide one.
                //
                // Before the refresh below, so the row redraws with it.
                if let store = self.store,
                   ((try? store.coverURL(forIssue: issueID)) ?? nil) == nil {
                    let captured = try? await Task.detached(priority: .utility) {
                        try library.captureCover(issueID: issueID)
                    }.value
                    if let captured { try? store.setCoverURL(captured, issueID: issueID) }
                }
                let mb = Double(outcome.bytes) / 1_048_576
                // refresh() re-runs the search, so the row rebuilds with
                // isDownloaded true and the cover turns colour at once.
                self.refresh(note: String(format: "downloaded %.1f MB (%@)",
                                          mb, outcome.kind.rawValue))
            } catch {
                guard let self else { return }
                self.downloading.remove(issueID)
                self.progress[issueID] = nil
                // Marked on the shelf, not just in an alert that is gone the
                // moment it is dismissed: some of these links really are dead,
                // and without a mark you retry them for ever.
                try? self.store?.setDownloadFailed(true, issueID: issueID)
                self.search(self.query)
                self.status = "download failed"
                // Summarised, not dumped: interpolating the raw error filled
                // the alert with NSError userInfo and buried the one sentence
                // that says what went wrong.
                self.failure = "“\(name)” could not be downloaded.\n\n"
                    + Library.reason(error)
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
        freeSpace = Self.freeSpace()
        // A newly imported page can bring a series the menu has not offered.
        availableSeries = (try? store?.editions()) ?? []
        availablePublishers = (try? store?.publishers()) ?? []
        availableHeroes = (try? store?.heroes()) ?? []
        search(query)
        status = note
    }

    func mirrors(for issue: StoredIssue) -> [MirrorLink] {
        (try? store?.mirrors(forIssue: issue.id)) as? [MirrorLink] ?? []
    }
}
