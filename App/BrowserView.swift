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
    nonisolated func webView(_ webView: WKWebView,
                             didFinish navigation: WKNavigation!) {}
}

struct BrowserView: UIViewRepresentable {
    let model: BrowserModel

    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
