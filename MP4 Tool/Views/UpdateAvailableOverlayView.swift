import SwiftUI

struct UpdateAvailableOverlayView: View {
    let update: AppAvailableUpdate
    let onLater: () -> Void
    let onDownload: () -> Void

    private var notesText: String {
        let trimmed = update.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "No release notes were provided for this release." : trimmed
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Update Available")
                    .font(.title2.weight(.semibold))

                VStack(spacing: 4) {
                    Text(update.appName)
                        .font(.headline)
                    Text("\(update.currentVersion) → \(update.latestVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(update.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Release Notes")
                        .font(.subheadline.weight(.semibold))

                    ScrollView {
                        Text(notesText)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 180, maxHeight: 280)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }

                HStack(spacing: 10) {
                    Button("Later") {
                        onLater()
                    }
                    .keyboardShortcut(.cancelAction)

                    if update.releaseURL != nil {
                        Button("Open Download Page") {
                            onDownload()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Close") {
                            onLater()
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(20)
            .frame(width: 620)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.2), radius: 22, x: 0, y: 10)
            .padding(28)
        }
        .transition(.opacity)
    }
}
