import SwiftUI
import SZKit

/// Settings — for now, what the app is and which build of it this is.
///
/// Deliberately its own screen rather than an alert: this is where anything
/// configurable will go, and the version belongs with it. Everything shown is
/// read from the bundle, so a release bumps it without touching this file.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            // The scroll view is a safety net for large Dynamic Type, not the
            // way this screen is meant to be read: everything below is sized
            // to fit a sheet on the smallest phone without moving, because a
            // settings pane whose last row is only reachable by scrolling
            // reads as a settings pane with nothing below the fold.
            ScrollView {
            VStack(spacing: 10) {
                if let icon = AppInfo.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: Self.iconSize, height: Self.iconSize)
                        // iOS masks the icon itself; the file inside the
                        // bundle is a plain square.
                        // Roughly iOS's own corner ratio, so it reads as an
                        // app icon at whatever size it ends up.
                        .clipShape(RoundedRectangle(cornerRadius: Self.iconSize * 0.22,
                                                    style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        .padding(.top, 8)
                }

                Text(AppInfo.name)
                    .font(.system(size: Device.isPhone ? 26 : 30, weight: .bold))

                // The build number alongside the version: it is the number
                // that tells two submissions of "1.0" apart, and the only
                // place a reader can be asked to read it back.
                Text("Version \(AppInfo.versionAndBuild)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(AppInfo.copyright)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)

                sources
                    .padding(.top, 8)

                // Not decoration: UnRAR's licence requires its second clause
                // to appear in the licence or documentation of anything that
                // ships its source, and a submitted binary carries no
                // documentation of its own. This screen is where it lives.
                NavigationLink {
                    Acknowledgements()
                } label: {
                    Text("Acknowledgements")
                        .font(.callout)
                }
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // The same notice the shelf shows, because a source can be switched
        // on from either place and the answer to "where did six hundred
        // magazines come from" should not depend on which.
        .alert("RetroSpec", isPresented: Binding(
            get: { model.sourceNotice != nil },
            set: { if !$0 { model.sourceNotice = nil } }
        )) {
            Button("OK", role: .cancel) { model.sourceNotice = nil }
        } message: {
            Text(model.sourceNotice ?? "")
        }
    }

    /// Which archives the shelf draws from.
    ///
    /// Switching one off hides it everywhere — the shelf, the search and the
    /// filter menus — and never deletes anything, so what has been read and
    /// downloaded is exactly as it was when it comes back.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SOURCES")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                ForEach(IssueSite.allCases, id: \.self) { site in
                    SourceToggle(site: site, model: model)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    if site != IssueSite.allCases.last {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Hiding a source keeps everything you have read and downloaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 6)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: 560)
    }

    /// Smaller than the icon's own pixels allow, and deliberately.
    ///
    /// `AppInfo.iconPointSize` draws it at up to 128pt, which is right for a
    /// screen that has nothing else on it. This one now carries the source
    /// switches too, and on a small phone the icon at that size is what
    /// pushed the last row under the fold.
    private static var iconSize: CGFloat {
        min(AppInfo.iconPointSize, Device.isPhone ? 60 : 76)
    }
}

/// Third-party source the app is built on, and what its licences require.
private struct Acknowledgements: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    Text("UnRAR").font(.headline)
                    // Reproduced verbatim, and it has to be: the licence asks
                    // for the full text of this paragraph, from those first
                    // two words onward.
                    Text("""
                        UnRAR source code may be used in any software to \
                        handle RAR archives without limitations free of \
                        charge, but cannot be used to develop RAR (WinRAR) \
                        compatible archiver and to re-create RAR compression \
                        algorithm, which is proprietary. Distribution of \
                        modified UnRAR source code in separate form or as a \
                        part of other software is permitted, provided that \
                        full text of this paragraph, starting from "UnRAR \
                        source code" words, is included in license, or in \
                        documentation if license is not available, and in \
                        source code comments of resulting package.
                        """)
                    Text("All copyrights to RAR and the utility UnRAR are "
                         + "exclusively owned by the author — Alexander Roshal.")
                }
                Group {
                    Text("LZMA SDK").font(.headline)
                    Text("7-Zip's LZMA SDK by Igor Pavlov, placed in the "
                         + "public domain. Used to read 7z archives.")
                }
                Group {
                    Text("StripZona").font(.headline)
                    Text("This is an independent reader. It is not affiliated "
                         + "with, endorsed by, or connected to stripzona.com, "
                         + "and it hosts no content of its own. A stripzona.com "
			 + "approved account is needed to access any content.")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
