import Foundation
import SwiftUI
import SZKit
import UniformTypeIdentifiers

@main
struct SZReaderApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

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
                // A file handed over from outside — AirDropped from a Mac,
                // sent through the share sheet, or opened with this app from
                // the Files app. It is copied into the reader's folder and
                // reaches the shelf the same way a file dragged in over a
                // cable does.
                .onOpenURL { url in
                    guard url.isFileURL else { return }
                    model.adoptLocalFile(at: url)
                }
                // Two questions that can only be answered by asking again, and
                // both for the same reason: what they are about changes while
                // this app is not the one running.
                //
                // The folder is filled from a Mac, which is the whole point of
                // it. The reader's settings are changed on their other device,
                // and the store's change notification does not arrive in the
                // background — so without asking here, the iPad would follow
                // the iPhone only while both were open, and need restarting
                // the rest of the time.
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    model.scanLocalFiles()
                    model.refreshPreferences()
                }
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
    /// What each downloaded issue weighs, keyed by issue id.
    ///
    /// Held rather than asked for per row: the Scan Size order compares on it,
    /// and every list row puts it on its Remove Download button, so a lookup
    /// per row would be a database statement inside a view body. Refreshed
    /// wherever the download set can change, which is `refresh(note:)` — every
    /// download, removal and delete goes through it.
    @Published var downloadedSizes: [Int: Int64] = [:]
    /// How many of those the app seeded from a catalogue it ships.
    ///
    /// Published because the bulk deletes leave them where they are, so both
    /// their counts and their warnings have to say how much is actually
    /// going.
    @Published var shippedCount = 0
    /// How many of the reader's own files are on the shelf.
    ///
    /// Published, unlike `localFileTotals` beside the folder scan: Settings
    /// names this number in a heading, and a heading cannot put a database
    /// query in a view body — that view redraws on every switch thrown and on
    /// every line the status bar writes. Refreshed wherever the other counts
    /// are, which covers the folder itself: a scan that found anything ends
    /// in `refresh(note:)`.
    @Published var localFileCount = 0
    /// 0...1 per issue being fetched, for the progress bar.
    @Published var progress: [Int: Double] = [:]
    /// Series the reader has narrowed to. Empty means every series.
    ///
    /// Persisted as newline-joined text: `AppStorage` cannot hold a Set, and a
    /// newline is the one separator a series name will never contain.
    @AppStorage("seriesFilter") private var seriesFilterRaw = "" {
        didSet { scheduleSearch() }
    }

    var selectedSeries: Set<String> {
        get { Set(seriesFilterRaw.split(separator: "\n").map(String.init)) }
        set { seriesFilterRaw = newValue.sorted().joined(separator: "\n") }
    }

    /// Publishers the reader has narrowed to. Empty means every publisher.
    @AppStorage("publisherFilter") private var publisherFilterRaw = "" {
        didSet { scheduleSearch() }
    }

    var selectedPublishers: Set<String> {
        get { Set(publisherFilterRaw.split(separator: "\n").map(String.init)) }
        set { publisherFilterRaw = newValue.sorted().joined(separator: "\n") }
    }

    /// Read-state switches. All on, or all off, means show everything —
    /// asking for every state is the same as not asking.
    @AppStorage("showUnread") var showUnread = false { didSet { scheduleSearch() } }
    @AppStorage("showReading") var showReading = false { didSet { scheduleSearch() } }
    @AppStorage("showRead") var showRead = false { didSet { scheduleSearch() } }

    var readStates: Set<ReadState> {
        var states: Set<ReadState> = []
        if showUnread { states.insert(.unread) }
        if showReading { states.insert(.reading) }
        if showRead { states.insert(.read) }
        return states
    }

    /// Heroes the reader has narrowed to. Empty means every hero.
    @AppStorage("heroFilter") private var heroFilterRaw = "" {
        didSet { scheduleSearch() }
    }

    var selectedHeroes: Set<String> {
        get { Set(heroFilterRaw.split(separator: "\n").map(String.init)) }
        set { heroFilterRaw = newValue.sorted().joined(separator: "\n") }
    }

    /// Every series in the library, for building the filter menu.
    @Published var availableSeries: [String] = []
    /// The same series, split by where they came from.
    ///
    /// With both sources showing, one alphabetical list runs the forum's
    /// editions and nineteen ex-Yugoslav magazine runs into each other, and
    /// the reader has to already know which is which to use it.
    @Published var seriesBySite: [IssueSite: [String]] = [:]
    /// Every publisher in the library, likewise.
    @Published var availablePublishers: [String] = []
    /// Every hero in the library, in the spelling the rows hold.
    @Published var availableHeroes: [String] = []

    /// How the shelf is ordered.
    ///
    /// Recently Open by default: the shelf runs to thousands of issues, and
    /// the handful anyone is actually part-way through is scattered through
    /// it by every other order. A reader who has picked another order has it
    /// stored and keeps it — `@AppStorage` only writes when set, so this
    /// default reaches exactly the people who never chose.
    @AppStorage("shelfSort") var sortOrder: ShelfSort = .default {
        didSet { scheduleSearch() }
    }

    /// Show only comics whose archive is actually on disk.
    @AppStorage("downloadedOnly") var downloadedOnly = false {
        didSet { scheduleSearch() }
    }

    /// How the page thumbnails on disk were rendered — their size, and which
    /// build of the drawing made them — so a build that changes either throws
    /// them away rather than serving the old ones.
    ///
    /// A new key, deliberately: the old one held the size alone, and every
    /// library out there has the current size written into it. Reusing it
    /// would mean this fix reached nobody who already had thumbnails, which is
    /// precisely the set of people with clipped ones.
    @AppStorage("pageRenderStamp") private var pageRenderStamp = ""

    // MARK: - Sources

    /// Whether the forum's issues are shown. On by default: importing a page
    /// is the app's original purpose, and a reader who has imported one
    /// should see it without being sent to a settings screen first.
    @AppStorage("showStripZona") var showStripZona = true {
        didSet { sourcesChanged(enabled: showStripZona, site: .stripzona) }
    }

    /// Whether the shipped RetroSpec catalogue is shown.
    ///
    /// Off by default, and the catalogue is not even loaded until it is
    /// switched on. Six hundred magazines nobody asked for is not a first
    /// launch — it is a shelf someone has to work out how to empty.
    @AppStorage("showRetroSpec") var showRetroSpec = false {
        didSet { sourcesChanged(enabled: showRetroSpec, site: .retrospec) }
    }

    /// Whether the shipped archive.org catalogue is shown. Off by default for
    /// the same reason, though this one is four issues rather than six hundred.
    @AppStorage("showArchive") var showArchive = false {
        didSet { sourcesChanged(enabled: showArchive, site: .archive) }
    }

    /// Whether Comic Book Plus is shown.
    ///
    /// Off by default like the other two, though for a different reason: it
    /// ships no catalogue at all, so switching it on adds nothing to the shelf
    /// and only puts a second entry in the Import menu. A source that starts
    /// on and appears to do nothing is worse than one the reader turns on
    /// deliberately.
    /// The stored key says "CBPlus" rather than spelling the site out, because
    /// `UIWordingTests` lints every string literal in this layer for the word
    /// "comic" and a defaults key is not worth an exemption. The property
    /// keeps the readable name; identifiers are not what the lint reads.
    @AppStorage("showCBPlus") var showComicBookPlus = false {
        didSet { sourcesChanged(enabled: showComicBookPlus, site: .comicbookplus) }
    }

    /// Whether each BombJack catalogue is shown.
    ///
    /// Seven of them, so these are read from `UserDefaults` by name rather
    /// than declared as seven `@AppStorage` properties. All off by default:
    /// switching one on adds a few thousand rows, and nobody wants all
    /// eighteen thousand.
    ///
    /// `objectWillChange` is sent by hand on write, which is the one thing
    /// `@AppStorage` was doing for us.
    static func defaultsKey(for site: IssueSite) -> String { "show_\(site.rawValue)" }

    private func storedFlag(_ site: IssueSite) -> Bool {
        UserDefaults.standard.bool(forKey: Self.defaultsKey(for: site))
    }

    private func storeFlag(_ site: IssueSite, _ enabled: Bool) {
        objectWillChange.send()
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey(for: site))
        sourcesChanged(enabled: enabled, site: site)
    }

    /// Which stored key stands for which source.
    ///
    /// Read backwards as well as forwards now: a switch thrown on the reader's
    /// other device arrives as a key, and something has to know which source
    /// that is. The four spelled out by hand carry the names they were given
    /// when there were four sources rather than twenty-three; everything since
    /// is `show_<site>`, which is why the rest is generated rather than typed.
    static let sourceDefaultsKeys: [String: IssueSite] = {
        var map: [String: IssueSite] = [
            "showStripZona": .stripzona,
            "showRetroSpec": .retrospec,
            "showArchive": .archive,
            "showCBPlus": .comicbookplus,
        ]
        for site in IssueSite.allCases
        where site.isSwitchable && !map.values.contains(site) {
            map[defaultsKey(for: site)] = site
        }
        return map
    }()

    /// Preferences that follow the reader to their other devices.
    ///
    /// Everything they deliberately chose: which sources show, how the shelf
    /// is filtered, how it is sorted, how it is laid out, and how pages are
    /// zoomed. Small, flat, and entirely strings and booleans — see
    /// `PreferenceCloud`, which carries it.
    static var syncedDefaultsKeys: [String] {
        sourceDefaultsKeys.keys.sorted() + [
            "seriesFilter", "publisherFilter", "heroFilter",
            "showUnread", "showReading", "showRead",
            "downloadedOnly", "shelfSort", "libraryLayout",
            SmartZoom.settingKey,
        ]
    }

    /// Preferences that stay on the device that set them, and why.
    ///
    /// Every one of these describes *this* device rather than what the reader
    /// wants, and syncing it would be actively wrong:
    ///
    /// - `pageRenderStamp` records how the thumbnails **on this disk** were
    ///   drawn. Carried across, a device that has never drawn one would think
    ///   it had, and keep serving nothing.
    /// - `retroSpecDefaultResolved` marks a one-time question already asked
    ///   here, and the answer depends on what this library had seeded at the
    ///   time. Answered elsewhere, it would skip the question on a device
    ///   whose answer differs.
    /// - `smartZoomOfferedIn` is a one-time offer, keyed to the build that
    ///   made it. A new device is a fair place to be told about the feature
    ///   once, and this is a prompt rather than a preference — the setting it
    ///   offers, `smartZoom`, does sync.
    ///
    /// Spelled out rather than left implicit so that adding a preference makes
    /// somebody decide. `PreferenceKeyCoverageTests` fails on any stored key
    /// that is in neither list.
    static let deviceOnlyDefaultsKeys = [
        "pageRenderStamp", "retroSpecDefaultResolved", "smartZoomOfferedIn",
    ]

    /// Sources the reader has switched on.    /// Sources the reader has switched on. Empty is a real answer — it means
    /// the shelf is deliberately blank — which is why nothing here hands an
    /// empty set to the store, where empty means "no opinion, show all".
    var visibleSites: Set<IssueSite> {
        Set(IssueSite.allCases.filter(isEnabled))
    }

    /// Told to the reader after switching a source on, so a shelf that just
    /// grew says where the issues came from and how to undo it.
    @Published var sourceNotice: SourceNotice?

    /// One switch-on, in the words shown to whoever threw the switch.
    ///
    /// Carries the source as well as the sentence: both places that show this
    /// are alerts, and an alert titled "RetroSpec" over a message about
    /// archive.org is worse than no title at all.
    struct SourceNotice: Equatable {
        let site: IssueSite
        let message: String
    }

    func setSource(_ site: IssueSite, enabled: Bool) {
        // A source with no switch has nothing to set. Reached in the ordinary
        // course of things rather than by mistake: Local Files is one of
        // `SourceLanguage.sharedSites`, and moving a language moves those.
        guard site.isSwitchable else { return }
        switch site {
        case .stripzona:     showStripZona = enabled
        case .retrospec:     showRetroSpec = enabled
        case .archive:       showArchive = enabled
        case .comicbookplus: showComicBookPlus = enabled
        default:             storeFlag(site, enabled)
        }
    }

    func isEnabled(_ site: IssueSite) -> Bool {
        // Always on, and not stored: the reader's own files are on the shelf
        // because they are on the device. Answering from `storedFlag` would
        // have them default to off — a folder dragged full of issues that
        // shows nothing, and no switch anywhere to explain it.
        guard site.isSwitchable else { return true }
        switch site {
        case .stripzona:     return showStripZona
        case .retrospec:     return showRetroSpec
        case .archive:       return showArchive
        case .comicbookplus: return showComicBookPlus
        default:             return storedFlag(site)
        }
    }

    /// Whether a language is showing: whether any of the sources it alone
    /// decides is on.
    ///
    /// Asked of `language.sites`, which leaves archive.org out on purpose. It
    /// holds every language, so with ex-YU on and English off it is on — and
    /// counting it would make the English switch report itself on with not one
    /// English shelf behind it.
    func isEnabled(_ language: SourceLanguage) -> Bool {
        language.sites.contains { isEnabled($0) }
    }

    /// Moves a whole language's sources at once.
    ///
    /// Not simply a loop over `setSource`: each call rebuilds the filter menus
    /// and re-runs the search, and fifteen of those on one tap is a freeze.
    /// The flags all move first, and the shelf is rebuilt once at the end.
    func setLanguage(_ language: SourceLanguage, enabled: Bool) {
        movingSeveral = true
        for site in language.sites {
            setSource(site, enabled: enabled)
        }
        // Archive.org follows the last language to leave rather than the
        // first: switching ex-YU off while English is on must not take the
        // English half of archive.org with it.
        let sharedStaysOn = enabled || SourceLanguage.allCases.contains {
            $0 != language && isEnabled($0)
        }
        for site in SourceLanguage.sharedSites {
            setSource(site, enabled: sharedStaysOn)
        }
        movingSeveral = false
        rebuildForVisibleSources()
    }

    /// Moves an archive's catalogues together, as the one switch they are
    /// shown as.
    ///
    /// PopBoks ships as two catalogues — Džuboks and Ritam — and is one
    /// archive of one society's scanning to everybody who is not this app's
    /// seeder, so Settings offers one switch for it. Batched like
    /// `setLanguage` and for the same reason: each `setSource` rebuilds the
    /// filter menus and re-runs the search, and that is worth doing once.
    func setSources(_ sites: [IssueSite], enabled: Bool) {
        guard sites.count > 1 else {
            for site in sites { setSource(site, enabled: enabled) }
            return
        }
        movingSeveral = true
        for site in sites { setSource(site, enabled: enabled) }
        movingSeveral = false
        rebuildForVisibleSources()
    }

    /// True while several switches are being moved as one — a language, or an
    /// archive shown as a single switch — which is what the per-source work
    /// below reads to know it is one of many.
    private var movingSeveral = false

    /// Loads the catalogue the first time its source is switched on, then
    /// rebuilds the shelf around whatever is now visible.
    ///
    /// Switching a source off never deletes anything. What has been read,
    /// where reading stopped and which archives are on disk all belong to the
    /// reader; hiding a source is a view, not a purge, and switching it back
    /// on returns exactly what was there.
    private func sourcesChanged(enabled: Bool, site: IssueSite) {
        if enabled, site.catalogueResource != nil {
            // Not on this thread. Switching a source on used to seed it here
            // and now, which froze the app solid for the length of the seed —
            // fifteen seconds for the largest catalogue, with the settings
            // sheet still on screen and nothing moving.
            //
            // Silent when one switch is moving several sources: alerts that
            // each replace the last amount to one alert naming whichever
            // source happened to finish second-to-last, and the count in it
            // would cover only that one. True of a language's fifteen and of
            // PopBoks's two alike. The status line still says what is
            // loading.
            seedInBackground(site, announce: !movingSeveral)
        }
        // A language switch moves up to fifteen of these, and the rebuild
        // below is worth doing once when the last of them has moved — which is
        // what `setLanguage` does.
        guard !movingSeveral else { return }
        rebuildForVisibleSources()
    }

    /// What the shelf has to redo once the set of visible sources has changed.
    ///
    /// A filter naming a series from a source that is now hidden matches
    /// nothing, and an empty shelf with no visible reason is the most baffling
    /// state the app has. Dropping those selections keeps the shelf
    /// explainable by what is actually on screen.
    /// Keeps the reader's settings the same on every device on their account.
    ///
    /// Held for the life of the app: it is what carries the notification
    /// observers, and a mirror nobody holds stops listening the moment it is
    /// created.
    private var preferences: PreferenceCloud?

    /// Asks the account what the reader's other device has changed.
    ///
    /// Called when the app comes back to the front. See `PreferenceCloud
    /// .refresh` for why waiting to be told is not enough.
    func refreshPreferences() { preferences?.refresh() }

    private func startPreferenceSync() {
        let cloud = PreferenceCloud(keys: Self.syncedDefaultsKeys)
        cloud.didAdopt = { [weak self] keys in self?.applyRemotePreferences(keys) }
        preferences = cloud
        cloud.start()
    }

    /// Applies preferences the reader changed on another device.
    ///
    /// `@AppStorage` has republished by the time this runs, so every switch
    /// and menu on screen already shows the new value. What it cannot do is
    /// the work each `didSet` would have done, because a `didSet` fires on
    /// assignment through the property and nothing here assigns. So the two
    /// things that are more than display happen here: a catalogue whose switch
    /// has just come on somewhere else is loaded, and the shelf is re-asked.
    private func applyRemotePreferences(_ keys: [String]) {
        // The eighteen by-name source flags have no property to republish
        // them — `storeFlag` sends this by hand for exactly the same reason.
        objectWillChange.send()

        // Every value is read from the store and assigned through this
        // model's own property. Both halves of that matter.
        //
        // Read from the store, because the property cannot be trusted to
        // answer: `@AppStorage` on an `ObservableObject` reads `UserDefaults`
        // only until the first write through the property and caches from
        // then on, answering with the last value *this device* set whatever
        // is actually stored. `AppStorageCachingTests` pins that.
        //
        // Assigned through the property, because that is the only thing that
        // clears the stale cache — and it is also what fires each `didSet`,
        // which is where the real work lives. Writing to `UserDefaults` alone
        // did neither: it was correct, invisible, and looked from the outside
        // like sync that stopped working the moment you used the app.
        let defaults = UserDefaults.standard
        for key in keys {
            switch key {
            case "shelfSort":
                sortOrder = defaults.string(forKey: key)
                    .flatMap(ShelfSort.init(rawValue:)) ?? .default
            case "seriesFilter":    seriesFilterRaw = defaults.string(forKey: key) ?? ""
            case "publisherFilter": publisherFilterRaw = defaults.string(forKey: key) ?? ""
            case "heroFilter":      heroFilterRaw = defaults.string(forKey: key) ?? ""
            case "showUnread":      showUnread = defaults.bool(forKey: key)
            case "showReading":     showReading = defaults.bool(forKey: key)
            case "showRead":        showRead = defaults.bool(forKey: key)
            case "downloadedOnly":  downloadedOnly = defaults.bool(forKey: key)
            // `libraryLayout` and `smartZoom` are read in views rather than
            // here, and a view's `@AppStorage` is refreshed by SwiftUI itself.
            default: break
            }
        }
        // Each of those `didSet`s schedules a search, and `scheduleSearch`
        // cancels the one before it, so a dozen arriving at once still costs
        // one query.

        let sources = keys.compactMap { key in
            Self.sourceDefaultsKeys[key].map { (key: key, site: $0) }
        }
        guard !sources.isEmpty else { return }

        // Batched the way `setLanguage` batches, and for the same reason: each
        // seed rebuilds the filter menus and re-runs the query, and a device
        // waking up to a language's fifteen sources switched on would other-
        // wise do all of that fifteen times.
        movingSeveral = true
        for source in sources {
            // Through `setSource`, which owns the difference between the four
            // sources with properties and the eighteen stored by name, and
            // which seeds a catalogue that has just been switched on. Cheap
            // when it is already in: the stamp in `meta` makes an unchanged
            // catalogue a single read.
            setSource(source.site, enabled: defaults.bool(forKey: source.key))
        }
        movingSeveral = false
        rebuildForVisibleSources()
    }

    private func rebuildForVisibleSources() {
        refreshSourceMenus()
        issueCount = store?.issueCount ?? 0
        downloadedCount = store?.downloadedCount ?? 0
        shippedCount = store?.shippedCount ?? 0
        localFileCount = store?.localFileTotals.count ?? 0
        scheduleSearch()
    }

    /// Rebuilds the Series, Publisher and Hero menus.
    ///
    /// Off the main thread, because this is eight `DISTINCT` queries over the
    /// whole issue table and the table is now twenty thousand rows deep.
    /// Switching a source *off* does no work at all beyond this — no seeding,
    /// nothing to write — and still froze the app solid, because every one of
    /// those queries ran here before the switch could redraw.
    ///
    /// The queries are also indexed now, so this is fast as well as
    /// non-blocking; the two together are what make the switch feel like a
    /// switch. The results land back on the main actor, which is where the
    /// `@Published` properties live.
    private func refreshSourceMenus() {
        let sites = visibleSites
        guard let store, !sites.isEmpty else {
            availableSeries = []; availablePublishers = []; availableHeroes = []
            seriesBySite = [:]
            return
        }
        Task { @MainActor [weak self] in
            let menus = await Task.detached(priority: .userInitiated) { () -> Menus in
                // Asked per source as well as together. The menu needs them
                // grouped and the filters need them pooled, and deriving one
                // from the other would mean knowing which source a series name
                // came from — which is exactly what the second query answers
                // and a name cannot.
                var grouped: [IssueSite: [String]] = [:]
                for site in sites {
                    let names = (try? store.editions(sites: [site])) ?? []
                    if !names.isEmpty { grouped[site] = names }
                }
                return Menus(series: (try? store.editions(sites: sites)) ?? [],
                             publishers: (try? store.publishers(sites: sites)) ?? [],
                             heroes: (try? store.heroes(sites: sites)) ?? [],
                             bySite: grouped)
            }.value

            guard let self else { return }
            self.availableSeries = menus.series
            self.availablePublishers = menus.publishers
            self.availableHeroes = menus.heroes
            self.seriesBySite = menus.bySite
            // Only once the menus are known: a selection is pruned against
            // what is actually on offer, and pruning against a stale list
            // drops a filter the reader can still see.
            self.pruneHiddenSelections()
        }
    }

    /// One trip's worth of menu contents, so the background pass hands back a
    /// single value rather than reaching for four properties from off-actor.
    private struct Menus: Sendable {
        let series: [String]
        let publishers: [String]
        let heroes: [String]
        let bySite: [IssueSite: [String]]
    }

    /// Written back only where something actually changed.
    ///
    /// Each of these three setters lands in an `@AppStorage` string whose
    /// `didSet` re-runs the search, and `didSet` fires on any assignment,
    /// equal value or not. Assigned unconditionally, one source switch cost
    /// four full-library searches — the rebuild's own, plus one for each
    /// selection that had not changed and, in the usual case, was not even
    /// set. At thirty thousand rows that is a fetch and a sort of the whole
    /// shelf, three times over, to discover that no filter had moved.
    private func pruneHiddenSelections() {
        let series = selectedSeries.intersection(availableSeries)
        if series != selectedSeries { selectedSeries = series }

        let publishers = selectedPublishers.intersection(availablePublishers)
        if publishers != selectedPublishers { selectedPublishers = publishers }

        let heroes = selectedHeroes.intersection(availableHeroes)
        if heroes != selectedHeroes { selectedHeroes = heroes }
    }
    /// A failure worth interrupting for. The status line is too easy to miss,
    /// and a download that silently does nothing looks like a broken app.
    @Published var failure: Failure?

    /// What the alert says, and what it is called.
    ///
    /// The title used to be the constant "Download failed", which is wrong for
    /// the one failure that is not one: a host asking for a pause has not lost
    /// the file and there is nothing to fix — the reader has to be told to
    /// wait, and a heading that says the download failed sends them straight
    /// back to the button.
    struct Failure: Equatable {
        let title: String
        let message: String
    }

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

    /// Bytes moved so far, and the total expected, for a transfer in flight.
    ///
    /// Beside `progress` rather than folded into it because the two are not
    /// the same thing: the fraction spans transfer *and* unpacking, while
    /// these are bytes off the wire. Only the archive download reports them —
    /// the page-image sources count pages, and multiplying a page fraction by
    /// a byte total would invent a number.
    @Published var transferred: [Int: TransferBytes] = [:]

    struct TransferBytes: Sendable, Equatable {
        let received: Int64
        let expected: Int64
    }

    /// What a download in flight is doing right now, in the words the status
    /// bar uses.
    ///
    /// The status line has always said more than the sheet did: the
    /// page-image sources count pages there while the sheet showed a bare
    /// percentage, and the unpacking that follows an archive download was
    /// named there and nowhere else. Both live here so the panel a reader
    /// opens says the same thing as the line along the bottom.
    ///
    /// Beside `transferred` rather than inside it: bytes off the wire are
    /// measured, these are the phase they were measured in, and only the
    /// archive sources report both.
    @Published var stage: [Int: DownloadStage] = [:]

    enum DownloadStage: Sendable, Equatable {
        /// A page-image source, part-way through reassembling an issue.
        case pages(done: Int, total: Int)
        /// An archive is here and is being extracted. No count to give —
        /// extraction is all-or-nothing.
        case unpacking
    }

    /// One report from the downloader, crossing threads.
    ///
    /// Sendable and plain, for the reason spelled out where the stream is
    /// built: the progress closure runs on whichever thread is moving bytes
    /// and must not touch the model.
    struct TransferTick: Sendable {
        let fraction: Double
        let received: Int64
        let expected: Int64
    }

    /// What an issue's downloaded file weighs on disk, or nil when it is not
    /// downloaded. Read straight from the download record rather than stat'ing
    /// the file: the record is what the shelf's own storage readout counts.
    func downloadedBytes(issueID: Int) -> Int64? {
        guard let store else { return nil }
        guard let outcome = try? store.downloadedFile(issueID: issueID),
              outcome.bytes > 0 else { return nil }
        return outcome.bytes
    }

    private var store: Store?
    /// Readable so the page grid can render thumbnails from the pages already
    /// on disk; only this model ever sets it.
    private(set) var library: Library?

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
            // And a cover that fails to load is worth writing down: the shelf
            // is where a dead image host is discovered, and the library is
            // where that has to be recorded for anything to be done about it.
            // Safe from any thread — `Store` serialises its statements.
            CoverStore.reportDeadCover = { [weak store] url in
                try? store?.markCoverDead(url: url)
            }
            // The default registry, with the one host that needs something
            // only the app layer can give it: the reader's session with Comic
            // Book Plus, which lives in WebKit's cookie store. Asked for at
            // the moment a download resolves, never held.
            let hosts = HostRegistry(hosts: [
                MediaFireHost(), MegaHost(), PixeldrainHost(),
                ComicBookPlusHost(cookies: {
                    await SiteCookies.header(forDomain: ComicBookPlus.host)
                }),
                DirectHost(),
            ])
            library = Library(store: store,
                              paths: paths,
                              transport: transport,
                              downloader: URLSessionDownloader(),
                              registry: hosts)

            // Page thumbnails are cached by page, and the file on disk records
            // neither how large it was drawn nor how — so a build that changes
            // either goes on serving what the last one left behind, for ever,
            // because nothing ever looks at them again. Cheap to throw away:
            // they are made from pages that are still on disk.
            //
            // *After* the library exists, which is what this needed and did
            // not have. It ran a line earlier, against a `library` that was
            // still nil: it discarded nothing, wrote the stamp, and left the
            // stale thumbnails exactly where they were.
            if pageRenderStamp != Library.pageRenderingStamp {
                library?.discardAllPageThumbnails()
                pageRenderStamp = Library.pageRenderingStamp
            }

            // A library that already holds the catalogue keeps showing it.
            //
            // The switch defaults to off, which is right for someone opening
            // the app for the first time and wrong for someone who already
            // has these magazines — downloaded, part-read — and would find
            // them gone after an update. Asked once, before the switch is
            // ever read, so a deliberate switch-off is never undone by it.
            if !UserDefaults.standard.bool(forKey: "retroSpecDefaultResolved") {
                UserDefaults.standard.set(true, forKey: "retroSpecDefaultResolved")
                if (try? store.hasSeeded(.retrospec)) == true { showRetroSpec = true }
            }

            // A catalogue ships with the app but is not loaded until its
            // source is switched on, so an untouched install really is empty
            // rather than empty-looking with 653 rows hidden behind a filter.
            //
            // A failure is not fatal. The forum library is the app's original
            // reason to exist and works with or without either of these.
            // Off the main thread, and not waited on.
            //
            // This used to seed every enabled catalogue here, synchronously,
            // before the first frame. That was survivable at RetroSpec's 653
            // issues and fatal at eighteen thousand: the seed takes fifteen
            // seconds, iOS kills an app that blocks its launch for about
            // twenty, and the kill rolled the transaction back — so the next
            // launch started over and was killed again. The app could not be
            // opened at all, and the switch that would have turned the source
            // off was on the other side of the launch.
            //
            // Now the shelf comes up first and the catalogue fills in behind
            // it. `Store` serialises its own statements, so this is safe from
            // any thread.
            for site in IssueSite.allCases
            where site.catalogueResource != nil && isEnabled(site) {
                seedInBackground(site, announce: false)
            }

            #if DEBUG
            seedFromSavedPages(into: store)
            #endif

            // The folder the reader fills themselves, read before the counts
            // below so the first frame already shows what is in it. Cheap: a
            // directory listing and, on the usual launch where nothing has
            // changed, one read per file to compare its size.
            scanLocalFiles()
            watchLocalFiles()

            // The download table against the device, before anything below
            // counts it. A restore brings the database back and leaves the
            // files behind — see `Library.reconcileDownloads` — and every
            // readout here would otherwise describe a library that is not on
            // the device: the count, the sizes, the disk usage, and a shelf
            // showing every issue as downloaded.
            let forgotten = (try? library?.reconcileDownloads()) ?? nil ?? []
            if !forgotten.isEmpty {
                status = "\(forgotten.count) download\(forgotten.count == 1 ? " is" : "s are") "
                       + "no longer on this device, and can be fetched again"
            }

            issueCount = store.issueCount
            downloadedCount = store.downloadedCount
            shippedCount = store.shippedCount
            localFileCount = store.localFileTotals.count
            downloadedSizes = store.downloadedBytesByIssue
            diskUsage = library?.diskUsage ?? 0
            freeSpace = Self.freeSpace()
            refreshSourceMenus()
            search("")
            // After the shelf exists, and deliberately so: adopting a filter
            // from another device re-runs the query, and there has to be a
            // query to re-run. Before it, the first frame would be drawn from
            // this device's settings and then rearranged under the reader.
            startPreferenceSync()
            resolveTitles()
            // Anything downloaded whose artwork went away since. See the
            // method: the capture at download time only ever fires once, and
            // a cover that dies later leaves a comic on the device showing a
            // grey rectangle for good.
            captureMissingCovers()
        } catch {
            status = "failed: \(error)"
        }
    }

    /// A search waiting for the current burst of changes to finish.
    ///
    /// Held so the next request can cancel it: the last one asked in a turn is
    /// the one worth running.
    private var pendingSearch: Task<Void, Never>?

    /// One search after a burst of changes, instead of one per change.
    ///
    /// The things that re-run the search rarely move alone. A source switch
    /// prunes three filter selections behind it; a language switch seeds
    /// fifteen catalogues that each land on their own. Every run is a fetch of
    /// every visible row and a sort of the lot, on this actor — 57 ms on a
    /// thirty-thousand-issue shelf by arrival, half a second by title — so
    /// everything that re-searches as bookkeeping rather than because a reader
    /// asked comes through here.
    ///
    /// Not a debounce: nothing waits on a clock. A task scheduled from the
    /// main actor cannot start until whatever scheduled it has finished
    /// running, and that window — one turn of synchronous changes — is exactly
    /// what is worth collapsing.
    private func scheduleSearch() {
        pendingSearch?.cancel()
        pendingSearch = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.pendingSearch = nil
            self.search(self.query)
        }
    }

    func search(_ text: String) {
        // Whatever a scheduled search was going to ask, this answers: it reads
        // the same filters and is about to set the query itself.
        pendingSearch?.cancel()
        pendingSearch = nil
        guard let store else { return }
        query = text
        // Every source switched off means an empty shelf, and it has to be
        // answered here rather than by the query: the store reads an empty
        // set of sources as "no preference" and returns the whole library,
        // which is the right default for a caller that has no opinion and the
        // exact opposite of what this one is saying.
        guard !visibleSites.isEmpty else {
            results = []
            return
        }
        let searching = !text.trimmingCharacters(in: .whitespaces).isEmpty
        do {
            // Empty query lists the start of the library rather than nothing,
            // so the shelf is never blank on launch.
            results = !searching
                // No cap: the grid and list are lazy, so only visible cells are
                // built, and a silent 200-row ceiling made a 613-issue library
                // look like it ended at 200.
                ? try store.recent(limit: nil, downloadedOnly: downloadedOnly,
                                   editions: selectedSeries,
                                   publishers: selectedPublishers,
                                   heroes: selectedHeroes,
                                   states: readStates, sites: visibleSites)
                : try store.search(text, limit: nil, downloadedOnly: downloadedOnly,
                                   editions: selectedSeries,
                                   publishers: selectedPublishers,
                                   heroes: selectedHeroes,
                                   states: readStates, sites: visibleSites)
            // Applied on top of the query, and told whether there is one: the
            // shelf sorts by arrival, a search stays in relevance order. Both
            // import orders defer here; the four explicit keys do not.
            if let comparator = StoredIssue.comparator(for: sortOrder,
                                                       whileSearching: searching,
                                                       sizes: downloadedSizes) {
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
    /// Under Application Support, not Documents.
    ///
    /// It used to be written into Documents, which was invisible and
    /// therefore harmless — until Local Files made that folder the one the
    /// Finder shows and the shelf reads. A stray `last-import.html` there is
    /// a file in the reader's own folder that they did not put there, sitting
    /// among their issues.
    private func dumpForDiagnosis(_ html: String) {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return }
        try? html.write(to: support.appendingPathComponent("last-import.html"),
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

    /// Gives a cover to downloaded issues that have none.
    ///
    /// A cover is normally captured the moment a download finishes, but only
    /// when the issue had no artwork *at that moment*. Anything whose remote
    /// cover dies later than that — a hotlinked image on a host that stops
    /// answering — keeps its file, keeps its pages, and shows a grey rectangle
    /// for good, because nothing ever asks again.
    ///
    /// This is what asks again. A trickle rather than a sweep: each capture
    /// opens an archive and renders a page, and a library of twenty thousand
    /// should not do that at launch.
    func captureMissingCovers() {
        guard let store, let library else { return }
        Task { @MainActor [weak self] in
            let waiting = (try? store.downloadedIssuesLackingCover()) ?? []
            guard !waiting.isEmpty else { return }
            var captured = 0
            for issueID in waiting {
                let art = try? await Task.detached(priority: .utility) {
                    try library.captureCover(issueID: issueID)
                }.value
                if let art {
                    // Before the row points at it. A capture writes a new
                    // picture under a reference the caches may already hold
                    // an *older* picture for — `szpage:<id>`, and SQLite
                    // reuses the id of a deleted issue. Without this the
                    // freshly rendered cover is written to disk and never
                    // seen, because every lookup stops at the cache.
                    //
                    // Also what repairs a device that already went wrong:
                    // this runs for anything lacking a cover, so a shelf
                    // carrying stale artwork from an earlier build corrects
                    // itself rather than needing the cache cleared by hand.
                    CoverStore.shared.forget(art)
                    try? store.setCoverURL(art, issueID: issueID)
                    captured += 1
                }
            }
            guard let self, captured > 0 else { return }
            self.search(self.query)
        }
    }

    /// Reads a shipped catalogue into the library without holding the app up.
    ///
    /// The seed reports as it goes and the shelf is rebuilt at the end, so a
    /// large source arrives visibly rather than as a freeze followed by
    /// eighteen thousand rows. `announce` is for the switch — a reader who has
    /// just thrown it should be told what landed — and is off at launch, where
    /// nothing has changed and there is nothing to say.
    func seedInBackground(_ site: IssueSite, announce: Bool) {
        guard let store else { return }
        status = "loading \(site.display)…"
        Task { @MainActor [weak self] in
            // Bound once, here, on the main actor. `self` inside a `[weak self]`
            // closure is a *variable* — the runtime zeroes it on dealloc — so
            // reading it from the detached seed below is a shared mutable read
            // across concurrency domains, and an error under the Swift 6
            // language mode. The binding holds the model for the length of one
            // seed; the app owns it for the whole run regardless.
            let model = self
            let outcome: Result<SeedReport, Error>
            do {
                let report = try await Task.detached(priority: .utility) {
                    try store.seedCatalogue(for: site) { done, total in
                        // Cheap and rate-limited by the batch size: one
                        // message per four hundred rows, not per row.
                        Task { @MainActor in
                            guard let model, done < total else { return }
                            model.status = "loading \(site.display)… \(done) of \(total)"
                        }
                    }
                }.value
                outcome = .success(report)
            } catch {
                outcome = .failure(error)
            }
            guard let self else { return }
            // Whether the shelf below has anything new to show.
            let wroteRows: Bool
            switch outcome {
            case .success(let report):
                if announce, report.inserted > 0 {
                    // "issues", never "comics": these catalogues are
                    // magazines, and the word has to be true of both.
                    self.sourceNotice = SourceNotice(
                        site: site,
                        message: "\(report.inserted) \(site.display) issues are now in "
                               + "your library. You can hide them again in Settings.")
                }
                self.status = report.isEmpty ? "" : "\(site.display) ready"
                wroteRows = !report.isEmpty
            case .failure(let error):
                self.status = "\(site.display) catalogue unavailable: "
                            + "\(Library.reason(error))"
                // A seed that threw part-way has still committed whatever
                // batches it finished, and the report that would have said how
                // many is what the throw replaced. So this refreshes: the one
                // case where the shelf may have grown without anything being
                // able to say by how much.
                wroteRows = true
            }
            // Nothing written means nothing to rebuild, and that is the normal
            // case on every launch after the first: the stamp matches, the
            // seed skips, and the shelf is already showing exactly these rows.
            // Rebuilding anyway cost one full menu pass and one full re-sort
            // of the whole library *per enabled source* — fourteen of each, to
            // discover that nothing had changed.
            //
            // Safe to skip because neither caller depends on this refresh for
            // anything but the seed's own rows. A source being switched on is
            // a change to what is *visible*, and `sourcesChanged` refreshes
            // for that before this task is ever started; `start()` likewise
            // refreshes on its own once the launch seeds are away.
            guard wroteRows else { return }
            // The same rebuild a source switch does, and now the same call:
            // written out again here, it was one more copy to keep in step,
            // and fifteen seeds landing from one language switch each ran a
            // search of their own rather than sharing one.
            self.rebuildForVisibleSources()
        }
    }

    // MARK: - Comic Book Plus

    /// Reads the series page the reader is looking at onto the shelf.
    ///
    /// The whole page at once, the way a forum topic imports: a leaf page is
    /// one series, and every scan on it is a row. Nothing is downloaded — the
    /// issues arrive greyed out, like every other import.
    func importComicBookPlus(html: String) throws -> ComicBookPlusReport {
        guard let store else { throw ImportFailure.notReady }
        do {
            let report = try store.importComicBookPlus(page: html)
            refresh(note: report.isEmpty
                    ? "imported nothing new"
                    : "imported \(report.issues) issue\(report.issues == 1 ? "" : "s")")
            search(query)
            return report
        } catch {
            status = "import failed: \(Library.reason(error))"
            throw error
        }
    }

    // MARK: - BatCave

    /// Reads the series page the reader is looking at onto the shelf.
    ///
    /// The same shape as Comic Book Plus above: one page is one run, and every
    /// chapter on it is a row. Nothing is fetched — the issues arrive greyed
    /// out, like every other import.
    func importBatCave(html: String) throws -> BatCaveReport {
        guard let store else { throw ImportFailure.notReady }
        do {
            let report = try store.importBatCave(page: html)
            refresh(note: report.isEmpty
                    ? "imported nothing new"
                    : "imported \(report.issues) issue\(report.issues == 1 ? "" : "s")")
            search(query)
            return report
        } catch {
            status = "import failed: \(Library.reason(error))"
            throw error
        }
    }

    // MARK: - Archive.org

    /// Asks archive.org what an item holds, while the reader browses.
    ///
    /// Not the throttled transport the downloads share. That one exists to
    /// keep third-party file hosts from banning the device; this is
    /// archive.org's own metadata API being asked one small question per page
    /// opened, and a second and a half of latency on every tap would be paid
    /// by the person browsing for nobody's benefit.
    private let archive = ArchiveOrgClient(transport: URLSessionTransport())

    /// Items already asked about, so stepping back and forward through the
    /// browser's history costs nothing.
    ///
    /// A browsing convenience, not a store: it is dropped wholesale once it
    /// gets large rather than being aged entry by entry. Losing it costs one
    /// request the next time an item is opened, which is what the first visit
    /// cost anyway.
    private var archiveItems: [String: ArchiveOrgItem] = [:]

    /// How many items are remembered before the lot is dropped. A long
    /// afternoon's browsing is tens of items, not hundreds.
    private static let archiveCacheLimit = 200

    func archiveItem(_ identifier: String) async throws -> ArchiveOrgItem? {
        if let known = archiveItems[identifier] { return known }
        let item = try await archive.item(identifier)
        if let item {
            if archiveItems.count >= Self.archiveCacheLimit { archiveItems.removeAll() }
            archiveItems[identifier] = item
        }
        return item
    }

    /// What the library already holds for an item, so the browser can say so
    /// before the reader taps Import.
    func archiveRow(_ identifier: String) -> ArchiveRow? {
        (try? store?.archiveItem(identifier: identifier)) ?? nil
    }

    /// Puts an archive.org item on the shelf. Metadata and cover only.
    ///
    /// Nothing is downloaded: the reader is in a browser looking for the next
    /// item, and an issue arrives here the way every other issue does — greyed
    /// out, waiting to be asked for.
    @discardableResult
    func importFromArchive(_ item: ArchiveOrgItem,
                           file: ArchiveOrgItem.ReadableFile) throws -> ArchiveImport {
        guard let store else { throw ImportFailure.notReady }
        // Changing which file an issue points at makes whatever is on the
        // device a download of something else. Dropped here rather than left
        // behind, where the shelf would go on showing the issue as downloaded
        // and open the old file for ever.
        let url = file.url(item: item.identifier)
        if let existing = try store.archiveItem(identifier: item.identifier),
           existing.isDownloaded, existing.mirrorURL != url {
            removeFromDisk(try store.deleteDownload(issueID: existing.issueID))
            library?.discardPageThumbnails(forIssue: existing.issueID)
        }
        let done = try store.importArchiveItem(item, file: file)
        refresh(note: done.existed
                ? "updated “\(done.title)”"
                : "imported “\(done.title)” from Archive.org")
        return done
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
        /// Where the reader is, or was left last time. Zero means it never
        /// started. Moves when the grid is opened from the reader, so going
        /// back to the grid marks the page you are on rather than the one you
        /// arrived at.
        var atPage: Int
        /// Pages, where the source states them — so the grid can lay itself
        /// out while the archive is still being opened. Nil for anything from
        /// the forum, which never says.
        let pageCount: Int?
        /// Which of the two screens is up.
        var stage: Stage

        /// An issue always opens in the reader, where it left off. The grid is
        /// somewhere the reader goes from there — never something put in front
        /// of them on the way in.
        enum Stage: Equatable {
            /// The reader, open here.
            case reading(from: Int)
            /// The grid of pages.
            case picking
        }
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
    /// The comic's own first page, decoded at screen resolution.
    ///
    /// What the cover viewer shows for anything on disk. The stored cover is
    /// a 600px capture made for a shelf thumbnail, and the catalogued ones
    /// are 150×200 thumbnails from stripovi.com — either blown up to fill an
    /// iPad is a poor thing to look at. The pages themselves are already
    /// here, at the size the reader draws them.
    func firstPage(forIssue issueID: Int) async -> UIImage? {
        guard let library else { return nil }
        let scale = UIScreen.main.scale
        let maxPixel = Int(max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * scale)
        // Off the main actor: this opens the archive and decodes a full page.
        return await Task.detached(priority: .userInitiated) {
            guard let document = try? library.document(forIssue: issueID),
                  let page = try? document.page(0, maxPixelSize: maxPixel) else { return nil }
            return UIImage(cgImage: page)
        }.value
    }

    func read(_ issue: StoredIssue) {
        guard let library, issue.isDownloaded, reading == nil else { return }
        let name = issue.readerTitle
        let resumeAt = (try? store?.lastPage(forIssue: issue.id)) ?? 0

        // The row says downloaded; the device is the authority. The two come
        // apart on restore — swept at launch by `reconcileDownloads` — and
        // again for anything that goes missing while the app is running, and
        // this is the one place a reader meets the difference. Without it the
        // reader opens on a title, the issue is stamped as opened below, and
        // *then* it fails: an alert saying the issue was never downloaded,
        // about an issue that has just been moved to the top of the default
        // sort for having been read.
        guard library.isOnDevice(issueID: issue.id) else {
            try? library.forgetDownload(issueID: issue.id)
            refresh(note: "“\(name)” is no longer on this device")
            return
        }

        // Stamped here rather than once the pages have arrived: opening is
        // what the reader did, and an archive that turns out to be broken was
        // still opened. The shelf catches up when the reader closes — it is
        // rebuilt on the cover's `onDisappear` — so nothing is rearranged
        // underneath a comic that is still on screen.
        try? store?.markOpened(issueID: issue.id)

        // On screen straight away, holding nothing but a title and a place.
        // The reader shows its own progress until the pages arrive.
        reading = OpenComic(id: issue.id, document: nil, title: name, atPage: resumeAt,
                            pageCount: issue.pageCount, stage: .reading(from: resumeAt))

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
                self.failure = Failure(
                    title: "Could not open",
                    message: "“\(name)” could not be opened.\n\n" + Library.reason(error))
            }
        }
    }

    /// Look through the pages first.
    ///
    /// `from` is where the reader has got to, when the grid is opened from
    /// inside it. Without that the grid would mark and scroll to the page the
    /// issue was opened at, which after twenty minutes of reading is nowhere
    /// near where you are.
    func browsePages(from page: Int? = nil) {
        if let page { reading?.atPage = page }
        reading?.stage = .picking
    }

    /// Back to the page the grid was opened from.
    func backToReading() {
        guard let open = reading else { return }
        reading?.stage = .reading(from: open.atPage)
    }

    /// Start reading at the page picked out of the grid.
    func read(page: Int) {
        reading?.atPage = page
        reading?.stage = .reading(from: page)
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

    /// Puts the whole library back on the shelf.
    ///
    /// Every way the shelf can be narrowed, including the search field — which
    /// is the one people mean and the one that used to survive. "Show all"
    /// that leaves a query in the box shows a search, and the reader is left
    /// looking at three issues wondering which control lied to them.
    ///
    /// Downloaded goes too, for the same reason: it is a filter like any
    /// other, and a shelf still hiding everything not on the device is not
    /// showing all of anything.
    ///
    /// Sources are deliberately left alone. Switching a source off is a
    /// decision made in Settings about what this library holds at all, not a
    /// filter over it, and turning three of them back on is not what anyone
    /// means by this button.
    func showAll() {
        showRead = false
        showUnread = false
        showReading = false
        selectedHeroes = []
        selectedSeries = []
        selectedPublishers = []
        downloadedOnly = false
        // Last, and through `search` rather than by assigning `query`: the
        // field is bound to it, and this is what actually re-runs the query
        // and rebuilds the shelf.
        search("")
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
                  batch.considered > 0 else { break }
            found += batch.found
            status = "Looking for covers: \(total - store.coverlessIssueCount)/\(total)"
            search(query)
        }
        return found
    }

    /// Fetches the archive: resolve a mirror, download, decrypt if needed,
    /// verify it is really an archive. Falls through to the next mirror when
    /// one is dead.
    /// The set an issue belongs to, when its topic publishes them together.
    func set(for issue: StoredIssue) -> IssueSegment? {
        try? library?.segment(forIssue: issue.id)
    }

    func download(_ issue: StoredIssue, asSet: Bool = false) {
        guard let library, !downloading.contains(issue.id) else { return }
        // BatCave has no archive behind it: the site serves a reader, and the
        // pages are fetched one at a time by a web view. Nothing in the mirror
        // and host machinery below applies, so it takes its own route.
        if issue.site == .batcave {
            downloadBatCave(issue, library: library)
            return
        }
        let issueID = issue.id
        let name = issue.title ?? issue.code ?? "issue"

        // A host that has asked to be left alone is left alone here too, not
        // only on the source that discovered the idea.
        //
        // **Only when every mirror is waiting.** Two links under one issue are
        // usually alternatives on different hosts, and refusing the download
        // because the first of them is resting would take away a download that
        // used to succeed through the second. So this stops nothing that
        // `Library.fetch` could still have completed — it only declines the
        // case where there is no host left to ask.
        let cooldown = HostCooldown()
        let mirrors = (try? store?.liveMirrors(forIssue: issueID)) ?? []
        let waits = mirrors.compactMap { mirror in
            cooldown.remaining(forHost: URL(string: mirror.url)?.host ?? mirror.host)
        }
        if !mirrors.isEmpty, waits.count == mirrors.count, let longest = waits.max() {
            failure = Failure(
                title: "Still waiting",
                message: (mirrors.count == 1
                          ? "The host for “\(name)” asked to be left alone for a "
                          : "Every host for “\(name)” asked to be left alone for a ")
                       + "while, and there is \(RetryAfter.phrase(longest)) of that left."
                       + "\n\nNothing is wrong with the issue — trying again "
                       + "before then would only be refused.")
            return
        }

        // After the cooldown check above rather than beside BatCave's branch,
        // so this source inherits it: its mirror is a page on stripovi.com, so
        // the generic test already covers it and there is nothing to repeat.
        if issue.site == .stripovi {
            downloadStripovi(issue, library: library, cooldown: cooldown)
            return
        }

        // Here rather than beside BatCave's branch above, for the reason
        // Stripovi is: its mirror is the issue's own folder on popboks.com, so
        // the generic cooldown test already covers it and there is nothing to
        // repeat. What it cannot use is everything *below* — there is no
        // archive to fetch, only tiles to reassemble.
        if let magazine = issue.site.popboksMagazine {
            downloadPopBoks(issue, magazine: magazine, library: library, cooldown: cooldown)
            return
        }

        downloading.insert(issueID)
        progress[issueID] = 0
        status = "downloading “\(name)”…"

        // Progress crosses threads as plain numbers.
        //
        // The downloader calls back from whichever thread is moving bytes, so
        // its closure must not reach for the model: reading a captured, weak,
        // non-Sendable AppModel from concurrent code is a data race, and an
        // error under the Swift 6 language mode. A stream continuation *is*
        // Sendable and the scale below is a Double, so those two are all
        // the closure holds; the fractions are consumed on the main actor,
        // where the model lives.
        var sink: AsyncStream<TransferTick>.Continuation!
        let fractions = AsyncStream<TransferTick> { sink = $0 }
        let continuation = sink!
        // Read here rather than inside the closure: it is main-actor state
        // and the closure runs on whichever thread is moving bytes.
        let share = Self.transferShare
        let report: @Sendable (DownloadProgress) -> Void = { p in
            // expected is -1 when the server sends no length; with no total
            // there is no fraction to show.
            guard p.expected > 0 else { return }
            // Scaled to leave room for unpacking. The two are one wait as far
            // as the reader is concerned, so they share one bar.
            //
            // Capped, because the total is not always measured: a host that
            // knows a size the server will not declare passes on what the page
            // stated, and that figure is rounded. A bar that runs past its own
            // end looks broken in a way that being slightly early does not.
            let fraction = min(Double(p.received) / Double(p.expected), 1.0)
            continuation.yield(TransferTick(fraction: fraction * share,
                                            received: p.received, expected: p.expected))
        }

        Task { @MainActor [weak self] in
            for await tick in fractions {
                self?.progress[issueID] = tick.fraction
                self?.transferred[issueID] = TransferBytes(received: tick.received,
                                                           expected: tick.expected)
            }
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
                    self.stage[issueID] = .unpacking
                    self.status = "unpacking “\(name)”…"
                }
                try await Task.detached(priority: .userInitiated) {
                    try library.prepareForReading(issueID: issueID)
                }.value

                guard let self else { return }
                self.downloading.remove(issueID)
                self.progress[issueID] = nil
                self.transferred[issueID] = nil
                self.stage[issueID] = nil
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
                self.transferred[issueID] = nil
                self.stage[issueID] = nil

                // A host asking for a pause is not a download that failed.
                // Nothing is wrong with the link, so nothing is marked on the
                // shelf and the reader is told the one thing they can act on:
                // how long to leave it.
                if let refusal = error as? DownloadError, refusal.isRateLimited {
                    // Written down rather than only announced. This sentence
                    // used to say that trying again would be refused, while
                    // doing nothing whatever to prevent it — which left the
                    // reader's obvious next tap as the one action that turns a
                    // throttle into a block.
                    if case .rateLimited(let host, let wait) = refusal {
                        cooldown.begin(forHost: host, wait: wait)
                    }
                    self.search(self.query)
                    self.status = "asked to wait"
                    self.failure = Failure(
                        title: "Too many requests",
                        message: "“\(name)” was not downloaded.\n\n"
                               + refusal.description
                               + "\n\nNothing is wrong with the issue. Downloads "
                               + "from that host will wait until then before "
                               + "trying again.")
                    return
                }

                // Marked on the shelf, not just in an alert that is gone the
                // moment it is dismissed: some of these links really are dead,
                // and without a mark you retry them for ever.
                try? self.store?.setDownloadFailed(true, issueID: issueID)
                self.search(self.query)
                self.status = "download failed"
                // Summarised, not dumped: interpolating the raw error filled
                // the alert with NSError userInfo and buried the one sentence
                // that says what went wrong.
                self.failure = Failure(
                    title: "Download failed",
                    message: "“\(name)” could not be downloaded.\n\n"
                           + Library.reason(error))
            }
        }
    }

    /// Fetches a BatCave issue page by page.
    ///
    /// The other sources download one file and unpack it. This one has no file
    /// to download: the site serves a reader, so the pages are fetched
    /// individually — by a web view, because the site refuses anything that is
    /// not a browser — and written straight into the layout the reader already
    /// opens. There is nothing to unpack afterwards, which is why the bar runs
    /// the whole way here rather than stopping at `transferShare`.
    ///
    /// The bar is also honest for once: the page count is known before the
    /// first request, so the fraction is pages done over pages there are,
    /// rather than bytes against a length the server may not declare.
    private func downloadBatCave(_ issue: StoredIssue, library: Library) {
        guard let store else { return }
        let issueID = issue.id
        let name = issue.title ?? issue.code ?? "issue"

        guard let mirror = (try? store.liveMirrors(forIssue: issueID))?.first else {
            failure = Failure(title: "Download failed",
                              message: "\u{201C}\(name)\u{201D} has no reader page recorded. "
                                     + "Import the series again.")
            return
        }

        // The wait, actually waited. Before this the refusal ended at the
        // alert and nothing stopped the reader tapping Download again a second
        // later — which is the one action that turns "slow down" into
        // "blocked". Checked here so no request leaves the device at all.
        let cooldown = HostCooldown()
        if let left = cooldown.remaining(forHost: BatCave.host) {
            failure = Failure(
                title: "Still waiting",
                message: "\(BatCave.host) asked to be left alone for a while, "
                       + "and there is \(RetryAfter.phrase(left)) of that left.\n\n"
                       + "Nothing is wrong with \u{201C}\(name)\u{201D} — any pages "
                       + "already fetched are kept, and it will carry on from "
                       + "there afterwards.")
            return
        }

        downloading.insert(issueID)
        progress[issueID] = 0
        status = "fetching \u{201C}\(name)\u{201D}\u{2026}"

        Task { @MainActor [weak self] in
            // Held for the length of the fetch and released with it: a web
            // view kept alive past its download is a web view still holding
            // the site's page.
            let fetcher = BatCavePageFetcher()
            do {
                let result = try await fetcher.fetch(
                    readerURL: mirror.url,
                    into: library.directory(forIssue: issueID)) { done, total in
                        guard let self, total > 0 else { return }
                        self.progress[issueID] = Double(done) / Double(total)
                        self.stage[issueID] = .pages(done: done, total: total)
                        self.status = "fetching \u{201C}\(name)\u{201D} \u{2014} page \(done) of \(total)"
                    }

                guard let self else { return }
                try store.recordDownload(issueID: issueID, mirrorURL: mirror.url,
                                         path: result.file, bytes: result.bytes)
                self.downloading.remove(issueID)
                self.progress[issueID] = nil
                self.transferred[issueID] = nil
                self.stage[issueID] = nil
                try? store.setDownloadFailed(false, issueID: issueID)

                // The series poster stands in for every issue of a run until
                // this replaces it with the issue's own first page.
                let captured = try? await Task.detached(priority: .utility) {
                    try library.captureCover(issueID: issueID)
                }.value
                if let captured { try? store.setCoverURL(captured, issueID: issueID) }

                let mb = Double(result.bytes) / 1_048_576
                self.refresh(note: String(format: "fetched %d pages, %.1f MB",
                                          result.pages, mb))
            } catch {
                guard let self else { return }
                self.downloading.remove(issueID)
                self.progress[issueID] = nil
                self.transferred[issueID] = nil
                self.stage[issueID] = nil

                // A cancelled fetch is not a failure: the pages already on
                // disk are kept and the next attempt resumes from them, so
                // nothing is marked and nothing is said.
                if error is CancellationError {
                    self.search(self.query)
                    self.status = "stopped"
                    return
                }

                // The site asking for a pause is not a download that failed.
                // Nothing is wrong with the issue, so nothing is marked on the
                // shelf — a mark here would send the reader back to retry the
                // one thing that must not be retried. The pages already
                // fetched stay on disk, so trying again after the wait costs
                // only what is left.
                if let refusal = error as? DownloadError, refusal.isRateLimited {
                    // Written down, not just announced. The server's own
                    // number when it gave one; otherwise `HostCooldown`
                    // supplies the wait, because this site refuses with a bare
                    // 403 and names nothing.
                    var stated: TimeInterval?
                    if case .rateLimited(_, let wait) = refusal { stated = wait }
                    cooldown.begin(forHost: BatCave.host, wait: stated)

                    self.search(self.query)
                    self.status = "asked to wait"
                    let left = cooldown.remaining(forHost: BatCave.host) ?? 0
                    self.failure = Failure(
                        title: "Too many requests",
                        message: "\u{201C}\(name)\u{201D} was not finished.\n\n"
                               + refusal.description
                               + "\n\nDownloads from \(BatCave.host) will wait "
                               + "\(RetryAfter.phrase(left)) before trying again. "
                               + "The pages already fetched are kept, so it will "
                               + "carry on from where it stopped.")
                    return
                }

                try? store.setDownloadFailed(true, issueID: issueID)
                self.search(self.query)
                self.status = "download failed"
                self.failure = Failure(
                    title: "Download failed",
                    message: "\u{201C}\(name)\u{201D} could not be fetched.\n\n"
                           + Library.reason(error))
            }
        }
    }

    /// Fetches a PopBoks issue, a page at a time, a page being a grid of
    /// tiles.
    ///
    /// The slowest download in the app by a wide margin, and not because of
    /// its size: a 68-page issue is about 42 MB, which is unremarkable, and
    /// some 2,400 requests, which is not. So the progress line counts pages
    /// rather than bytes — bytes would sit near zero for minutes and then jump
    /// — and the fetcher does its own pacing.
    ///
    /// A dedicated transport rather than the shared throttled one, for the
    /// reason Stripovi uses one: that throttle spaces every host 1.5 seconds
    /// apart, which here would turn one issue into an hour.
    private func downloadPopBoks(_ issue: StoredIssue, magazine: PopBoks.Magazine,
                                 library: Library, cooldown: HostCooldown) {
        guard let store else { return }
        let issueID = issue.id
        let name = issue.title ?? issue.code ?? "issue"

        guard let code = issue.code, let archiveID = Int(code),
              let catalogue = try? PopBoksCatalog.shipped(magazine),
              let entry = catalogue.issues.first(where: { $0.id == archiveID }) else {
            failure = Failure(
                title: "Download failed",
                message: "\u{201C}\(name)\u{201D} is not in the shipped index. "
                       + "Switch the source off and on again to rebuild the shelf.")
            return
        }

        downloading.insert(issueID)
        progress[issueID] = 0
        status = "fetching \u{201C}\(name)\u{201D}\u{2026}"

        Task { @MainActor [weak self] in
            // Bound on the main actor for the same reason as `seedInBackground`:
            // the fetcher's progress closure runs off it, and must capture an
            // immutable optional rather than read a weak variable.
            let model = self
            do {
                let fetcher = PopBoksFetcher(transport: URLSessionTransport())
                let result = try await fetcher.fetch(
                    issue: entry, in: catalogue,
                    into: library.directory(forIssue: issueID)) { done, total in
                        Task { @MainActor in
                            guard let model, total > 0 else { return }
                            model.progress[issueID] = Double(done) / Double(total)
                            model.stage[issueID] = .pages(done: done, total: total)
                            model.status = "fetching \u{201C}\(name)\u{201D} \u{2014} "
                                         + "page \(done) of \(total)"
                        }
                    }

                guard let self else { return }
                try store.recordDownload(issueID: issueID, mirrorURL: issue.code ?? "",
                                         path: result.file, bytes: result.bytes)
                self.downloading.remove(issueID)
                self.progress[issueID] = nil
                self.transferred[issueID] = nil
                self.stage[issueID] = nil
                try? store.setDownloadFailed(false, issueID: issueID)

                // The archive's 150-pixel listing thumbnail stands in until
                // the issue's own first page can replace it.
                let captured = try? await Task.detached(priority: .utility) {
                    try library.captureCover(issueID: issueID)
                }.value
                if let captured { try? store.setCoverURL(captured, issueID: issueID) }

                let mb = Double(result.bytes) / 1_048_576
                var note = String(format: "fetched %d pages, %.1f MB", result.pages, mb)
                note += " (\(result.tiles) tiles)"
                // Pages the archive counts but does not hold. Said out loud
                // because the issue really is short and a reader who counts
                // will notice — and nothing here can fix it.
                if !result.missingFromSource.isEmpty {
                    let gone = result.missingFromSource.count
                    note += " \u{2014} \(gone) page\(gone == 1 ? "" : "s") "
                          + "missing from the archive"
                }
                // A page the archive holds all but a corner of. Rare — one
                // known case in 208 issues — and worth saying, because that
                // page really does have a white patch on it and nothing here
                // can mend it.
                if result.blankTiles > 0 {
                    note += " \u{2014} \(result.blankTiles) missing "
                          + "tile\(result.blankTiles == 1 ? "" : "s") left blank"
                }
                self.refresh(note: note)
            } catch {
                guard let self else { return }
                self.downloading.remove(issueID)
                self.progress[issueID] = nil
                self.transferred[issueID] = nil
                self.stage[issueID] = nil

                if error is CancellationError {
                    self.search(self.query)
                    self.status = "stopped"
                    return
                }

                if let refusal = error as? DownloadError, refusal.isRateLimited {
                    var stated: TimeInterval?
                    if case .rateLimited(_, let wait) = refusal { stated = wait }
                    cooldown.begin(forHost: PopBoks.host, wait: stated)
                    self.search(self.query)
                    self.status = "asked to wait"
                    let left = cooldown.remaining(forHost: PopBoks.host) ?? 0
                    self.failure = Failure(
                        title: "Too many requests",
                        message: "\u{201C}\(name)\u{201D} was not finished.\n\n"
                               + refusal.description
                               + "\n\nDownloads from \(PopBoks.host) will wait "
                               + "\(RetryAfter.phrase(left)) before trying again. The "
                               + "pages already fetched are kept.")
                    return
                }

                try? store.setDownloadFailed(true, issueID: issueID)
                self.search(self.query)
                self.status = "download failed"
                self.failure = Failure(
                    title: "Download failed",
                    message: "\u{201C}\(name)\u{201D} could not be fetched.\n\n"
                           + Library.reason(error))
            }
        }
    }

    /// Fetches a Stripovi comic, a page at a time.
    ///
    /// The simplest of the three fetchers, because this site is behind
    /// nothing: no web view, no session, no challenge — just requests, spaced
    /// out. Everything it needs is in the shipped index, including the rule
    /// that builds each page's address.
    ///
    /// A dedicated transport rather than the shared throttled one. That
    /// throttle spaces every host in the app 1.5 seconds apart, which is right
    /// for probing file hosts and wrong for a run of 126 pages — it would turn
    /// the longest comic into three minutes for no benefit to a site that has
    /// never once refused us. `StripoviFetcher` does its own pacing.
    private func downloadStripovi(_ issue: StoredIssue, library: Library,
                                  cooldown: HostCooldown) {
        guard let store else { return }
        let issueID = issue.id
        let name = issue.title ?? issue.code ?? "issue"

        guard let code = issue.code, let comicID = Int(code),
              let catalogue = try? StripoviCatalog.shipped(),
              let comic = catalogue.comics.first(where: { $0.id == comicID }) else {
            failure = Failure(
                title: "Download failed",
                message: "\u{201C}\(name)\u{201D} is not in the shipped index. "
                       + "Switch the source off and on again to rebuild the shelf.")
            return
        }

        downloading.insert(issueID)
        progress[issueID] = 0
        status = "fetching \u{201C}\(name)\u{201D}\u{2026}"

        Task { @MainActor [weak self] in
            // Bound on the main actor for the same reason as `seedInBackground`:
            // the fetcher's progress closure runs off it, and must capture an
            // immutable optional rather than read a weak variable.
            let model = self
            do {
                let fetcher = StripoviFetcher(transport: URLSessionTransport())
                let result = try await fetcher.fetch(
                    comic: comic, in: catalogue,
                    into: library.directory(forIssue: issueID)) { done, total in
                        Task { @MainActor in
                            guard let model, total > 0 else { return }
                            model.progress[issueID] = Double(done) / Double(total)
                            model.stage[issueID] = .pages(done: done, total: total)
                            model.status = "fetching \u{201C}\(name)\u{201D} \u{2014} "
                                         + "page \(done) of \(total)"
                        }
                    }

                guard let self else { return }
                try store.recordDownload(issueID: issueID, mirrorURL: issue.code ?? "",
                                         path: result.file, bytes: result.bytes)
                self.downloading.remove(issueID)
                self.progress[issueID] = nil
                self.transferred[issueID] = nil
                self.stage[issueID] = nil
                try? store.setDownloadFailed(false, issueID: issueID)

                // The site's listing tile stands in until the comic's own
                // first page can replace it.
                let captured = try? await Task.detached(priority: .utility) {
                    try library.captureCover(issueID: issueID)
                }.value
                if let captured { try? store.setCoverURL(captured, issueID: issueID) }

                let mb = Double(result.bytes) / 1_048_576
                // The shipped rule having gone stale is said out loud. It is
                // the only place anyone would ever find out, and the fix is a
                // rebuilt catalogue rather than anything the reader can do.
                var note = String(format: "fetched %d pages, %.1f MB", result.pages, mb)
                // Pages the site counts but does not have. Said out loud
                // because the comic really is short and a reader who counts
                // will notice — and nothing here can fix it, the file is not
                // on the server.
                if !result.missingFromSource.isEmpty {
                    let gone = result.missingFromSource.count
                    note += " — \(gone) page\(gone == 1 ? "" : "s") "
                          + "missing from the site"
                }
                if result.resolvedFromSite {
                    note += " — page addresses read from the site, "
                          + "the shipped index is out of date"
                }
                self.refresh(note: note)
            } catch {
                guard let self else { return }
                self.downloading.remove(issueID)
                self.progress[issueID] = nil
                self.transferred[issueID] = nil
                self.stage[issueID] = nil

                if error is CancellationError {
                    self.search(self.query)
                    self.status = "stopped"
                    return
                }

                if let refusal = error as? DownloadError, refusal.isRateLimited {
                    var stated: TimeInterval?
                    if case .rateLimited(_, let wait) = refusal { stated = wait }
                    cooldown.begin(forHost: Stripovi.host, wait: stated)
                    self.search(self.query)
                    self.status = "asked to wait"
                    let left = cooldown.remaining(forHost: Stripovi.host) ?? 0
                    self.failure = Failure(
                        title: "Too many requests",
                        message: "\u{201C}\(name)\u{201D} was not finished.\n\n"
                               + refusal.description
                               + "\n\nDownloads from \(Stripovi.host) will wait "
                               + "\(RetryAfter.phrase(left)) before trying again. The "
                               + "pages already fetched are kept.")
                    return
                }

                try? store.setDownloadFailed(true, issueID: issueID)
                self.search(self.query)
                self.status = "download failed"
                self.failure = Failure(
                    title: "Download failed",
                    message: "\u{201C}\(name)\u{201D} could not be fetched.\n\n"
                           + Library.reason(error))
            }
        }
    }

    /// Drops the archive but keeps the metadata, so it can be fetched again
    /// without spending another Like on a re-import.
    func deleteDownload(_ issue: StoredIssue) {
        guard let store else { return }
        // Never for one of the reader's own files: removing "the download"
        // for one means deleting the file itself, and that question is only
        // ever put as Delete. No button raises this for a local row — every
        // one of them was changed to say Delete File — and this is here so
        // that stays true of the next one.
        guard issue.site != .local else { return }
        do {
            // Issues published as one download share a directory, so there is
            // no removing one of them on its own — the reader has already been
            // told that and agreed.
            if let library, try library.removeSegmentDownload(issueID: issue.id) {
                refresh(note: "removed the set")
                return
            }
            removeFromDisk(try store.deleteDownload(issueID: issue.id))
            // The pages they were rendered from have gone with it.
            library?.discardPageThumbnails(forIssue: issue.id)
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
            // The row is going, so everything keyed on its id goes with it.
            // For a download `removeFromDisk` has already taken the folder;
            // for a local file the pages are elsewhere and the file itself
            // was the only thing that line could reach. The artwork goes in
            // both cases: SQLite gives the next row this id.
            library?.discardUnpacked(forIssue: issue.id)
            discardCover(forIssue: issue.id)
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
            library?.discardAllPageThumbnails()
            refresh(note: "removed \(files.count) download\(files.count == 1 ? "" : "s")")
        } catch {
            status = "remove failed: \(error)"
        }
    }

    /// How many of the comics currently on the shelf are downloaded.
    ///
    /// Not counting the reader's own files, which Remove Visible passes over:
    /// a warning that offers to free eleven downloads and then frees seven is
    /// a warning nobody will read twice.
    var visibleDownloadedCount: Int {
        results.filter { $0.isDownloaded && $0.site != .local }.count
    }

    /// How many issues in the whole library a delete may actually take.
    ///
    /// Less the reader's own files, which it passes over: a warning that
    /// counts them and then leaves them is a warning that has lied about the
    /// only number in it.
    var deletableCount: Int {
        max(issueCount - shippedCount - localFileTotals.count, 0)
    }

    /// The same question about the shelf as it stands.
    var visibleDeletableCount: Int {
        results.filter { !$0.isCatalogued && $0.site != .local }.count
    }

    /// Whether any downloaded comic on the shelf belongs to a set, so the
    /// warning can say that removing it reaches issues that are not shown.
    var visibleDownloadsTouchASet: Bool {
        results.contains { $0.isDownloaded && set(for: $0) != nil }
    }

    /// Removes the downloads for everything currently on the shelf.
    ///
    /// The middle ground the library was missing. One at a time is tedious
    /// across a run of two hundred, and everything at once is far too broad —
    /// but the shelf is already a selection the reader has made, with a
    /// search, a series filter or "downloaded only", so acting on exactly
    /// what is shown needs no separate selection mode to build first.
    ///
    /// One refresh at the end rather than one per issue: `refresh` re-runs
    /// the query and rebuilds the shelf, which on a few hundred rows is the
    /// whole cost of the operation.
    func removeVisibleDownloads() {
        guard let store else { return }
        do {
            var removed = 0
            // Local files are passed over here as they are in Remove All:
            // `deleteDownload` hands back the recorded path for removal, and
            // for one of these that path is the reader's own file in their
            // own folder. There is no download to reclaim — the file is the
            // issue — so there is nothing here for it to do but damage.
            for issue in results where issue.isDownloaded && issue.site != .local {
                // A set shares one directory, so removing any member removes
                // every issue in it — including any the shelf is not showing.
                if let library, try library.removeSegmentDownload(issueID: issue.id) {
                    removed += 1
                    continue
                }
                removeFromDisk(try store.deleteDownload(issueID: issue.id))
                library?.discardPageThumbnails(forIssue: issue.id)
                removed += 1
            }
            refresh(note: "removed \(removed) download\(removed == 1 ? "" : "s")")
        } catch {
            status = "remove failed: \(error)"
        }
    }

    /// Deletes everything currently on the shelf, downloads and all.
    func deleteVisible() {
        guard let store else { return }
        do {
            // Snapshotted before the first delete: `results` is republished by
            // anything that touches the library, and a loop over a collection
            // being rebuilt underneath it would miss rows.
            //
            // Shipped rows are passed over rather than refused: nothing can
            // bring one back, so a bulk delete takes only what an Import
            // returns.
            // Local files are passed over as well as shipped rows, and for
            // the mirror-image reason: a shipped row cannot be got back at
            // all, and one of these can only be got back by fetching a cable.
            // Neither is what a reader clearing the shelf has agreed to.
            let doomed = results.filter { !$0.isCatalogued && $0.site != .local }
            for issue in doomed {
                removeFromDisk(try store.delete(issueID: issue.id))
                library?.discardUnpacked(forIssue: issue.id)
                discardCover(forIssue: issue.id)
            }
            refresh(note: "deleted \(doomed.count) issue\(doomed.count == 1 ? "" : "s")")
        } catch {
            status = "delete failed: \(error)"
        }
    }

    func deleteEverything() {
        guard let store else { return }
        do {
            // What this is actually about to take: not the reader's own
            // files, which it passes over and which are asked about next.
            // Counting them here reported "deleted 2 issues" for one.
            let count = deletableCount
            for file in try store.deleteImported() { removeFromDisk(file) }
            // Thumbnails for what is left are rebuilt from the archives still
            // on disk, so discarding the lot costs a redraw and never a
            // download.
            library?.discardAllPageThumbnails()
            refresh(note: "deleted \(count) issue\(count == 1 ? "" : "s")")
        } catch {
            status = "delete failed: \(error)"
        }
    }

    // MARK: - Local Files

    /// The folder the reader fills themselves — the app's Documents
    /// directory, which is what iOS shows in the Finder over a cable and
    /// under "On My iPad" in the Files app.
    ///
    /// Nothing the app downloads goes here; downloads live under Application
    /// Support. That separation is what lets a flat scan of this folder mean
    /// "the reader's issues" and nothing else.
    private let localFolder = Library.localFilesFolder()

    /// Notices files arriving and leaving while the app is in front of the
    /// reader — which is the ordinary case, because the iPad is plugged into
    /// the computer they are dragging from. Held for the life of the model;
    /// releasing it stops the watch.
    private var localWatcher: LocalFilesWatcher?

    /// Sizes as the last scan saw them.
    ///
    /// What tells a file that has finished copying from one still arriving —
    /// see `LocalFiles.settled`. Kept here rather than in the store because
    /// it describes this run of the app watching a folder change, not
    /// anything about the library.
    private var lastSeenSizes: [String: Int64] = [:]

    /// A re-scan owed to a file that was still being written when the last
    /// one ran. Cancelled and replaced rather than stacked, so a folder full
    /// of arriving files owes exactly one.
    private var localRescan: Task<Void, Never>?

    /// How many of the reader's own files are on the shelf, and what they
    /// weigh. Read on demand rather than published: the one screen that asks
    /// is a confirmation, and it wants the answer at the moment it is put.
    var localFileTotals: (count: Int, bytes: Int64) {
        store?.localFileTotals ?? (0, 0)
    }

    /// Brings the shelf into line with the folder.
    ///
    /// Run at launch and again every time the app comes back to the front,
    /// because the folder changes while the app is not looking: that is the
    /// whole point of it. A reader who drags four issues in over the cable
    /// and unplugs expects to find four issues, and one who drags an issue to
    /// the Trash expects it gone.
    ///
    /// Silent when nothing changed, which is nearly always. `refresh` re-runs
    /// the search and rebuilds the filter menus, and doing that on every
    /// return to the foreground would be a visible stutter bought for nothing.
    func scanLocalFiles() {
        guard let store, let localFolder else { return }
        // The dump an earlier build wrote into Documents, when nothing showed
        // that folder to anyone. It is invisible to the scan — not a readable
        // extension — but perfectly visible in the Finder, where it is a file
        // the reader did not put there sitting among their issues. Removed
        // once, on the first launch of a build that can see it.
        try? FileManager.default.removeItem(
            at: localFolder.appendingPathComponent("last-import.html"))
        do {
            // Everything in the folder, and then only the part of it that has
            // finished arriving. The rest is left for the re-scan below: a
            // row written from half a file is an issue that will not open.
            let all = LocalFiles.scan(localFolder)
            let (ready, waiting) = LocalFiles.settled(all, against: lastSeenSizes)
            lastSeenSizes = Dictionary(all.map { ($0.name, $0.bytes) },
                                       uniquingKeysWith: { first, _ in first })
            if waiting.isEmpty {
                localRescan?.cancel()
                localRescan = nil
            } else {
                scheduleLocalRescan()
            }
            // Removals are worked out from the whole folder, not from the
            // part of it that settled: a file being copied over an existing
            // one is not a file that has gone.
            let report = try store.reconcileLocalFiles(
                ready, present: Set(all.map(\.name)))
            // Pages unpacked from a file that has gone, or that came back
            // holding different bytes, are pages of an issue that is no
            // longer there. The row's artwork goes with it for the same
            // reason — and because the next row written takes its id.
            for id in report.removed {
                library?.discardUnpacked(forIssue: id)
                discardCover(forIssue: id)
            }
            for id in report.replaced {
                library?.discardUnpacked(forIssue: id)
                discardCover(forIssue: id)
            }
            guard !report.isEmpty else { return }
            refresh(note: Self.scanNote(report))
            // A file that arrived with no artwork gets it from its own first
            // page, exactly as a finished download does.
            captureMissingCovers()
        } catch {
            status = "reading your files failed: \(Library.reason(error))"
        }
    }

    /// What a scan says for itself, in the status line.
    ///
    /// Only the halves that happened: "added 3" after a drag in, "removed 1"
    /// after a delete in the Finder, and both when a reader did their tidying
    /// in one session at the computer.
    static func scanNote(_ report: LocalFilesReport) -> String {
        var parts: [String] = []
        if report.added > 0 { parts.append("added \(report.added)") }
        if !report.removed.isEmpty { parts.append("removed \(report.removed.count)") }
        if !report.replaced.isEmpty { parts.append("replaced \(report.replaced.count)") }
        let what = parts.joined(separator: ", ")
        let total = report.added + report.removed.count + report.replaced.count
        return "\(IssueSite.local.display.lowercased()): \(what) "
            + "file\(total == 1 ? "" : "s")"
    }

    /// Starts watching the folder, so a file dragged in over the cable shows
    /// up on the shelf without the app being restarted.
    ///
    /// Every change lands back here in `scanLocalFiles`, which is the same
    /// path the launch and foreground scans take — the watch decides *when*
    /// to look, and nothing about what is found.
    private func watchLocalFiles() {
        guard localWatcher == nil, let localFolder else { return }
        localWatcher = LocalFilesWatcher(directory: localFolder) { [weak self] in
            Task { @MainActor in self?.scanLocalFiles() }
        }
    }

    /// Looks again shortly, for a file that was still being written.
    ///
    /// The copy of a large issue takes a while and its directory entry
    /// appears at the start of it, so the event that woke the watcher arrives
    /// long before the file is whole. Nothing else will wake it — the writes
    /// that follow are to the file, not to the folder — so the second look
    /// has to be asked for.
    private func scheduleLocalRescan() {
        localRescan?.cancel()
        localRescan = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(LocalFiles.settleTime))
            guard !Task.isCancelled else { return }
            self?.scanLocalFiles()
        }
    }

    /// Takes in a file handed to the app from outside — AirDrop, the share
    /// sheet, or Open With in the Files app.
    ///
    /// Copied into the folder rather than read where it lies. A file opened
    /// in place belongs to whoever handed it over: iCloud can evict it, the
    /// other app can delete it, and the shelf would be holding a row that
    /// stops working for reasons nothing here can see. Once it is in the
    /// folder it is the same thing as a file dragged in over a cable, and one
    /// scan puts it on the shelf.
    func adoptLocalFile(at url: URL) {
        guard let localFolder else { return }
        guard LocalFiles.isReadable(url.lastPathComponent) else {
            status = "\(url.lastPathComponent) is not a file this app can open"
            return
        }
        do {
            _ = try Self.take(url, into: localFolder)
            scanLocalFiles()
        } catch {
            status = "could not take in \(url.lastPathComponent): "
                   + "\(Library.reason(error))"
        }
    }

    /// Takes in files the reader chose through Import ▸ From Device.
    ///
    /// The way in for everything already sitting on the iPad. AirDrop is the
    /// case that made it necessary: iOS routes an AirDropped document to the
    /// Files app's Downloads folder rather than to whichever app claims the
    /// type, and no declaration this app can make changes that — which left
    /// the reader holding a comic on their own device with no way to hand it
    /// over except the share sheet, if they thought to look there.
    ///
    /// A copy, never a move, and that is the whole difference from the Inbox
    /// case in `take`. These files are the reader's, sitting where they put
    /// them, and Downloads is a folder they may well go back to.
    ///
    /// One scan for the batch. Picking eleven issues should read as one thing
    /// happening, not eleven.
    func adoptLocalFiles(_ urls: [URL]) {
        guard let localFolder, !urls.isEmpty else { return }
        Task { @MainActor [weak self] in
            await self?.takeIn(urls, into: localFolder)
        }
    }

    private func takeIn(_ urls: [URL], into localFolder: URL) async {
        var refused: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            guard LocalFiles.isReadable(name) else {
                refused.append(name)
                continue
            }
            // Held across both the fetch and the copy, which is why this is
            // here rather than inside `take`: a file that is still in iCloud
            // needs the same access to be downloaded as to be read.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                if Self.isWaitingOnICloud(url) {
                    status = "fetching \(name) from iCloud…"
                    try await Self.fetchFromICloud(url)
                }
                // Off the main actor: these are hundreds of megabytes and the
                // shelf should not stop scrolling for the length of a copy.
                _ = try await Task.detached(priority: .userInitiated) {
                    try Self.copyIn(url, into: localFolder)
                }.value
            } catch {
                refused.append(name)
            }
        }
        // The scan is what writes the rows and says what arrived, so it goes
        // first and the complaint goes after it — a refusal is the thing the
        // reader needs to see, and a status set before this would be
        // overwritten by the scan's own note.
        scanLocalFiles()
        guard !refused.isEmpty else { return }
        status = refused.count == 1
            ? "could not take in \(refused[0])"
            : "could not take in \(refused.count) of \(urls.count) files"
    }

    /// Takes in files dragged onto the shelf from another app.
    ///
    /// The iPad gesture for this, and the one a reader reaches for first with
    /// Files open beside the app in Split View. It arrives as a promise
    /// rather than a file: the URL below is real only for as long as the
    /// handler that produced it runs, which is why the copy happens there,
    /// off the main actor, rather than being handed back to it.
    func adoptDropped(_ providers: [NSItemProvider]) {
        guard let localFolder else { return }
        for provider in providers {
            provider.loadInPlaceFileRepresentation(
                forTypeIdentifier: UTType.data.identifier
            ) { url, _, _ in
                guard let url, LocalFiles.isReadable(url.lastPathComponent) else { return }
                let taken = try? Self.take(url, into: localFolder)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if taken == nil {
                        self.status = "could not take in \(url.lastPathComponent)"
                    }
                    self.scanLocalFiles()
                }
            }
        }
    }

    /// Puts one arriving file in the folder, and answers what it is called
    /// there.
    ///
    /// Synchronous and off the actor on purpose. A dropped file is handed
    /// over as a URL that stops resolving the moment the completion handler
    /// which produced it returns, so this cannot wait for a hop to the main
    /// actor — by the time it arrived there would be nothing to copy.
    nonisolated private static func take(_ url: URL, into folder: URL) throws -> String {
        // A URL from another app's container comes security-scoped, and
        // reading it without asking fails with a permission error that reads
        // like a missing file. Balanced immediately: the copy below is the
        // only thing that needs the access.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try copyIn(url, into: folder)
    }

    /// Whether the picker handed over a file that is not on the device yet.
    ///
    /// iCloud Drive shows everything the account holds, downloaded or not, and
    /// a file that is not downloaded is a placeholder — the name and the size
    /// are real, the bytes are not there. Copying one gives an empty or
    /// missing file rather than an error, so it has to be asked about first.
    nonisolated private static func isWaitingOnICloud(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey,
                                         .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    /// How long a fetch is given before it is called a failure.
    ///
    /// Generous on purpose: these are comic archives, hundreds of megabytes
    /// each, and a phone on a slow connection is the ordinary case rather
    /// than the pathological one. It exists so a fetch that will never finish
    /// — the file withdrawn, the account signed out — ends in a message
    /// instead of a spinner nothing clears.
    nonisolated private static let iCloudTimeout: TimeInterval = 15 * 60

    /// Pulls a file down from iCloud and waits for it to land.
    ///
    /// Polled rather than observed. The proper instrument is an
    /// `NSMetadataQuery`, which is a live index of the whole ubiquity
    /// container and has to be started, filtered and torn down; this asks one
    /// file one question twice a second, and the question is answered from
    /// local metadata rather than the network. For an import the reader is
    /// sitting in front of, that is the cheaper of the two by a wide margin.
    nonisolated private static func fetchFromICloud(_ url: URL) async throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(iCloudTimeout)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            if !isWaitingOnICloud(url) { return }
        }
        throw CocoaError(.userCancelled)
    }

    /// The copy itself, with the security scope already held by the caller.
    ///
    /// Split out from `take` for the one case that has to do something
    /// *between* opening the scope and copying: a file still in iCloud has to
    /// be fetched first, and the fetch needs the same access the copy does.
    nonisolated private static func copyIn(_ url: URL, into folder: URL) throws -> String {
        let name = LocalFiles.vacantName(for: url.lastPathComponent, in: folder)
        let destination = folder.appendingPathComponent(name)
        let fm = FileManager.default
        // iOS drops what another app hands over into Documents/Inbox and
        // leaves it there for good. Moved rather than copied when it is
        // already ours, so the same issue is not on the device twice — once
        // on the shelf and once in a folder nothing ever empties.
        if LocalFiles.isInInbox(url, of: folder) {
            try fm.moveItem(at: url, to: destination)
        } else {
            try fm.copyItem(at: url, to: destination)
        }
        return name
    }

    /// Throws away an issue's artwork — the file and every cache holding it.
    ///
    /// One method because these have to happen together and there are five
    /// places that need them. Deleting the file alone was the bug: the shelf
    /// went on drawing the old picture out of `CoverStore`, which nothing
    /// ever evicted.
    ///
    /// The reference is `szpage:<id>`, and the id is the whole problem —
    /// SQLite reuses the rowid of a deleted issue, so the next comic added
    /// inherits the last one's cache key along with its number. See
    /// `CoverStore.forget`.
    private func discardCover(forIssue id: Int) {
        library?.discardCover(forIssue: id)
        CoverStore.shared.forget(Library.coverReference(issueID: id))
    }

    /// Deletes the reader's own files, having been asked to.
    ///
    /// Only ever from the question put after Delete Library. Nothing else in
    /// the app deletes these in bulk: they came off a computer over a cable
    /// and no import brings one back, so this is the one path that removes
    /// them and it is spelled out to the reader first.
    func deleteLocalFiles() {
        guard let store else { return }
        do {
            let files = try store.deleteLocalIssues()
            for (id, file) in files {
                // The file itself, and never the folder it sits in: that
                // folder is the reader's, and their next issue goes in it.
                try? FileManager.default.removeItem(at: file)
                library?.discardUnpacked(forIssue: id)
                discardCover(forIssue: id)
            }
            refresh(note: "deleted \(files.count) local file\(files.count == 1 ? "" : "s")")
        } catch {
            status = "delete failed: \(Library.reason(error))"
        }
    }

    /// The archive and the directory it was unpacked into. Removing the row
    /// without the bytes would silently keep the disk full.
    ///
    /// The folder only when it is one of ours. A downloaded archive sits
    /// alone in `comics/<id>`, so deleting the folder is how the unpacked
    /// pages go with it. A local file sits in the reader's own folder among
    /// their other issues — and this line, written when every path led to the
    /// former, would have deleted the lot.
    private func removeFromDisk(_ file: URL?) {
        guard let file else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        guard library?.owns(folder) == true else { return }
        try? fm.removeItem(at: folder)
    }

    private func refresh(note: String) {
        issueCount = store?.issueCount ?? 0
        downloadedCount = store?.downloadedCount ?? 0
        shippedCount = store?.shippedCount ?? 0
        localFileCount = store?.localFileTotals.count ?? 0
        // Before the search below it, which sorts on these when the shelf is
        // in Scan Size order.
        downloadedSizes = store?.downloadedBytesByIssue ?? [:]
        diskUsage = library?.diskUsage ?? 0
        freeSpace = Self.freeSpace()
        // A newly imported page can bring a series the menu has not offered.
        refreshSourceMenus()
        search(query)
        status = note
    }

    func mirrors(for issue: StoredIssue) -> [MirrorLink] {
        (try? store?.mirrors(forIssue: issue.id)) ?? []
    }
}
