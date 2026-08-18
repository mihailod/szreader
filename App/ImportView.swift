import SwiftUI
import SZKit

/// Browse stripzona, like the posts you want, tap Import.
///
/// Deliberately manual. The app does not store credentials, does not log in for
/// you, and never clicks Like on your behalf — likes are public actions on a
/// hand-approved account, and there is a daily quota. You do the browsing; the
/// app just reads the page you are already looking at.
struct ImportView: View {

    let onImport: (String) throws -> ImportReport
    @StateObject private var browser = BrowserModel(fence: .stripzona, desktopSite: true)

    @State private var report: ImportReport?
    @State private var errorText: String?
    @State private var importing = false

    // The forum path directly: the bare root 302s to plain http, and every
    // cleartext hop would expose a session cookie that is not marked Secure.
    private static let home = "https://www.stripzona.com/port/index.php"

    var body: some View {
        BrowserScreen(model: browser, fallbackTitle: "Import") {
            Button {
                Task { await performImport() }
            } label: {
                if importing {
                    ProgressView()
                } else {
                    // Spelled out as an explicit stack: a toolbar collapses a
                    // Label to its icon regardless of labelStyle, and the word
                    // "Import" is what makes this recognisably the same button
                    // as on the shelf.
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import")
                    }
                    .font(.headline)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(importing || browser.isLoading)
        } banner: {
            banner
        }
        .onAppear { if browser.url == nil { browser.load(Self.home) } }
    }

    @ViewBuilder private var banner: some View {
        if let errorText {
            BrowserBanner(icon: "exclamationmark.triangle.fill", tint: .orange,
                          title: "Import failed", detail: errorText,
                          dismiss: clearBanner)
        } else if let report {
            BrowserBanner(
                icon: report.isEmpty ? "questionmark.circle.fill" : "checkmark.circle.fill",
                tint: report.isEmpty ? .orange : .green,
                title: report.isEmpty
                    ? "Nothing new imported"
                    : "Imported \(report.issues) issue\(report.issues == 1 ? "" : "s"), \(report.mirrors) mirror\(report.mirrors == 1 ? "" : "s")",
                detail: report.advice
                    ?? "\(report.attributed) of \(report.links) links matched an issue.",
                dismiss: clearBanner)
        }
    }

    private func clearBanner() {
        report = nil
        errorText = nil
    }

    private func performImport() async {
        importing = true
        defer { importing = false }
        report = nil
        errorText = nil

        guard let html = await browser.currentHTML() else {
            errorText = "Could not read the page."
            return
        }
        do {
            report = try onImport(html)
        } catch {
            // The real reason, not a guess at it. This used to report "the
            // library could not be written to" for every failure, which sent
            // an entire debugging session after a database problem that was
            // never there.
            errorText = SZKit.Library.reason(error)
        }
    }
}
