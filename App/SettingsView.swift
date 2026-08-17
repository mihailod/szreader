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
                header
                    .padding(.top, 8)

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
                // Down the same left edge as the icon, the name and the source
                // rows: with the header no longer centred, this was the one
                // thing left floating in the middle of the sheet.
                .padding(.horizontal, 16)
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
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
        .alert(model.sourceNotice?.site.display ?? "", isPresented: Binding(
            get: { model.sourceNotice != nil },
            set: { if !$0 { model.sourceNotice = nil } }
        )) {
            Button("OK", role: .cancel) { model.sourceNotice = nil }
        } message: {
            Text(model.sourceNotice?.message ?? "")
        }
    }

    /// What the app is: the icon, and beside it the three lines that name it.
    ///
    /// A row rather than a column. Nothing here ever changes between launches,
    /// and stacked it took the top of the sheet for four fixed things while the
    /// part that grows — the sources — started below the middle of a phone
    /// screen. Side by side the whole lot costs one icon's height, and every
    /// row that height frees goes to the list underneath.
    private var header: some View {
        HStack(spacing: 14) {
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
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(AppInfo.name)
                    .font(.system(size: Device.isPhone ? 24 : 28, weight: .bold))

                // The build number alongside the version: it is the number
                // that tells two submissions of "1.0" apart, and the only
                // place a reader can be asked to read it back.
                Text("Version \(AppInfo.versionAndBuild)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(AppInfo.copyright)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            // Left-aligned against the icon at every width: without this the
            // pair floats to the middle of the sheet on an iPad and stops
            // lining up with the sources card below it.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: 560)
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
    /// screen that has nothing else on it. Here it sits beside three lines of
    /// text and is sized to stand about as tall as they do, so the pair reads
    /// as one block rather than as a picture with a caption.
    private static var iconSize: CGFloat {
        min(AppInfo.iconPointSize, Device.isPhone ? 64 : 76)
    }
}

/// Third-party source the app is built on, and what its licences require.
private struct Acknowledgements: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    Text("StripZona (free account needed)").font(.headline)
                    Text("This is an independent reader. It is not affiliated "
                         + "with, endorsed by, or connected to stripzona.com, "
                         + "and it hosts no StripZona content of its own. A stripzona.com "
			 + "approved account is needed to access any content.")
                }
                Group {
                    Text("RetroSpec").font(.headline)
                    // Credited by name, unlike the other two: this one is one
                    // person's work rather than an institution, and the whole
                    // ex-Yugoslav computer press survives in readable form
                    // because he scanned it.
                    Text("The RetroSpec source is Tomaž Kac's archive of "
                         + "scanned ex-Yugoslav (1972=2001) computer magazines and books at "
                         + "retrospec.elite.org/users/tomcat/yu. "
                         + "The app ships the index and only downloads each "
                         + "issue from the archive on demand. This is "
                         + "an independent reader, not affiliated with or "
                         + "endorsed by RetroSpec, and it hosts none of its "
                         + "scans.")
                }
                Group {
                    Text("Internet Archive").font(.headline)
                    // The same disclaimer, and it has to be here for the same
                    // reason: the app ships a list of archive.org items and
                    // fetches them on request. It is not affiliated with the
                    // Internet Archive and stores none of their material.
                    Text("The Archive.org source lists items hosted by the "
                         + "Internet Archive, which are downloaded from "
                         + "archive.org on demand. This reader is "
                         + "not affiliated with or endorsed by the Internet "
                         + "Archive, and hosts none of their material. Only "
                         + "ex-YU Amiga fanzines are currently indexed.")
                }
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
