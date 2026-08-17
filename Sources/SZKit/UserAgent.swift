import Foundation

/// What this app calls itself on the wire.
public enum UserAgent {

    /// One string for every request the app makes — page fetches, host probes,
    /// downloads and cover images alike.
    ///
    /// One, and stable. The hosts these requests go to rate-limit by IP and by
    /// session, not by this header, so varying it buys nothing against a
    /// throttle and costs the two things that do matter: a single address
    /// whose client changes between requests is a stronger bot signal than one
    /// that does not, and a download whose header disagrees with the web view
    /// that established the session is how a live cookie gets refused.
    ///
    /// It says Safari on macOS because several of these hosts serve a stripped
    /// page or an interstitial to anything that does not, and the app has to
    /// read the same page a browser would. The one request that used to go out
    /// under CFNetwork's default — the cover fetch, which is also by far the
    /// most frequent — is the reason this is a shared constant rather than a
    /// default argument in two places: it named the app and the OS build on
    /// every tile of the shelf.
    public static let browser =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}
