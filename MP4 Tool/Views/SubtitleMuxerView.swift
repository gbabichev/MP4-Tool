import SwiftUI

struct SubtitleMuxerView: View {
    @StateObject private var viewModel = SubtitleMuxerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusContent

            Text("Select one MP4 and one SRT file, then merge them into a single MP4 with embedded subtitles.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox("Files") {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Button("Open") {
                                viewModel.openMP4InFinder()
                            }
                            .controlSize(.small)
                            .disabled(viewModel.inputMP4Path.isEmpty)

                            Text("Input MP4")
                                .font(.subheadline)
                        }
                        Text(viewModel.inputMP4Path.isEmpty ? "Select an MP4 file from the toolbar." : viewModel.inputMP4Path)
                            .font(.caption)
                            .foregroundStyle(viewModel.inputMP4Path.isEmpty ? .tertiary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Button("Open") {
                                viewModel.openSRTInFinder()
                            }
                            .controlSize(.small)
                            .disabled(viewModel.inputSRTPath.isEmpty)

                            Text("Subtitle SRT")
                                .font(.subheadline)
                        }
                        Text(viewModel.inputSRTPath.isEmpty ? "Select an SRT file from the toolbar." : viewModel.inputSRTPath)
                            .font(.caption)
                            .foregroundStyle(viewModel.inputSRTPath.isEmpty ? .tertiary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Output") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Button("Open") {
                                viewModel.openOutputFolderInFinder()
                            }
                            .controlSize(.small)
                            .disabled(viewModel.outputFolderPath.isEmpty)

                            Text("Output Folder")
                                .font(.subheadline)
                        }
                        Text(viewModel.outputFolderPath.isEmpty ? "Select output folder from the toolbar." : viewModel.outputFolderPath)
                            .font(.caption)
                            .foregroundStyle(viewModel.outputFolderPath.isEmpty ? .tertiary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

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
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    viewModel.selectMP4File()
                } label: {
                    Label("Choose MP4...", systemImage: "film")
                }
                .disabled(viewModel.isMuxing)

                Button {
                    viewModel.selectSRTFile()
                } label: {
                    Label("Choose SRT...", systemImage: "captions.bubble")
                }
                .disabled(viewModel.isMuxing)

                Button {
                    viewModel.selectOutputFolder()
                } label: {
                    Label("Output Folder...", systemImage: "folder")
                }
                .disabled(viewModel.isMuxing)
            }

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
