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
    @Binding var createSubfolders: Bool
    @Binding var deleteOriginal: Bool
    @Binding var keepEnglishAudioOnly: Bool
    let isProcessing: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)

            SettingsRow("Mode", subtitle: "Encode converts to H.265, Remux copies streams") {
                Picker("", selection: $selectedMode) {
                    ForEach(ProcessingMode.allCases, id: \.self) { mode in
                        Text(mode.description).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isProcessing)
            }

            if selectedMode == .encode {
                SettingsRow("Quality (CRF)", subtitle: "Lower = better quality, larger file. Default 23.") {
                    HStack {
                        Slider(value: $crfValue, in: 18...28, step: 1)
                            .frame(width: 200)
                            .disabled(isProcessing)
                        Text("\(Int(crfValue))")
                            .frame(width: 30)
                            .monospacedDigit()
                    }
                }
            }

            SettingsRow("Create Subfolders", subtitle: "Each file will be saved in its own subfolder") {
                Toggle("", isOn: $createSubfolders)
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

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
