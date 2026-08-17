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
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the switch is called.
    ///
    /// `site.display` everywhere except StripZona, which says here that an
    /// account is needed — the one source that can be switched on and still
    /// show nothing, because its links stay hidden until you are signed in.
    /// The condition is on the switch rather than in `IssueSite.display`,
    /// which is stored: it is written into the publisher column and the search
    /// index of every seeded row, and a caveat belongs on a control, not in a
    /// database.
    private var title: String {
        switch site {
        case .stripzona: return "\(site.display) (free account needed)"
        case .retrospec, .archive: return site.display
        }
    }

    /// What the reader is switching on, in the terms they would describe it.
    ///
    /// Says where the issues come from, because the sources behave nothing
    /// alike: one is a forum you import pages from, the other two are fixed
    /// catalogues that are simply there.
    private var detail: String {
        switch site {
        case .stripzona:
            return "Ex-Yugoslav, etc. comics and magazines you import from the StripZona forum."
        case .retrospec:
            return "Ex-Yugoslav computer magazines and books — Svet Kompjutera, "
                 + "Računari, Moj Mikro and more."
        case .archive:
            // Named rather than counted: four issues is a number that dates
            // the sentence the moment a fifth is added, and the two runs are
            // what someone would recognise.
            return "Ex-Yugoslav Amiga fanzines scanned on the Internet Archive — "
                 + "A-Profy and Amiga Bilten."
        }
    }
}
