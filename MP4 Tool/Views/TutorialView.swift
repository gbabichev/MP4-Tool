//
//  TutorialView.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI

struct TutorialView: View {
    @Binding var isPresented: Bool
    @AppStorage("hasSeenTutorial") private var hasSeenTutorial = false

    var body: some View {
        ZStack {
            // Semi-transparent background overlay
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            // Tutorial content card
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    LiveAppIconView()

                    Text("MP4 Tool Tutorial")
                        .font(.title)
                        .bold()

                    Text("Convert and remux video files efficiently")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Tutorial steps
                VStack(alignment: .leading, spacing: 20) {
                    TutorialStep(
                        icon: "film.stack",
                        title: "Supported Formats"
                    ) {
                        Text("Input: ").bold() +
                        Text("MKV, MP4, AVI, MOV, M4V") +
                        Text("\nOutput: ").bold() +
                        Text("MP4 (H.265 HEVC or original codec)")
                    }

                    TutorialStep(
                        icon: "folder",
                        title: "1. Add Files"
                    ) {
                        Text("• Drag folders onto ") +
                        Text("Input Folder").bold() +
                        Text(" to scan all videos\n") +
                        Text("• Drag individual files into ") +
                        Text("Files to Process").bold() +
                        Text("\n• Or use toolbar buttons and keyboard shortcuts ⌘O and ⌘⇧O")
                    }

                    TutorialStep(
                        icon: "arrow.left.arrow.right",
                        title: "2. Choose Mode"
                    ) {
                        Text("Select ") +
                        Text("Encode").bold() +
                        Text(" to convert videos to H.265 (HEVC) for smaller file sizes, or ") +
                        Text("Remux").bold() +
                        Text(" to copy streams without re-encoding (fast, no quality loss).")
                    }

                    TutorialStep(
                        icon: "slider.horizontal.3",
                        title: "3. Adjust Settings",
                        description: "In Encode mode, adjust CRF quality (18-28, lower = better quality). Configure audio/subtitle language filtering, subfolders, and deletion options as needed."
                    )

                    TutorialStep(
                        icon: "play.fill",
                        title: "4. Start Processing",
                        description: "Click Start Processing or press ⌘P to begin. Monitor progress in the log output below."
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Footer with dismiss button
                VStack(spacing: 12) {
                    Text("You can always re-open this tutorial from Help → Tutorial")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Don't show this again", isOn: $hasSeenTutorial)
                        .toggleStyle(.checkbox)

                    Button {
                        dismiss()
                    } label: {
                        Text("Get Started")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(32)
            .frame(width: 600)
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(16)
            .shadow(radius: 20)
        }
    }

    private func dismiss() {
        isPresented = false
    }
}

// MARK: - Tutorial Step Component

struct TutorialStep<Description: View>: View {
    let icon: String
    let title: String
    let description: Description

    init(icon: String, title: String, description: String) where Description == Text {
        self.icon = icon
        self.title = title
        self.description = Text(description)
    }

    init(icon: String, title: String, @ViewBuilder description: () -> Description) {
        self.icon = icon
        self.title = title
        self.description = description()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.accentColor)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)

                description
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    TutorialView(isPresented: .constant(true))
}
