import SwiftUI

/// Settings — for now, what the app is and which build of it this is.
///
/// Deliberately its own screen rather than an alert: this is where anything
/// configurable will go, and the version belongs with it. Everything shown is
/// read from the bundle, so a release bumps it without touching this file.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer()

                if let icon = AppInfo.icon {
                    Image(uiImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: AppInfo.iconPointSize,
                               height: AppInfo.iconPointSize)
                        // iOS masks the icon itself; the file inside the
                        // bundle is a plain square.
                        // Roughly iOS's own corner ratio, so it reads as an
                        // app icon at whatever size it ends up.
                        .clipShape(RoundedRectangle(cornerRadius: AppInfo.iconPointSize * 0.22,
                                                    style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                }

                Text(AppInfo.name)
                    .font(.system(size: 40, weight: .bold))

                // The build number alongside the version: it is the number
                // that tells two submissions of "1.0" apart, and the only
                // place a reader can be asked to read it back.
                Text("Version \(AppInfo.versionAndBuild)")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(AppInfo.copyright)
                    .font(.body)
                    .foregroundStyle(.tertiary)

                Spacer()

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
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
