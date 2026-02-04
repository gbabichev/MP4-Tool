//
//  VideoSplitterView.swift
//  MP4 Tool
//
//  Created by George Babichev on 1/26/26.
//

import SwiftUI

struct VideoSplitterView: View {
    @StateObject private var viewModel = VideoSplitterViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack(spacing: 12) {
                statusContent
                Spacer()
            }

            Divider()

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Folders") {
                    VStack(spacing: 12) {
                        FolderPickerRow(
                            title: "Input Folder",
                            subtitle: viewModel.inputFolderPath.isEmpty ? "Select folder containing MP4 files" : viewModel.inputFolderPath,
                            isPlaceholder: viewModel.inputFolderPath.isEmpty,
                            buttonLabel: "Choose...",
                            systemImage: "folder"
                        ) {
                            viewModel.selectFolder(isInput: true)
                        }

                        FolderPickerRow(
                            title: "Output Folder",
                            subtitle: viewModel.outputFolderPath.isEmpty ? "Select folder for split files" : viewModel.outputFolderPath,
                            isPlaceholder: viewModel.outputFolderPath.isEmpty,
                            buttonLabel: "Choose...",
                            systemImage: "folder.badge.gearshape"
                        ) {
                            viewModel.selectFolder(isInput: false)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Detection Settings") {
                    VStack(spacing: 12) {
                        SettingWithCaption(
                            title: "Black Min Duration (sec)",
                            caption: "Minimum length of a black segment to consider for splitting.",
                            value: $viewModel.blackMinDuration,
                            format: .number.precision(.fractionLength(2)),
                            range: 0...10
                        )

                        SettingWithCaption(
                            title: "Black Threshold (sec)",
                            caption: "Ignore black frames before this timestamp (skip intros).",
                            value: $viewModel.blackThresholdSeconds,
                            format: .number.precision(.fractionLength(0)),
                            range: 0...7200
                        )

                        VStack(alignment: .leading, spacing: 6) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Pixel Threshold")
                                        .font(.subheadline)
                                    Spacer()
                                    TextField("", value: $viewModel.picThreshold, format: .number.precision(.fractionLength(2)))
                                        .frame(width: 80)
                                        .textFieldStyle(.roundedBorder)
                                        .onChange(of: viewModel.picThreshold) { _, _ in
                                            viewModel.clampSettings()
                                        }
                                }

                                Slider(value: $viewModel.picThreshold, in: 0...1, step: 0.01)
                            }

                            Text("How dark a pixel must be to count as black (0.0–1.0).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        ToggleSettingWithCaption(
                            title: "Scan Around Halfway",
                            caption: "Only scan a window centered on the midpoint of the video.",
                            isOn: $viewModel.halfwayScanEnabled
                        )

                        SettingWithCaption(
                            title: "Halfway Window (min)",
                            caption: "Total window centered on 50% (e.g., 6 min = 3 before + 3 after).",
                            value: $viewModel.halfwayWindowMinutes,
                            format: .number.precision(.fractionLength(0)),
                            range: 1...60
                        )
                        .disabled(!viewModel.halfwayScanEnabled)

                        ToggleSettingWithCaption(
                            title: "Rename Files",
                            caption: "Rename outputs like E01-E02 → E01/E02.",
                            isOn: $viewModel.renameFiles
                        )
                    }
                    .padding(.vertical, 4)
                }

                Spacer()
                }
                .frame(minWidth: 420, maxWidth: 520)

                GroupBox {
                    if viewModel.results.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("Scan a folder to find split points.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                    } else {
                        List {
                            ForEach(viewModel.results) { result in
                                HStack(spacing: 12) {
                                    Toggle(isOn: Binding(
                                        get: { viewModel.selectedResultIDs.contains(result.id) },
                                        set: { isSelected in
                                            if isSelected {
                                                viewModel.selectedResultIDs.insert(result.id)
                                            } else {
                                                viewModel.selectedResultIDs.remove(result.id)
                                            }
                                        }
                                    )) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(result.fileName)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Text(viewModel.outputPreview(for: result))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    .toggleStyle(.checkbox)

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 4) {
                                        TextField("mm:ss", text: Binding(
                                            get: { viewModel.manualSplitTimeText(for: result.id) },
                                            set: { viewModel.setManualSplitTimeText($0, for: result.id) }
                                        ))
                                            .font(.system(.caption, design: .monospaced))
                                            .frame(width: 70)
                                            .textFieldStyle(.roundedBorder)
                                            .controlSize(.small)
                                        Text("Auto: \(result.splitTimeLabel)")
                                            .font(.caption2)
                                            .foregroundStyle(result.hasAutoSplit ? Color.secondary : Color.red)
                                        if !viewModel.manualSplitTimeText(for: result.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                           !viewModel.manualSplitTimeIsValid(for: result) {
                                            Text("Invalid")
                                                .font(.caption2)
                                                .foregroundStyle(.red)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Split Candidates")
                        Spacer()
                        if !viewModel.results.isEmpty {
                            let allSelected = viewModel.selectedResultIDs.count == viewModel.results.count
                            Button(allSelected ? "Deselect All" : "Select All") {
                                if allSelected {
                                    viewModel.selectedResultIDs.removeAll()
                                } else {
                                    viewModel.selectedResultIDs = Set(viewModel.results.map { $0.id })
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 760, minHeight: 800)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isScanning {
                    Button {
                        viewModel.cancelScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        viewModel.scanForSplits()
                    } label: {
                        Label("Scan for Splits", systemImage: "magnifyingglass")
                    }
                    .disabled(!viewModel.canScan)
                    .keyboardShortcut("r", modifiers: .command)
                    
                    Button {
                        viewModel.splitSelectedFiles()
                    } label: {
                        Label("Split", systemImage: "scissors")
                    }
                    .disabled(!viewModel.canSplit)
                }
            }
        }
    }
}

private extension VideoSplitterView {
    @ViewBuilder
    var statusContent: some View {
        if viewModel.isScanning {
            ProgressView()
                .scaleEffect(0.9)
            Text(viewModel.scanProgress)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Stop") {
                viewModel.cancelScan()
            }
            .disabled(!viewModel.canCancelScan)
            if !viewModel.scanAlertText.isEmpty {
                Text(viewModel.scanAlertText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if viewModel.isSplitting {
            ProgressView()
                .scaleEffect(0.9)
            Text(viewModel.splitProgress)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !viewModel.scanAlertText.isEmpty {
                Text(viewModel.scanAlertText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if !viewModel.scanProgress.isEmpty {
            Text(viewModel.scanProgress)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !viewModel.scanAlertText.isEmpty {
                Text(viewModel.scanAlertText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if !viewModel.splitProgress.isEmpty {
            Text(viewModel.splitProgress)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !viewModel.scanAlertText.isEmpty {
                Text(viewModel.scanAlertText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Text(viewModel.ffmpegStatusLabel)
                .font(.caption)
                .foregroundColor(viewModel.ffmpegAvailable ? .secondary : .orange)
            if !viewModel.scanAlertText.isEmpty {
                Text(viewModel.scanAlertText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct FolderPickerRow: View {
    let title: String
    let subtitle: String
    let isPlaceholder: Bool
    let buttonLabel: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isPlaceholder ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(action: action) {
                Label(buttonLabel, systemImage: systemImage)
            }
        }
    }
}

private struct SettingRow: View {
    let title: String
    @Binding var value: Double
    let format: FloatingPointFormatStyle<Double>
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer()
            TextField("", value: $value, format: format)
                .frame(width: 80)
                .textFieldStyle(.roundedBorder)
                .onChange(of: value) { _, _ in
                    value = min(max(value, range.lowerBound), range.upperBound)
                }
        }
    }
}

private struct SettingWithCaption: View {
    let title: String
    let caption: String
    @Binding var value: Double
    let format: FloatingPointFormatStyle<Double>
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(title: title, value: $value, format: format, range: range)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ToggleSettingWithCaption: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: $isOn) {
                    Text(title)
                        .font(.subheadline)
                }
                .toggleStyle(.checkbox)
                Spacer()
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
