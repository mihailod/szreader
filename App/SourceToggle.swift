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
                Text(title)
                    .font(.headline)
                    // The same reason the detail below has it: on a narrow
                    // phone the stack offers one line's height and the label
                    // truncates instead of wrapping, so "StripZona (free
                    // account needed)" arrives as "StripZona (free account
                    // nee…". Costs the iPad nothing — its titles already fit.
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Both strings come from `SourceCopy`, which is the file to edit. They
    /// used to be written here and again in Acknowledgements, and the two
    /// copies had already drifted apart.
    private var copy: SourceCopy { SourceCopy.of(site) }

    private var title: String { copy.switchTitle }

    private var detail: String { copy.detail }
}
