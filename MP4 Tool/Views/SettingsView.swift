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
    @Binding var crfValue: Double
    @Binding var selectedResolution: ResolutionOption
    @Binding var selectedPreset: PresetOption
    @Binding var encodeVideo: Bool
    @Binding var encodeAudio: Bool
    @Binding var createSubfolders: Bool
    @Binding var automaticRename: Bool
    @Binding var deleteOriginal: Bool
    @Binding var keepEnglishAudioOnly: Bool
    @Binding var keepEnglishSubtitlesOnly: Bool
    @Binding var postProcessScriptPath: String
    @Binding var postProcessScriptRunTiming: PostProcessScriptRunTiming
    @Binding var postProcessScriptPassFileNameAsFirstArgument: Bool
    let isProcessing: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Settings")
                    .font(.title3)
                    .fontWeight(.semibold)

                Spacer()
            }
            .frame(maxWidth: .infinity)

            ScrollView {
                GroupBox {
                    VStack(spacing: 12) {
                        SettingsRow("Mode", subtitle: "Choose encoding codec or remux without re-encoding") {
                            Picker("", selection: $selectedMode) {
                                ForEach(ProcessingMode.allCases, id: \.self) { mode in
                                    Text(mode.description).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(isProcessing)
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

                            SettingsRow("Quality (CRF)", subtitle: "Lower = better quality, larger file. Default 23.") {
                                HStack {
                                    Slider(value: $crfValue, in: 0...50, step: 1)
                                        .frame(width: 200)
                                        .disabled(isProcessing || !encodeVideo)
                                    Text("\(Int(crfValue))")
                                        .frame(width: 30)
                                        .monospacedDigit()
                                }
                            }

                            SettingsRow("Resolution", subtitle: "Scale video to specified resolution") {
                                Picker("", selection: $selectedResolution) {
                                    ForEach(ResolutionOption.allCases, id: \.self) { resolution in
                                        Text(resolution.description).tag(resolution)
                                    }
                                }
                                .pickerStyle(.menu)
                                .disabled(isProcessing || !encodeVideo)
                            }

                            SettingsRow("Preset", subtitle: "Slower = better compression. Default: fast") {
                                Picker("", selection: $selectedPreset) {
                                    ForEach(PresetOption.allCases, id: \.self) { preset in
                                        Text(preset.description).tag(preset)
                                    }
                                }
                                .pickerStyle(.menu)
                                .disabled(isProcessing || !encodeVideo)
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

                        SettingsRow("Keep English Subtitles Only", subtitle: "Ignore non-English subtitle tracks during processing") {
                            Toggle("", isOn: $keepEnglishSubtitlesOnly)
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
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

        if panel.runModal() == .OK, let url = panel.url {
            scriptPath = url.path
        }
    }

    private func clearPassFileNameIfNeeded() {
        guard runTiming != .afterEachItem else { return }
        passFileNameAsFirstArgument = false
    }
}
