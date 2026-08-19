import SwiftUI
import SZKit

/// Browse Comic Book Plus, find a title, tap Import.
///
/// Between the two browsers the app already has. The forum importer reads
/// whatever page you are standing on and hopes it is a topic; the archive.org
/// one reads nothing off the page at all, because that site answers every
/// question as JSON. This site is neither: its pages carry the whole listing
/// as schema.org microdata, so the page *is* the answer — but only one kind of
/// page is, and the reader has to be told which.
///
/// So Import is dark on the front page, on a search result and on a single
/// book, and lights up on a title's own page. That is the same rule the
/// archive.org browser follows, for the same reason: a page listing one series
/// names exactly what would be imported, and the others do not.
struct ComicBookPlusBrowserView: View {

    @ObservedObject var model: AppModel
    /// Asks for the mobile layout, and gets the desktop one anyway.
    ///
    /// Measured rather than assumed: the site serves the same fixed-width
    /// table whichever user agent it is given, so a phone scrolls sideways
    /// through it either way and this flag changes nothing visible. It is set
    /// this way because asking for the phone layout is the honest request from
    /// a phone, not because it fixes the width — if the site ever grows a
    /// responsive skin, this is already pointed at it.
    ///
    /// StripZona is the opposite case and asks for the desktop site on
    /// purpose: its mobile skin hides the post content that import reads.
    @StateObject private var browser = BrowserModel(fence: .comicBookPlus, desktopSite: false)

    /// Whether the page on screen is one that can be imported.
    ///
    /// Held rather than asked for on demand, because answering means reading
    /// the live DOM across the WebKit bridge and the button's enabled state is
    /// evaluated on every layout pass.
    @State private var isLeaf = false
    @State private var checking = false
    @State private var importing = false
    @State private var report: Report?
    @State private var errorText: String?

    private struct Report {
        let series: String
        let inserted: Int
        let updated: Int
    }

    var body: some View {
        BrowserScreen(model: browser,
                      fallbackTitle: IssueSite.comicbookplus.display) {
            importButton
        } banner: {
            banner
        }
        .onAppear { if browser.url == nil { browser.load(ComicBookPlus.indexURL) } }
        // The URL is what changes when the reader moves, and it changes before
        // the new page has finished arriving — so the check is also repeated
        // when loading finishes, below.
        .onChange(of: browser.url) { _ in
            clearBanner()
            Task { await checkForListing() }
        }
        .onChange(of: browser.isLoading) { loading in
            if !loading { Task { await checkForListing() } }
        }
    }

    // MARK: - The button

    private var importButton: some View {
        Button {
            Task { await performImport() }
        } label: {
            if importing || checking {
                ProgressView()
            } else {
                // The same explicit stack as the other two importers: a
                // toolbar collapses a Label to its icon whatever the label
                // style says, and the word is what makes this recognisably
                // the button from the shelf.
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import")
                }
                .font(.headline)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isLeaf || importing || browser.isLoading)
    }

    // MARK: - Reading the page

    /// Whether what is on screen lists a series.
    ///
    /// Asks the parser rather than the address. A `?cid=` URL is a category
    /// as often as it is a title — the publisher index and the genre pages
    /// wear the same query — so the address cannot answer this, and the thing
    /// that can is the markup the import would read anyway.
    private func checkForListing() async {
        checking = true
        defer { checking = false }
        guard let html = await browser.currentHTML() else {
            isLeaf = false
            return
        }
        isLeaf = ComicBookPlusPage.isLeaf(html)
    }

    private func performImport() async {
        importing = true
        defer { importing = false }
        clearBanner()

        guard let html = await browser.currentHTML() else {
            errorText = "Could not read the page."
            return
        }
        do {
            let result = try model.importComicBookPlus(html: html)
            report = Report(series: result.series,
                            inserted: result.inserted, updated: result.updated)
        } catch {
            // The real reason rather than a guess at it — the same lesson the
            // forum importer records having learned.
            errorText = SZKit.Library.reason(error)
        }
    }

    // MARK: - The banner

    @ViewBuilder private var banner: some View {
        if let errorText {
            BrowserBanner(icon: "exclamationmark.triangle.fill", tint: .orange,
                          title: "Import failed", detail: errorText,
                          dismiss: clearBanner)
        } else if let report {
            BrowserBanner(
                icon: report.inserted > 0 ? "checkmark.circle.fill" : "questionmark.circle.fill",
                tint: report.inserted > 0 ? .green : .orange,
                title: title(for: report),
                detail: detail(for: report),
                dismiss: clearBanner)
        }
    }

    /// What the import did, counted the way the reader would count it.
    private func title(for report: Report) -> String {
        report.inserted > 0
            ? "Imported \(report.inserted) issue\(report.inserted == 1 ? "" : "s")"
            : "Nothing new imported"
    }

    /// The series is named because the reader may have moved on, and the
    /// second sentence answers the question a greyed-out shelf row provokes.
    private func detail(for report: Report) -> String {
        if report.inserted == 0 {
            return "\(report.series) — every issue on this page is already on "
                 + "your shelf."
        }
        let known = report.updated > 0
            ? " \(report.updated) were already there."
            : ""
        return "\(report.series).\(known) Only the details are imported; "
             + "download each issue from your shelf when you want it."
    }

    private func clearBanner() {
        report = nil
        errorText = nil
    }
}
