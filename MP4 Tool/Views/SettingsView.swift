//
//  SettingsView.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI

struct SettingsView: View {
    @Binding var selectedMode: ProcessingMode
    @Binding var crfValue: Double
    @Binding var selectedResolution: ResolutionOption
    @Binding var selectedPreset: PresetOption
    @Binding var createSubfolders: Bool
    @Binding var automaticRename: Bool
    @Binding var deleteOriginal: Bool
    @Binding var keepEnglishAudioOnly: Bool
    @Binding var keepEnglishSubtitlesOnly: Bool
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
                        SettingsRow("Quality (CRF)", subtitle: "Lower = better quality, larger file. Default 23.") {
                            HStack {
                                Slider(value: $crfValue, in: 0...50, step: 1)
                                    .frame(width: 200)
                                    .disabled(isProcessing)
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
                            .disabled(isProcessing)
                        }

                        SettingsRow("Preset", subtitle: "Slower = better compression. Default: fast") {
                            Picker("", selection: $selectedPreset) {
                                ForEach(PresetOption.allCases, id: \.self) { preset in
                                    Text(preset.description).tag(preset)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(isProcessing)
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

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
