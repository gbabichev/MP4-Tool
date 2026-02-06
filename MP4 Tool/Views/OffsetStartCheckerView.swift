import SwiftUI

struct OffsetStartCheckerView: View {
    @StateObject private var viewModel = OffsetStartCheckerViewModel()
    @State private var showFailuresOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusContent

            VStack(alignment: .leading, spacing: 4) {
                Text("Check Offset Starts scans MP4 files to make sure playback begins at 00:00 and can try to repair files in place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Some files can still fail repair or be marked as FAIL: Please Re-Encode. Those files should be fully re-encoded in the main app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Folder") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input Folder")
                        .font(.subheadline)
                    Text(viewModel.inputFolderPath.isEmpty ? "Select folder containing MP4 files" : viewModel.inputFolderPath)
                        .font(.caption)
                        .foregroundStyle(viewModel.inputFolderPath.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Scan Results") {
                if viewModel.results.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("Run a scan to check first video packet pts_time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if displayedResults.isEmpty {
                            Text(showFailuresOnly ? "No failures to display." : "No results to display.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .padding(.vertical, 12)
                        } else {
                            List(displayedResults) { result in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.fileName)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(result.filePath)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(ptsLabel(for: result))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(result.hasOffsetStart ? Color.red : Color.secondary)

                                        if let fixStatus = fixStatusLabel(for: result) {
                                            Text(fixStatus)
                                                .font(.caption2)
                                                .foregroundStyle(fixStatusColor(for: result))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 760, minHeight: 560)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    viewModel.selectInputFolder()
                } label: {
                    Label("Choose Folder...", systemImage: "folder")
                }
                .disabled(viewModel.isScanning || viewModel.isFixing)
            }

            ToolbarItem(placement: .navigation) {
                Button(showFailuresOnly ? "Show All" : "Show Failures") {
                    showFailuresOnly.toggle()
                }
                .disabled(viewModel.results.isEmpty)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isScanning || viewModel.isFixing {
                    Button {
                        if viewModel.isScanning {
                            viewModel.cancelScan()
                        } else {
                            viewModel.cancelFix()
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        viewModel.scanOffsetStarts()
                    } label: {
                        Label("Scan", systemImage: "magnifyingglass")
                    }
                    .disabled(!viewModel.canScan)
                    .keyboardShortcut("r", modifiers: .command)

                    Button {
                        viewModel.fixOffsetStartsInPlace()
                    } label: {
                        Label("Fix Offsets", systemImage: "wrench.and.screwdriver")
                    }
                    .disabled(!viewModel.canFix)
                }
            }
        }
    }

    private var displayedResults: [OffsetStartCheckResult] {
        guard showFailuresOnly else { return viewModel.results }
        return viewModel.results.filter(isFailure)
    }

    private func isFailure(_ result: OffsetStartCheckResult) -> Bool {
        if result.firstPTS == nil {
            return true
        }

        if result.hasOffsetStart {
            return true
        }

        switch result.fixOutcome {
        case .worseAfterRemux, .needsFullReencode:
            return true
        case .notAttempted, .fixedByRemux:
            return false
        }
    }

    private func ptsLabel(for result: OffsetStartCheckResult) -> String {
        guard let firstPTS = result.firstPTS else {
            return "pts_time: unavailable"
        }

        let numeric = String(format: "%.6f", firstPTS)
        if result.hasOffsetStart {
            return "pts_time: \(numeric) (offset)"
        }
        return "pts_time: \(numeric)"
    }

    private func fixStatusLabel(for result: OffsetStartCheckResult) -> String? {
        switch result.fixOutcome {
        case .notAttempted:
            return nil
        case .fixedByRemux:
            return "Fixed: remux"
        case .worseAfterRemux:
            return "FAIL: Please Re-Encode"
        case .needsFullReencode:
            return "Needs full re-encode"
        }
    }

    private func fixStatusColor(for result: OffsetStartCheckResult) -> Color {
        switch result.fixOutcome {
        case .notAttempted:
            return .secondary
        case .fixedByRemux:
            return .secondary
        case .worseAfterRemux:
            return .red
        case .needsFullReencode:
            return .red
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if viewModel.isScanning {
            HStack(spacing: 8) {
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
                .controlSize(.small)
                .disabled(!viewModel.canCancelScan)
                if !viewModel.scanAlertText.isEmpty {
                    Text(viewModel.scanAlertText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else if viewModel.isFixing {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.9)
                Text(viewModel.fixProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") {
                    viewModel.cancelFix()
                }
                .controlSize(.small)
                .disabled(!viewModel.canCancelFix)
                if !viewModel.scanAlertText.isEmpty {
                    Text(viewModel.scanAlertText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else if !viewModel.scanProgress.isEmpty {
            HStack(spacing: 8) {
                Text(viewModel.scanProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !viewModel.scanAlertText.isEmpty {
                    Text(viewModel.scanAlertText)
                        .font(.caption)
                        .foregroundStyle(viewModel.scanAlertText.hasPrefix("Fixed ") ? Color.secondary : Color.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else {
            if !viewModel.scanAlertText.isEmpty {
                HStack(spacing: 8) {
                    Text(viewModel.scanAlertText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
