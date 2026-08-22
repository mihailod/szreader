import SwiftUI
import SZKit

/// Browse BatCave, open a title, tap Import.
///
/// The third browser of this shape, and it follows the Comic Book Plus one
/// closely: Import is dark until the page on screen lists a run, and lights up
/// on a title's own page. Front page, category and search result all leave it
/// off, because none of them names what would be imported.
///
/// The gate is asked in two stages, cheap first. The address settles the
/// question for everything except a title page — only `/<id>-<slug>.html` can
/// be one — and reading the whole document across the WebKit bridge is worth
/// doing only once the address has said it might be. The site's front page and
/// its category listings are large, and this runs on every navigation.
struct BatCaveBrowserView: View {

    @ObservedObject var model: AppModel

    /// The mobile layout, which is the honest request from a phone and costs
    /// nothing either way: what the import reads is `window.__DATA__`, which
    /// the server inlines whatever skin it serves. Unlike StripZona, whose
    /// mobile skin hides the post content the import needs.
    @StateObject private var browser = BrowserModel(fence: .batcave, desktopSite: false)

    /// Whether the page on screen is one that can be imported.
    ///
    /// Held rather than recomputed on demand: answering means reading the live
    /// DOM across the bridge, and a button's enabled state is evaluated on
    /// every layout pass.
    @State private var isSeries = false
    @State private var checking = false
    @State private var importing = false
    @State private var report: BatCaveReport?
    @State private var errorText: String?

    var body: some View {
        BrowserScreen(model: browser, fallbackTitle: IssueSite.batcave.display) {
            importButton
        } banner: {
            banner
        }
        .onAppear { if browser.url == nil { browser.load(BatCave.browseURL) } }
        // The URL changes before the new page has finished arriving, so the
        // check is repeated when loading finishes — the same pairing the
        // Comic Book Plus browser needs and for the same reason.
        .onChange(of: browser.url) { _ in
            clearBanner()
            Task { await checkForSeries() }
        }
        .onChange(of: browser.isLoading) { loading in
            if !loading { Task { await checkForSeries() } }
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
                // The same explicit stack as the other importers: a toolbar
                // collapses a Label to its icon whatever the label style says,
                // and the word is what makes this the button from the shelf.
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import")
                }
                .font(.headline)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isSeries || importing || browser.isLoading)
    }

    // MARK: - Reading the page

    private func checkForSeries() async {
        // The cheap half. An address that cannot be a title page settles it
        // without touching the document.
        guard let url = browser.url, BatCave.isIssuePage(url) else {
            isSeries = false
            return
        }
        checking = true
        defer { checking = false }
        guard let html = await browser.currentHTML() else {
            isSeries = false
            return
        }
        // The confirming half. An address can look right while the page behind
        // it is the site's own "not found", which lists nothing.
        isSeries = BatCavePage.isSeriesPage(html)
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
            report = try model.importBatCave(html: html)
        } catch {
            // The real reason rather than a guess at it — the lesson the forum
            // importer records having learned.
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

    private func title(for report: BatCaveReport) -> String {
        report.inserted > 0
            ? "Imported \(report.inserted) issue\(report.inserted == 1 ? "" : "s")"
            : "Nothing new imported"
    }

    /// The series is named because the reader may already have moved on, and
    /// the rest answers the two questions a shelf full of grey rows provokes:
    /// why nothing downloaded, and why the count does not match the page.
    private func detail(for report: BatCaveReport) -> String {
        var sentences: [String] = []
        if report.inserted == 0 {
            sentences.append("\(report.series) — every issue on this page is "
                           + "already on your shelf.")
        } else {
            sentences.append("\(report.series).")
            if report.updated > 0 {
                sentences.append("\(report.updated) were already there.")
            }
            sentences.append("Only the details are imported; download each "
                           + "issue from your shelf when you want it.")
        }
        // The site's own flag, passed on. A reader who counted the issues on
        // screen is owed the difference.
        if report.broken > 0 {
            sentences.append("\(report.broken) \(report.broken == 1 ? "is" : "are") "
                           + "marked broken on the site and \(report.broken == 1 ? "was" : "were") "
                           + "skipped.")
        }
        return sentences.joined(separator: " ")
    }

    private func clearBanner() {
        report = nil
        errorText = nil
    }
}
