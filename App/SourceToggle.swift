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
        IssueSite.allCases.filter {
            $0.bombjackCategory == nil && $0.spectrumGroup == nil
                && $0.vintageAppleGroup == nil
        }
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
            Divider().padding(.leading, 16)
            spectrumGroup
            Divider().padding(.leading, 16)
            vintageAppleGroup
        }
    }

    /// The two, under one heading — same shape as the groups above.
    private var vintageAppleGroup: some View {
        grouped(title: "Vintage Apple",
                blurb: "Scanned magazines, books and manuals from the Apple world "
                     + "— Byte, Macworld, MacUser and the Mac bookshelf.",
                sites: IssueSite.vintageAppleSites)
    }

    /// One archive with parts: a heading, a line saying what it is, and its
    /// switches indented under it.
    ///
    /// Written once and called three times. It began as three near-identical
    /// blocks and they had already started to drift in their padding.
    private func grouped(title: String, blurb: String,
                         sites: [IssueSite]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(blurb)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ForEach(Array(sites.enumerated()), id: \.element) { index, site in
                SourceToggle(site: site, model: model)
                    .padding(.leading, 32)
                    .padding(.trailing, 16)
                    .padding(.vertical, 8)
                if index < sites.count - 1 {
                    Divider().padding(.leading, 32)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private var spectrumGroup: some View {
        grouped(title: "Spectrum Computing",
                blurb: "Scanned magazines, fanzines and books for the Sinclair "
                     + "machines — ZX Spectrum, ZX81 and QL.",
                sites: IssueSite.spectrumSites)
    }

    private var bombJackGroup: some View {
        grouped(title: "BombJack",
                blurb: "Scanned computer magazines and books for many platforms — "
                     + "Commodore 8bit, Amiga, Atari, Sinclair, MSX, etc.",
                sites: IssueSite.bombjackSites)
    }
}

