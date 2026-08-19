import Foundation
import WebKit
import SZKit

/// The reader's session with a site, taken from the browser they signed in on.
///
/// Comic Book Plus serves its files only to members, so the download has to
/// carry the same session as the browser. The cookies live in WebKit's own
/// store rather than anywhere this app wrote them — the reader signs in on the
/// site's form and the app never sees, stores or replays their credentials —
/// so this reads them back out at the moment a download needs them.
///
/// Read every time and never cached. `PHPSESSID` is a session cookie: WebKit
/// replaces it when the session rolls over, the login survives on the
/// longer-lived one beside it, and a copy kept anywhere would be a stale
/// credential in a file.
enum SiteCookies {

    /// A `Cookie` header for one domain, or nil when there is nothing stored.
    ///
    /// `.default()` is the persistent store, which is the one `BrowserModel`
    /// uses — that is what makes a sign-in outlive a launch, and what makes it
    /// visible here without a web view being on screen.
    static func header(forDomain domain: String) async -> String? {
        await warmUp()
        let jar = await MainActor.run { WKWebsiteDataStore.default().httpCookieStore }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            Task { @MainActor in
                jar.getAllCookies { continuation.resume(returning: $0) }
            }
        }
        // The domain itself and anything under it, matched on a leading dot so
        // a cookie set for another site whose name merely ends the same way is
        // not handed over. Cookies are stored with a leading dot when they are
        // meant for subdomains, which is why both forms are compared.
        let mine = cookies.filter {
            let d = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
            let lowered = d.lowercased()
            return lowered == domain || lowered.hasSuffix("." + domain)
        }
        guard !mine.isEmpty else { return nil }
        return mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Makes the persistent store real before anything reads it.
    ///
    /// `WKWebsiteDataStore.default()` is lazy. Cookies live on disk between
    /// launches, but they are not loaded into the process until WebKit's
    /// networking machinery starts — which happens when a web view is created,
    /// not when the store is merely referenced. So on a cold launch this
    /// returned *nothing at all*, for every domain, and a download resolved as
    /// if the reader had never signed in. Opening the browser fixed it, which
    /// is exactly what made it look like an expiry.
    ///
    /// Asking for the data records is what forces that load — measured, not
    /// assumed: before this call the store reported zero cookies for every
    /// domain, and after it sixteen. Cheap, and once per launch; the flag is
    /// only ever set, so a race can at worst do the work twice.
    ///
    /// Nothing in the test suite guards this. It is WebKit behaviour in the
    /// app layer, reachable only from a running simulator, so the evidence is
    /// the measurement above rather than a red test. Anyone removing this
    /// should expect downloads to work only after the browser has been opened
    /// once per launch, which is exactly how it presented.
    private static var isWarm = false

    private static func warmUp() async {
        guard !isWarm else { return }
        isWarm = true
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                WKWebsiteDataStore.default().fetchDataRecords(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()
                ) { _ in continuation.resume() }
            }
        }
    }
}
