import SwiftUI
import WebKit

/// Holds the web view and its navigation state.
///
/// The session lives entirely in WebKit's persistent data store — the app never
/// sees, stores, or replays a password. You log in once in a real login form
/// and the cookie survives relaunches, which is also why nothing here needs the
/// Keychain.
@MainActor
final class BrowserModel: NSObject, ObservableObject {

    @Published var url: URL?
    @Published var title = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var progress: Double = 0

    let webView: WKWebView

    private var observers: [NSKeyValueObservation] = []

    override init() {
        let config = WKWebViewConfiguration()
        // .default() is the persistent store: the login cookie outlives launches.
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self

        observers = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.url = view.url }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.title = view.title ?? "" }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.progress = view.estimatedProgress }
            },
        ]
    }

    func load(_ address: String) {
        // Upgrade before the first request too, not just on redirects.
        guard let url = URL(string: address) else { return }
        webView.load(URLRequest(url: url))
    }

    /// The **live DOM**, not the originally fetched source.
    ///
    /// This is the whole reason the import lives in the app. IPB reveals hidden
    /// content by AJAX after a Like, so a page saved from the browser still
    /// contains the locked markup unless it is force-reloaded first. Reading
    /// outerHTML sidesteps that entirely: what you can see is what gets parsed.
    func currentHTML() async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }
}

extension BrowserModel: WKNavigationDelegate {

    /// Upgrades stripzona page loads to HTTPS.
    ///
    /// The site serves the forum over TLS but emits plain-http links, and its
    /// session cookie is not marked Secure, so a cleartext hop would put a live
    /// session on the wire.
    ///
    /// GET ONLY, and that restriction is load-bearing. Upgrading works by
    /// cancelling the navigation and re-issuing it, but WebKit does not expose
    /// `httpBody` to this delegate — it is always nil — so a re-issued form
    /// submission arrives as a bodyless GET with no Referer. That silently
    /// broke logging in: the credentials never reached the server and the page
    /// just bounced back. Non-GET navigations are left exactly as the page
    /// made them; the login form already posts to https regardless.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let request = navigationAction.request
        guard request.httpMethod == nil || request.httpMethod == "GET",
              navigationAction.navigationType != .formSubmitted,
              navigationAction.navigationType != .formResubmitted,
              let url = request.url,
              url.scheme == "http",
              let host = url.host?.lowercased(),
              host.hasSuffix("stripzona.com"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .allow }

        parts.scheme = "https"
        guard let secure = parts.url else { return .allow }
        // Carry the original headers over; only the scheme changes.
        var upgraded = request
        upgraded.url = secure
        Task { @MainActor in webView.load(upgraded) }
        return .cancel
    }
}

struct BrowserView: UIViewRepresentable {
    let model: BrowserModel

    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
