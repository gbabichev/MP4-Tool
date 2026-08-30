import SwiftUI

struct TrackEditorView: View {
    @StateObject private var viewModel = TrackEditorViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusContent

            if !viewModel.errorDetails.isEmpty {
                errorLogContent
            }

            if viewModel.isRemuxing {
                remuxProgressContent
            }

            Text("Inspect every media track, choose what to keep, add external audio or subtitles, and create a new validated MP4.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox("Source") {
                ToolSelectionRow(
                    title: viewModel.inputPath.isEmpty ? "No MP4 Selected" : "Input MP4",
                    detail: viewModel.inputPath.isEmpty
                        ? "Choose or drop an MP4 file to inspect its tracks" : viewModel.inputPath,
                    isSelected: !viewModel.inputPath.isEmpty,
                    emptySystemImage: "film",
                    selectedSystemImage: "film.fill",
                    chooseLabel: "Choose…",
                    openLabel: "Reveal",
                    chooseDisabled: viewModel.operationInProgress,
                    openAction: viewModel.revealInput,
                    chooseAction: viewModel.chooseInput
                )
                .padding(.vertical, 4)
            }

            GroupBox("Output") {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.replaceOriginal ? "arrow.triangle.2.circlepath" : "doc.badge.plus")
                            .foregroundStyle(viewModel.replaceOriginal ? Color.orange : Color.accentColor)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Replace Original")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(
                                viewModel.replaceOriginal
                                    ? "Safely replace the source only after the edited file passes validation"
                                    : "Keep the source and append _edited to the new MP4"
                            )
                            .font(.caption)
                            .foregroundStyle(viewModel.replaceOriginal ? Color.orange : Color.secondary)
                        }

                        Spacer()

                        Toggle("Replace Original", isOn: $viewModel.replaceOriginal)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(viewModel.operationInProgress || viewModel.inputPath.isEmpty)
                    }

                    Divider()

                    ToolSelectionRow(
                        title: viewModel.outputFolderPath.isEmpty ? "No Folder Selected" : "Output Folder",
                        detail: viewModel.outputFolderPath.isEmpty
                            ? "Choose where the edited MP4 should be saved" : viewModel.outputFolderPath,
                        isSelected: !viewModel.outputFolderPath.isEmpty,
                        emptySystemImage: "folder.badge.plus",
                        selectedSystemImage: "folder.fill",
                        chooseLabel: "Choose…",
                        openLabel: "Open",
                        chooseDisabled: viewModel.operationInProgress || viewModel.replaceOriginal,
                        openAction: viewModel.openOutputFolder,
                        chooseAction: viewModel.chooseOutputFolder
                    )

                    Divider()

                    HStack(spacing: 12) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        Text("Output File")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        TextField("Movie_edited.mp4", text: $viewModel.outputFileName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .disabled(viewModel.operationInProgress || viewModel.replaceOriginal)
                        if !viewModel.resolvedOutputPath.isEmpty {
                            Text(viewModel.resolvedOutputPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 360, alignment: .trailing)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Tracks") {
                if viewModel.tracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("Choose an MP4 to inspect its video, audio, and subtitle tracks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 24)
                } else {
                    List {
                        ForEach(TrackEditorTrackKind.allCases, id: \.self) { kind in
                            let matchingIndexes = viewModel.tracks.indices.filter {
                                viewModel.tracks[$0].kind == kind
                            }
                            if !matchingIndexes.isEmpty {
                                Section {
                                    ForEach(matchingIndexes, id: \.self) { index in
                                        TrackEditorTrackRow(
                                            track: $viewModel.tracks[index],
                                            controlsDisabled: viewModel.operationInProgress,
                                            setDefault: { value in
                                                viewModel.setDefault(
                                                    trackID: viewModel.tracks[index].id,
                                                    value: value
                                                )
                                            },
                                            removeExternal: {
                                                viewModel.removeExternalTrack(id: viewModel.tracks[index].id)
                                            }
                                        )
                                    }
                                } header: {
                                    Label(kind.label, systemImage: kind.systemImage)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 980, minHeight: 680)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            viewModel.inspect(path: url.path)
            return true
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    viewModel.addAudioTracks()
                } label: {
                    Label("Add Audio…", systemImage: "waveform.badge.plus")
                }
                .disabled(viewModel.inputPath.isEmpty || viewModel.operationInProgress)

                Button {
                    viewModel.addSubtitleTracks()
                } label: {
                    Label("Add Subtitles…", systemImage: "captions.bubble.fill")
                }
                .disabled(viewModel.inputPath.isEmpty || viewModel.operationInProgress)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.operationInProgress {
                    Button {
                        viewModel.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .toolbarStopActionStyle()
                } else {
                    Button {
                        viewModel.startRemux()
                    } label: {
                        Label("Create MP4", systemImage: "shippingbox")
                    }
                    .disabled(!viewModel.canRemux)
                }
            }
        }
        .alert("Output File Already Exists", isPresented: $viewModel.showOverwriteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Replace", role: .destructive) {
                viewModel.confirmOverwriteAndStart()
            }
        } message: {
            Text("Replace the existing file at:\n\(viewModel.resolvedOutputPath)")
        }
    }

    private var errorLogContent: some View {
        GroupBox {
            ScrollView([.horizontal, .vertical]) {
                Text(viewModel.errorDetails)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
            .frame(height: 150)
        } label: {
            HStack {
                Label("Error Log", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Spacer()
                Button {
                    viewModel.copyErrorDetails()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
        }
    }

    private var remuxProgressContent: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(viewModel.statusMessage, systemImage: "shippingbox.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if viewModel.hasDeterminateRemuxProgress {
                        Text(viewModel.remuxProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                    }
                }

                if viewModel.hasDeterminateRemuxProgress {
                    ProgressView(value: viewModel.remuxProgress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                HStack {
                    Label("Elapsed: \(viewModel.remuxElapsedText)", systemImage: "clock")
                    Spacer()
                    Label("ETA: \(viewModel.remuxETAText)", systemImage: "hourglass")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .padding(.vertical, 4)
        } label: {
            Text("Progress")
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        HStack(spacing: 8) {
            if viewModel.operationInProgress {
                ProgressView()
                    .controlSize(.small)
            }
            Image(systemName: viewModel.hasTools ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(viewModel.hasTools ? Color.green : Color.orange)
            Text(viewModel.hasTools ? "FFmpeg ready" : "FFmpeg and FFprobe are required")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var statusColor: Color {
        if viewModel.statusMessage.hasPrefix("Created ") {
            return .green
        }
        if viewModel.statusMessage.localizedCaseInsensitiveContains("failed")
            || viewModel.statusMessage.localizedCaseInsensitiveContains("cannot")
            || viewModel.statusMessage.localizedCaseInsensitiveContains("could not") {
            return .red
        }
        return .secondary
    }
}

private struct TrackEditorTrackRow: View {
    @Binding var track: TrackEditorTrack
    let controlsDisabled: Bool
    let setDefault: (Bool) -> Void
    let removeExternal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Include", isOn: $track.isIncluded)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(controlsDisabled || !track.isMuxable)

            Image(systemName: track.kind.systemImage)
                .foregroundStyle(track.isIncluded ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.technicalDescription)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let note = track.compatibilityNote {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else {
                    Text(trackDetailDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

            if track.kind != .video {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Language")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("Language", selection: $track.language) {
                        ForEach(languageOptions, id: \.code) { option in
                            Text(option.label).tag(option.code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 150)
                    .disabled(controlsDisabled || !track.isIncluded)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Track Title")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Optional, e.g. Commentary", text: $track.title)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(minWidth: 190, idealWidth: 240, maxWidth: 280)
                        .disabled(controlsDisabled || !track.isIncluded)
                        .help("Optional name shown by players, such as Main Audio, Commentary, or SDH")
                }

                Button {
                    setDefault(!track.isDefault)
                } label: {
                    Label(
                        "Default",
                        systemImage: track.isDefault ? "checkmark.square.fill" : "square"
                    )
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .disabled(controlsDisabled || !track.isIncluded)

                if track.kind == .subtitle {
                    Menu {
                        subtitleFlagButton(
                            "Forced",
                            isEnabled: track.isForced
                        ) {
                            track.isForced.toggle()
                        }
                        subtitleFlagButton(
                            "Hearing Impaired",
                            isEnabled: track.isHearingImpaired
                        ) {
                            track.isHearingImpaired.toggle()
                        }
                        subtitleFlagButton(
                            "Captions",
                            isEnabled: track.isCaptions
                        ) {
                            track.isCaptions.toggle()
                        }
                    } label: {
                        Label("Flags", systemImage: "tag")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .controlSize(.small)
                    .disabled(controlsDisabled || !track.isIncluded)
                    .help("Edit subtitle flags shown by media players")
                }
            }

            if track.isExternal {
                Button(role: .destructive, action: removeExternal) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(controlsDisabled)
                .help("Remove added track")
            }
        }
        .padding(.vertical, 3)
        .opacity(track.isIncluded ? 1 : 0.62)
    }

    private var languageOptions: [TrackEditorLanguageOption] {
        var options = TrackEditorLanguageOption.common
        let currentCode = track.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !currentCode.isEmpty, !options.contains(where: { $0.code == currentCode }) {
            options.insert(
                TrackEditorLanguageOption(code: currentCode, name: "Current"),
                at: 0
            )
        }
        return options
    }

    private var trackDetailDescription: String {
        var parts = [track.isExternal ? "Added track" : "Source stream \(track.streamIndex)"]
        if let disposition = track.subtitleDispositionDescription {
            parts.append(disposition)
        }
        return parts.joined(separator: " · ")
    }

    private func subtitleFlagButton(
        _ title: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if isEnabled {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

private struct TrackEditorLanguageOption {
    let code: String
    let name: String

    var label: String {
        "\(name) (\(code))"
    }

    static let common: [TrackEditorLanguageOption] = [
        .init(code: "und", name: "Undefined"),
        .init(code: "eng", name: "English"),
        .init(code: "spa", name: "Spanish"),
        .init(code: "fra", name: "French"),
        .init(code: "deu", name: "German"),
        .init(code: "ita", name: "Italian"),
        .init(code: "por", name: "Portuguese"),
        .init(code: "nld", name: "Dutch"),
        .init(code: "pol", name: "Polish"),
        .init(code: "rus", name: "Russian"),
        .init(code: "ukr", name: "Ukrainian"),
        .init(code: "ces", name: "Czech"),
        .init(code: "dan", name: "Danish"),
        .init(code: "fin", name: "Finnish"),
        .init(code: "nor", name: "Norwegian"),
        .init(code: "swe", name: "Swedish"),
        .init(code: "jpn", name: "Japanese"),
        .init(code: "kor", name: "Korean"),
        .init(code: "zho", name: "Chinese"),
        .init(code: "ara", name: "Arabic"),
        .init(code: "hin", name: "Hindi")
    ]
}
