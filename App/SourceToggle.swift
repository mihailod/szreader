import SwiftUI
import SZKit

/// One switch for one archive.
///
/// Shared by Settings and the empty shelf rather than written twice. The empty
/// shelf is where a first-time reader meets these — it is the only screen that
/// says the app has a second library in it — and Settings is where they go
/// looking afterwards, once the shelf has something on it and the empty screen
/// is gone for good. The same control in both places means the second visit
/// looks like the first.
struct SourceToggle: View {
    let site: IssueSite
    @ObservedObject var model: AppModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.isEnabled(site) },
            set: { model.setSource(site, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(site.display).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the reader is switching on, in the terms they would describe it.
    ///
    /// Says where the issues come from, because the two sources behave
    /// nothing alike: one is a forum you import pages from and the other is
    /// a fixed catalogue that is simply there.
    private var detail: String {
        switch site {
        case .stripzona:
            return "Comics and magazines you import from the StripZona forum."
        case .retrospec:
            return "Ex-Yugoslav computer magazines and books — Svet Kompjutera, "
                 + "Računari, Moj Mikro and more."
        }
    }
}
