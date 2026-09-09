//
//  SettingsView.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @Binding var selectedMode: ProcessingMode
    @Binding var smartRemuxMegabytesPerMinute: Double
    @Binding var crfValue: Double
    @Binding var selectedResolution: ResolutionOption
    @Binding var selectedPreset: PresetOption
    @Binding var encodeVideo: Bool
    @Binding var encodeAudio: Bool
    @Binding var createSubfolders: Bool
    @Binding var automaticRename: Bool
    @Binding var deleteOriginal: Bool
    @Binding var keepEnglishAudioOnly: Bool
    @Binding var keepAllEnglishAudioTracks: Bool
    @Binding var keepEnglishSubtitlesOnly: Bool
    @Binding var keepAllEnglishSubtitleTracks: Bool
    @Binding var postProcessScriptPath: String
    @Binding var postProcessScriptRunTiming: PostProcessScriptRunTiming
    @Binding var postProcessScriptPassFileNameAsFirstArgument: Bool
    let isProcessing: Bool
    @Binding var isExpanded: Bool
    @AppStorage("processingPresets") private var encodedPresets = ""
    @AppStorage("selectedProcessingPresetID") private var selectedProcessingPresetIDRawValue = ""
    @State private var isShowingSavePresetAlert = false
    @State private var isShowingDeletePresetAlert = false
    @State private var newPresetName = ""

    private var userProcessingPresets: [ProcessingPreset] {
        guard let data = encodedPresets.data(using: .utf8),
              var presets = try? JSONDecoder().decode([ProcessingPreset].self, from: data) else {
            return []
        }
        for index in presets.indices where presets[index].keepAllEnglishAudioTracks == nil {
            presets[index].keepAllEnglishAudioTracks = false
        }
        for index in presets.indices where presets[index].keepAllEnglishSubtitleTracks == nil {
            presets[index].keepAllEnglishSubtitleTracks = false
        }
        for index in presets.indices where presets[index].smartRemuxMegabytesPerMinute == nil {
            presets[index].smartRemuxMegabytesPerMinute = ProcessingMode.defaultSmartRemuxMegabytesPerMinute
        }
        return presets.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var processingPresets: [ProcessingPreset] {
        ProcessingPreset.builtInPresets + userProcessingPresets
    }

    private var selectedProcessingPresetID: UUID? {
        get { UUID(uuidString: selectedProcessingPresetIDRawValue) }
        nonmutating set { selectedProcessingPresetIDRawValue = newValue?.uuidString ?? "" }
    }

    private var selectedProcessingPreset: ProcessingPreset? {
        guard let selectedProcessingPresetID else { return nil }
        return processingPresets.first { $0.id == selectedProcessingPresetID }
    }

    private var selectedPresetIsBuiltIn: Bool {
        guard let selectedProcessingPresetID else { return false }
        return ProcessingPreset.builtInPresets.contains { $0.id == selectedProcessingPresetID }
    }

    private var selectedPresetIsModified: Bool {
        guard let selectedProcessingPreset else { return false }
        return currentPreset(
            id: selectedProcessingPreset.id,
            name: selectedProcessingPreset.name
        ) != selectedProcessingPreset
    }

    private var newPresetUsesReservedName: Bool {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProcessingPreset.builtInPresets.contains {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private var smartTargetSubtitle: String {
        "Remux at or below this rate · About \(smartTargetSize(minutes: 45)) for a 45 min TV episode or \(smartTargetSize(minutes: 120)) for a 2 hr movie"
    }

    private func smartTargetSize(minutes: Double) -> String {
        let gigabytes = smartRemuxMegabytesPerMinute * minutes / 1_000
        let format = gigabytes.rounded() == gigabytes ? "%.0f GB" : "%.2f GB"
        return String(format: format, gigabytes)
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(spacing: 12) {
                    processingPresetsSection

                    GroupBox {
                        VStack(spacing: 12) {
                        SettingsRow("Mode", subtitle: "Choose automatic, encode, or remux processing") {
                            Picker("", selection: $selectedMode) {
                                ForEach(ProcessingMode.allCases, id: \.self) { mode in
                                    Text(mode.description).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(isProcessing)
                        }

                        if selectedMode == .smart {
                            SettingsRow(
                                "Smart Target",
                                subtitle: smartTargetSubtitle
                            ) {
                                HStack {
                                    Slider(
                                        value: $smartRemuxMegabytesPerMinute,
                                        in: 5...100,
                                        step: 1
                                    )
                                    .frame(minWidth: 120, idealWidth: 200, maxWidth: 200)
                                    .disabled(isProcessing)

                                    Text("\(Int(smartRemuxMegabytesPerMinute.rounded())) MB/min")
                                        .frame(width: 78, alignment: .trailing)
                                        .monospacedDigit()
                                }
                            }
                        }

                        if selectedMode == .encodeH265 || selectedMode == .encodeH264 {
                            SettingsRow("Encode Video", subtitle: "Turn off to copy video and only process audio") {
                                Toggle("", isOn: $encodeVideo)
                                    .toggleStyle(.switch)
                                    .disabled(isProcessing || !encodeAudio)
                            }

                            SettingsRow("Encode Audio", subtitle: "Turn off to copy existing compatible audio") {
                                Toggle("", isOn: $encodeAudio)
                                    .toggleStyle(.switch)
                                    .disabled(isProcessing || !encodeVideo)
                            }

                        }

                        if selectedMode == .smart || selectedMode == .encodeH265 || selectedMode == .encodeH264 {
                            SettingsRow(
                                "Quality (CRF)",
                                subtitle: selectedMode == .smart
                                    ? "Used when Smart chooses H.265 encoding"
                                    : "Lower = better quality, larger file. Default 23."
                            ) {
                                HStack {
                                    Slider(value: $crfValue, in: 0...50, step: 1)
                                        .frame(minWidth: 120, idealWidth: 200, maxWidth: 200)
                                        .disabled(isProcessing || (selectedMode != .smart && !encodeVideo))
                                    Text("\(Int(crfValue))")
                                        .frame(width: 30)
                                        .monospacedDigit()
                                }
                            }

                            SettingsRow(
                                "Resolution",
                                subtitle: selectedMode == .smart
                                    ? "Used when Smart chooses H.265 encoding"
                                    : "Scale video to specified resolution"
                            ) {
                                Picker("", selection: $selectedResolution) {
                                    ForEach(ResolutionOption.allCases, id: \.self) { resolution in
                                        Text(resolution.description).tag(resolution)
                                    }
                                }
                                .pickerStyle(.menu)
                                .disabled(isProcessing || (selectedMode != .smart && !encodeVideo))
                            }

                            SettingsRow(
                                "Encoder Preset",
                                subtitle: selectedMode == .smart
                                    ? "Used when Smart chooses H.265 encoding"
                                    : "Slower = better compression. Default: fast"
                            ) {
                                Picker("", selection: $selectedPreset) {
                                    ForEach(PresetOption.allCases, id: \.self) { preset in
                                        Text(preset.description).tag(preset)
                                    }
                                }
                                .pickerStyle(.menu)
                                .disabled(isProcessing || (selectedMode != .smart && !encodeVideo))
                            }
                        }

                        SettingsRow("Create Subfolders", subtitle: "Each file will be saved in its own subfolder") {
                            Toggle("", isOn: $createSubfolders)
                                .toggleStyle(.switch)
                                .disabled(isProcessing)
                        }

                        SettingsRow("Automatic Rename", subtitle: "Clean movie/TV output names when patterns are detected") {
                            Toggle("", isOn: $automaticRename)
                                .toggleStyle(.switch)
                                .disabled(isProcessing)
                        }

                        SettingsRow("Delete Original", subtitle: "Remove source files after successful conversion") {
                            Toggle("", isOn: $deleteOriginal)
                                .toggleStyle(.switch)
                                .disabled(isProcessing)
                        }

                        SettingsRow("Keep English Audio Only", subtitle: "Ignore non-English audio tracks during processing") {
                            Toggle("", isOn: $keepEnglishAudioOnly)
                                .toggleStyle(.switch)
                                .disabled(isProcessing)
                        }

                        SettingsRow(
                            "Keep All English Audio Tracks",
                            subtitle: keepEnglishAudioOnly
                                ? "Keep commentary and alternate English mixes instead of choosing one main track"
                                : "Keep every English track while leaving other languages unchanged"
                        ) {
                            Toggle("", isOn: $keepAllEnglishAudioTracks)
                                .toggleStyle(.switch)
                                .disabled(isProcessing)
                        }

                        SettingsRow("Keep English Subtitles Only", subtitle: "Ignore non-English subtitle tracks during processing") {
                            Toggle("", isOn: $keepEnglishSubtitlesOnly)
                                .toggleStyle(.switch)
                                .disabled(isProcessing)
                        }

                        SettingsRow(
                            "Keep All English Subtitle Tracks",
                            subtitle: keepEnglishSubtitlesOnly
                                ? "Keep forced and SDH variants instead of choosing one complete subtitle track"
                                : "Keep every English subtitle variant while leaving other languages unchanged"
                        ) {
                            Toggle("", isOn: $keepAllEnglishSubtitleTracks)
                                .toggleStyle(.switch)
                                .disabled(isProcessing)
                        }

                        Divider()

                        PostProcessScriptSettingsSection(
                            scriptPath: $postProcessScriptPath,
                            runTiming: $postProcessScriptRunTiming,
                            passFileNameAsFirstArgument: $postProcessScriptPassFileNameAsFirstArgument,
                            isProcessing: isProcessing
                        )
                        }
                        .padding(.vertical, 4)
                        .padding(.trailing, 14)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            clearInvalidPresetSelection()
        }
        .onChange(of: encodedPresets) { _, _ in
            clearInvalidPresetSelection()
        }
        .alert("Save Processing Preset", isPresented: $isShowingSavePresetAlert) {
            TextField("Preset Name", text: $newPresetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                saveCurrentSettings()
            }
            .disabled(
                newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || newPresetUsesReservedName
            )
        } message: {
            Text(
                newPresetUsesReservedName
                    ? "“\(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines))” is a built-in preset name. Choose a different name."
                    : "Save the current processing settings for future batches. An existing preset with the same name will be updated."
            )
        }
        .alert("Delete Processing Preset?", isPresented: $isShowingDeletePresetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteSelectedPreset()
            }
        } message: {
            Text("This removes “\(selectedProcessingPreset?.name ?? "this preset")”.")
        }
    }

    private var processingPresetsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        presetSummary
                        Spacer(minLength: 8)
                        presetActionButtons
                    }
                    .frame(minWidth: 390)

                    VStack(alignment: .leading, spacing: 8) {
                        presetSummary
                        presetActionButtons
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)

                if selectedPresetIsModified {
                    Label(
                        selectedPresetIsBuiltIn
                            ? "Modified — save as a new preset to keep these changes."
                            : "Modified — update the preset to keep these changes.",
                        systemImage: "pencil.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text("Choose presets from Processing Setup, or save these settings for later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Preset Management", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var presetSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Selected Preset")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)

            Text(
                selectedProcessingPreset.map(presetDisplayName)
                    ?? "Custom Settings"
            )
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presetActionButtons: some View {
        HStack(spacing: 6) {
            Button {
                newPresetName = ""
                isShowingSavePresetAlert = true
            } label: {
                Image(systemName: "plus")
            }
            .help("Save current settings as a new preset")
            .disabled(isProcessing)

            Button {
                updateSelectedPreset()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Save changes to the selected preset")
            .disabled(
                isProcessing
                || selectedProcessingPreset == nil
                || selectedPresetIsBuiltIn
                || !selectedPresetIsModified
            )

            Button {
                resetSelectedPreset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("Discard unsaved changes and restore the selected preset")
            .disabled(
                isProcessing
                || selectedProcessingPreset == nil
                || !selectedPresetIsModified
            )

            Button(role: .destructive) {
                isShowingDeletePresetAlert = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete selected preset")
            .disabled(isProcessing || selectedProcessingPreset == nil || selectedPresetIsBuiltIn)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func currentPreset(id: UUID, name: String) -> ProcessingPreset {
        ProcessingPreset(
            id: id,
            name: name,
            modeRawValue: selectedMode.rawValue,
            smartRemuxMegabytesPerMinute: smartRemuxMegabytesPerMinute,
            crfValue: crfValue,
            resolutionRawValue: selectedResolution.rawValue,
            encoderPresetRawValue: selectedPreset.rawValue,
            encodeVideo: encodeVideo,
            encodeAudio: encodeAudio,
            createSubfolders: createSubfolders,
            automaticRename: automaticRename,
            deleteOriginal: deleteOriginal,
            keepEnglishAudioOnly: keepEnglishAudioOnly,
            keepAllEnglishAudioTracks: keepAllEnglishAudioTracks,
            keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly,
            keepAllEnglishSubtitleTracks: keepAllEnglishSubtitleTracks,
            postProcessScriptPath: postProcessScriptPath,
            postProcessScriptRunTimingRawValue: postProcessScriptRunTiming.rawValue,
            postProcessScriptPassFileNameAsFirstArgument: postProcessScriptPassFileNameAsFirstArgument
        )
    }

    private func presetDisplayName(_ preset: ProcessingPreset) -> String {
        var name = ProcessingPreset.builtInPresets.contains(where: { $0.id == preset.id })
            ? "\(preset.name) (Built-in)"
            : preset.name
        if preset.id == selectedProcessingPresetID, selectedPresetIsModified {
            name += " • Modified"
        }
        return name
    }

    private func clearInvalidPresetSelection() {
        guard selectedProcessingPresetID != nil, selectedProcessingPreset == nil else { return }
        selectedProcessingPresetID = nil
    }

    private func saveCurrentSettings() {
        let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        guard !newPresetUsesReservedName else { return }

        var presets = userProcessingPresets
        if let index = presets.firstIndex(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            let preset = currentPreset(id: presets[index].id, name: name)
            presets[index] = preset
            persist(presets)
            selectedProcessingPresetID = preset.id
        } else {
            let preset = currentPreset(id: UUID(), name: name)
            presets.append(preset)
            persist(presets)
            selectedProcessingPresetID = preset.id
        }
    }

    private func updateSelectedPreset() {
        guard let selectedProcessingPreset else { return }
        guard !selectedPresetIsBuiltIn else { return }
        var presets = userProcessingPresets
        guard let index = presets.firstIndex(where: { $0.id == selectedProcessingPreset.id }) else {
            return
        }
        presets[index] = currentPreset(id: selectedProcessingPreset.id, name: selectedProcessingPreset.name)
        persist(presets)
    }

    private func resetSelectedPreset() {
        guard let selectedProcessingPreset else { return }
        apply(selectedProcessingPreset)
    }

    private func deleteSelectedPreset() {
        guard let selectedProcessingPresetID else { return }
        guard !selectedPresetIsBuiltIn else { return }
        let presets = userProcessingPresets.filter { $0.id != selectedProcessingPresetID }
        persist(presets)
        self.selectedProcessingPresetID = nil
    }

    private func persist(_ presets: [ProcessingPreset]) {
        guard let data = try? JSONEncoder().encode(presets),
              let encoded = String(data: data, encoding: .utf8) else {
            return
        }
        encodedPresets = encoded
    }

    private func apply(_ preset: ProcessingPreset) {
        selectedMode = preset.mode
        smartRemuxMegabytesPerMinute = min(
            max(
                preset.smartRemuxMegabytesPerMinute
                    ?? ProcessingMode.defaultSmartRemuxMegabytesPerMinute,
                5
            ),
            100
        )
        crfValue = min(max(preset.crfValue, 0), 50)
        selectedResolution = preset.resolution
        selectedPreset = preset.encoderPreset
        encodeVideo = preset.encodeVideo
        encodeAudio = preset.encodeAudio
        createSubfolders = preset.createSubfolders
        automaticRename = preset.automaticRename
        deleteOriginal = preset.deleteOriginal
        keepEnglishAudioOnly = preset.keepEnglishAudioOnly
        keepAllEnglishAudioTracks = preset.keepAllEnglishAudioTracks ?? false
        keepEnglishSubtitlesOnly = preset.keepEnglishSubtitlesOnly
        keepAllEnglishSubtitleTracks = preset.keepAllEnglishSubtitleTracks ?? false
        postProcessScriptPath = preset.postProcessScriptPath
        postProcessScriptRunTiming = preset.postProcessScriptRunTiming
        postProcessScriptPassFileNameAsFirstArgument =
            preset.postProcessScriptRunTiming == .afterEachItem
            && preset.postProcessScriptPassFileNameAsFirstArgument
    }

}

private struct PostProcessScriptSettingsSection: View {
    @Binding var scriptPath: String
    @Binding var runTiming: PostProcessScriptRunTiming
    @Binding var passFileNameAsFirstArgument: Bool
    let isProcessing: Bool

    private var scriptSubtitle: String {
        scriptPath.isEmpty ? "Optional local script to run after processing" : scriptPath
    }

    private var passFileNameBinding: Binding<Bool> {
        Binding(
            get: { runTiming == .afterEachItem && passFileNameAsFirstArgument },
            set: { passFileNameAsFirstArgument = runTiming == .afterEachItem ? $0 : false }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsRow("Post-Process Script", subtitle: scriptSubtitle) {
                HStack(spacing: 6) {
                    Button("Choose...") {
                        chooseScript()
                    }
                    .disabled(isProcessing)

                    if !scriptPath.isEmpty {
                        Button {
                            scriptPath = ""
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .help("Clear selected script")
                        .disabled(isProcessing)
                    }
                }
            }

            if !scriptPath.isEmpty {
                SettingsRow("Script Timing", subtitle: "Choose when the selected script runs") {
                    Picker("", selection: $runTiming) {
                        ForEach(PostProcessScriptRunTiming.allCases, id: \.self) { timing in
                            Text(timing.description).tag(timing)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isProcessing)
                }

                SettingsRow("Pass File Name First", subtitle: "For per-item scripts, pass the output file name before input/output paths") {
                    Toggle("", isOn: passFileNameBinding)
                        .toggleStyle(.switch)
                        .disabled(isProcessing || runTiming != .afterEachItem)
                }
            }
        }
        .onAppear(perform: clearPassFileNameIfNeeded)
        .onChange(of: runTiming) { _, _ in
            clearPassFileNameIfNeeded()
        }
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose a local script to run after processing"
        panel.prompt = "Choose"

        if !scriptPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: scriptPath).deletingLastPathComponent()
        }

        CleanFilePanelPresenter.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            guard preflightScriptAccess(url) else { return }
            scriptPath = url.path
        }
    }

    private func preflightScriptAccess(_ url: URL) -> Bool {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
            return true
        } catch {
            showScriptAccessAlert(url: url, error: error)
            return false
        }
    }

    private func showScriptAccessAlert(url: URL, error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could Not Read Post-Process Script"
        alert.informativeText = """
        MP4 Tool could not read \(url.path).

        Choose a script the app can read, or grant access when macOS asks. This check prevents a later CLI-started run from blocking on a file access prompt.

        \(error.localizedDescription)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func clearPassFileNameIfNeeded() {
        guard runTiming != .afterEachItem else { return }
        passFileNameAsFirstArgument = false
    }
}
