import UIKit

/// What the app calls itself, read off its own bundle.
///
/// Nothing here is written twice. The name and the version live in
/// `project.yml`, which generates `Info.plist`; this reads them back at
/// runtime. Spelling either of them out in Swift would be a second place to
/// change at release time, and the one that gets forgotten is always the one
/// on screen.
enum AppInfo {

    /// Who holds the copyright, and from when. The only part of the notice
    /// with nowhere else to live — the rest is assembled from the bundle.
    static let author = "Mihailo Despotovic"
    static let year = "2026"

    /// "StreamZine". Falls back to the bundle name, which is the target's
    /// product name, and then to nothing rather than to a literal: a
    /// hard-coded default is exactly the stale second copy this avoids, and
    /// an empty title is obvious where a plausible wrong one is not.
    static var name: String {
        string("CFBundleDisplayName") ?? string("CFBundleName") ?? ""
    }

    /// "1.0" — `MARKETING_VERSION`.
    static var version: String { string("CFBundleShortVersionString") ?? "" }

    /// "1" — `CURRENT_PROJECT_VERSION`, the number the App Store counts.
    static var build: String { string("CFBundleVersion") ?? "" }

    /// "1.0 (1)", the form every About screen uses.
    static var versionAndBuild: String {
        build.isEmpty ? version : "\(version) (\(build))"
    }

    /// "StreamZine 1.0, © Mihailo Despotovic 2006".
    static var copyright: String {
        "© \(author) \(year)"
    }

    /// The app's own icon, at the largest size the bundle actually holds.
    ///
    /// Found by looking in the bundle rather than by asking `CFBundleIcons`,
    /// which lists only `AppIcon60x60` — 120 px. Xcode also writes
    /// `AppIcon76x76@2x~ipad.png` at 152 px and mentions it nowhere, so going
    /// through the plist gets the smaller of the two and a soft icon on the
    /// one screen that shows it big. Reading the directory finds whatever was
    /// produced without naming any of it.
    static var icon: UIImage? {
        let path = Bundle.main.bundlePath
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names
            .filter { $0.hasPrefix("AppIcon") && $0.hasSuffix(".png") }
            .compactMap { UIImage(contentsOfFile: "\(path)/\($0)") }
            .max { $0.pixelWidth < $1.pixelWidth }
    }

    /// The size to draw the icon so it is never scaled up.
    ///
    /// The bundled icons are home-screen sized; drawn any larger than their
    /// own pixels allow they go soft, and this is the one place in the app
    /// showing the icon at size. Capped so a future larger asset does not
    /// take over the screen.
    static var iconPointSize: CGFloat {
        guard let icon else { return 76 }
        return min(CGFloat(icon.pixelWidth) / UIScreen.main.scale, 128)
    }

    private static func string(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }
}

private extension UIImage {
    var pixelWidth: Int { Int(size.width * scale) }
}
