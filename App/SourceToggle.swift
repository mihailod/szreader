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

/// The list of sources, wherever it is shown.
///
/// Shared by Settings and the empty shelf, which have always carried the same
/// switches — and now have to carry them in the same *shape*, because
/// BombJack is seven of them. Flat, that reads as seven peers of StripZona;
/// grouped under one heading with its description, it reads as one archive
/// with parts, which is what it is.
struct SourceList: View {
    @ObservedObject var model: AppModel

    /// The sources that stand on their own.
    private var standalone: [IssueSite] {
        IssueSite.allCases.filter { $0.bombjackCategory == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(standalone, id: \.self) { site in
                SourceToggle(site: site, model: model)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider().padding(.leading, 16)
            }
            bombJackGroup
        }
    }

    /// The seven, under one heading.
    private var bombJackGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("BombJack").font(.headline)
                Text("Scanned computer magazines and books for many platforms — "
                     + "Commodore 8bit, Amiga, Atari, Sinclair, MSX, etc.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ForEach(Array(IssueSite.bombjackSites.enumerated()), id: \.element) { index, site in
                SourceToggle(site: site, model: model)
                    // Indented, so the seven read as parts of the archive
                    // above them rather than as more sources beside it.
                    .padding(.leading, 32)
                    .padding(.trailing, 16)
                    .padding(.vertical, 8)
                if index < IssueSite.bombjackSites.count - 1 {
                    Divider().padding(.leading, 32)
                }
            }
        }
        .padding(.bottom, 4)
    }
}

