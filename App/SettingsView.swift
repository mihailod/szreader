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
