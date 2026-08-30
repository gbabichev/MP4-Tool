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
                        .scaleEffect(0.75)

                    Text("MP4 Tool Tutorial")
                        .font(.title)
                        .bold()

                    Text("Convert, organize, inspect, and repair your media")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Tutorial steps (scrollable)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        TutorialStep(
                            icon: "film.stack",
                            title: "Supported Formats"
                        ) {
                            Text("Input: ").bold() +
                            Text("MKV, MP4, AVI, MOV, M4V") +
                            Text("\nOutput: ").bold() +
                            Text("MP4 (H.265, H.264, or original codec)")
                        }

                        TutorialStep(
                            icon: "folder",
                            title: "1. Build Your Queue"
                        ) {
                            Text("Drag video files or folders into the ") +
                            Text("Queue").bold() +
                            Text(", or click ") +
                            Text("Add Files").bold() +
                            Text(". Folders are scanned recursively, and pending items can be reordered to choose what runs next.")
                        }

                        TutorialStep(
                            icon: "list.star",
                            title: "2. Choose a Preset or Mode"
                        ) {
                            Text("Start with a built-in preset, or customize the workflow. Use ") +
                            Text("H.265").bold() +
                            Text(" for smaller files, ") +
                            Text("H.264").bold() +
                            Text(" for better compatibility, or ") +
                            Text("Remux").bold() +
                            Text(" to copy streams without re-encoding (fast, no quality loss).")
                        }

                        TutorialStep(
                            icon: "slider.horizontal.3",
                            title: "3. Configure Processing",
                            description: "Choose an output folder and adjust quality, resolution, speed, automatic naming, and audio or subtitle filtering. Notifications, live frame previews, and staging storage can also be changed in Processing Setup."
                        )

                        TutorialStep(
                            icon: "play.fill",
                            title: "4. Process and Monitor",
                            description: "Click Process or press ⌘P. Follow batch progress, the current file, ETA, and optional frame previews in the center view. Open the Log inspector for detailed FFmpeg output. Every completed output is validated before it is accepted."
                        )

                        TutorialStep(
                            icon: "stop.circle",
                            title: "5. Control the Batch",
                            description: "You can add files while processing continues. Use Stop After Current File to finish the active item safely, or Stop Now to end processing immediately."
                        )

                        TutorialStep(
                            icon: "wrench.and.screwdriver",
                            title: "6. Inspect and Manage Your Library",
                            description: "Open Tools for Inspect & Repair checks covering compatibility, metadata, timing, and subtitles. You can also edit tracks, split videos, find non-MP4 files, and review Run History."
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

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
