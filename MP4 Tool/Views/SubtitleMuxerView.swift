import SwiftUI

struct SubtitleMuxerView: View {
    @StateObject private var viewModel = SubtitleMuxerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusContent

            Text("Select one MP4 and one SRT file, then merge them into a single MP4 with embedded subtitles.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox("Inputs") {
                VStack(spacing: 12) {
                    ToolSelectionRow(
                        title: viewModel.inputMP4Path.isEmpty ? "No MP4 Selected" : "Input MP4",
                        detail: viewModel.inputMP4Path.isEmpty
                            ? "Choose the MP4 file to receive subtitles" : viewModel.inputMP4Path,
                        isSelected: !viewModel.inputMP4Path.isEmpty,
                        emptySystemImage: "film",
                        selectedSystemImage: "film.fill",
                        chooseLabel: "Choose…",
                        openLabel: "Reveal",
                        chooseDisabled: viewModel.isMuxing,
                        openAction: viewModel.openMP4InFinder,
                        chooseAction: viewModel.selectMP4File
                    )

                    Divider()

                    ToolSelectionRow(
                        title: viewModel.inputSRTPath.isEmpty ? "No Subtitle Selected" : "Subtitle SRT",
                        detail: viewModel.inputSRTPath.isEmpty
                            ? "Choose the SRT subtitle file to embed" : viewModel.inputSRTPath,
                        isSelected: !viewModel.inputSRTPath.isEmpty,
                        emptySystemImage: "doc.text",
                        selectedSystemImage: "doc.text.fill",
                        chooseLabel: "Choose…",
                        openLabel: "Reveal",
                        chooseDisabled: viewModel.isMuxing,
                        openAction: viewModel.openSRTInFinder,
                        chooseAction: viewModel.selectSRTFile
                    )
                }
                .padding(.vertical, 4)
            }

            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 12) {
                    ToolSelectionRow(
                        title: viewModel.outputFolderPath.isEmpty ? "No Folder Selected" : "Output Folder",
                        detail: viewModel.outputFolderPath.isEmpty
                            ? "Choose where the merged MP4 should be saved" : viewModel.outputFolderPath,
                        isSelected: !viewModel.outputFolderPath.isEmpty,
                        emptySystemImage: "folder.badge.plus",
                        selectedSystemImage: "folder.fill",
                        chooseLabel: "Choose…",
                        openLabel: "Open",
                        chooseDisabled: viewModel.isMuxing,
                        openAction: viewModel.openOutputFolderInFinder,
                        chooseAction: viewModel.selectOutputFolder
                    )

                    Divider()

                    HStack(spacing: 8) {
                        Text("Output File")
                            .font(.subheadline)
                        TextField("example_muxed.mp4", text: $viewModel.outputFileName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                    }

                    HStack(spacing: 8) {
                        Text("Subtitle Language")
                            .font(.subheadline)
                        Spacer()
                        Picker("Subtitle Language", selection: $viewModel.selectedSubtitleLanguageCode) {
                            ForEach(viewModel.subtitleLanguageOptions, id: \.code) { option in
                                Text(option.label).tag(option.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }

                    if !viewModel.resolvedOutputPath.isEmpty {
                        Text(viewModel.resolvedOutputPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 760, minHeight: 460)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isMuxing {
                    Button {
                        viewModel.cancelMux()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        viewModel.startMux()
                    } label: {
                        Label("Mux", systemImage: "shippingbox")
                    }
                    .disabled(!viewModel.canMux)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
        .alert("Output File Already Exists", isPresented: $viewModel.showOverwriteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Continue", role: .destructive) {
                viewModel.confirmOverwriteAndStart()
            }
        } message: {
            Text("The output file already exists:\n\(viewModel.resolvedOutputPath)\n\nContinue will overwrite it.")
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if viewModel.isMuxing {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(viewModel.muxProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(viewModel.muxProgressPercentLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !viewModel.statusMessage.isEmpty {
                        Text(viewModel.statusMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                ProgressView(value: viewModel.muxProgressFraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 360)
            }
        } else if !viewModel.muxProgress.isEmpty {
            HStack(spacing: 8) {
                Text(viewModel.muxProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !viewModel.statusMessage.isEmpty {
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundStyle(viewModel.statusMessage.hasPrefix("Created ") ? Color.secondary : Color.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else {
            HStack(spacing: 8) {
                Text(viewModel.ffmpegStatusLabel)
                    .font(.caption)
                    .foregroundStyle(viewModel.ffmpegAvailable ? Color.secondary : Color.orange)
                if !viewModel.statusMessage.isEmpty {
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
