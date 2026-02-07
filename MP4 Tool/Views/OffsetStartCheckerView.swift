import SwiftUI

struct OffsetStartCheckerView: View {
    @StateObject private var viewModel = OffsetStartCheckerViewModel()
    @State private var showFailuresOnly = false
    @State private var showNeedsActionOnly = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusContent

            VStack(alignment: .leading, spacing: 4) {
                Text("Check Offset Starts scans MP4 files to make sure playback begins at 00:00 and can try to repair files in place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("If a file still needs full re-encoding, use the \(Image(systemName: "arrowshape.turn.up.right")) toolbar button to send it to the main app queue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Folder") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Button("Open") {
                            viewModel.openInputFolderInFinder()
                        }
                        .controlSize(.small)
                        .disabled(viewModel.inputFolderPath.isEmpty)

                        Text("Input Folder")
                            .font(.subheadline)
                    }
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
                        Text("Run a scan to check whether files start at 00:00.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button(showNeedsActionOnly ? "Show All" : "Show Needs Action") {
                                showNeedsActionOnly.toggle()
                            }
                            .controlSize(.small)
                            .disabled(showFailuresOnly || viewModel.results.isEmpty)

                            Button(showFailuresOnly ? "Show All" : "Show Failures") {
                                showFailuresOnly.toggle()
                                if showFailuresOnly {
                                    showNeedsActionOnly = false
                                }
                            }
                            .controlSize(.small)
                            .disabled(viewModel.results.isEmpty || (!viewModel.hasCompletedFixPass && !showFailuresOnly))
                        }

                        if displayedResults.isEmpty {
                            Text(emptyResultsMessage)
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
                Button {
                    sendFailuresToMainApp()
                } label: {
                    Label("Send Failed to Main", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(!viewModel.canSendFailuresToMainApp)
            }

            ToolbarItem(placement: .navigation) {
                Button {
                    viewModel.exportFailuresToFile()
                } label: {
                    Label("Export Failures...", systemImage: "square.and.arrow.up")
                }
                .disabled(!viewModel.canExportFailures)
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
                        showFailuresOnly = false
                        showNeedsActionOnly = false
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
        if showFailuresOnly {
            return viewModel.failureResults
        }

        if showNeedsActionOnly {
            return viewModel.actionRequiredResults
        }

        return viewModel.results
    }

    private var emptyResultsMessage: String {
        if showFailuresOnly {
            return "No failures to display."
        }

        if showNeedsActionOnly {
            return "No files need action."
        }

        return "No results to display."
    }

    private func sendFailuresToMainApp() {
        openWindow(id: "main")
        DispatchQueue.main.async {
            viewModel.sendFailuresToMainApp()
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
        case .failedNeedsReencode:
            return "FAIL: Please Re-Encode"
        }
    }

    private func fixStatusColor(for result: OffsetStartCheckResult) -> Color {
        switch result.fixOutcome {
        case .notAttempted:
            return .secondary
        case .fixedByRemux:
            return .secondary
        case .failedNeedsReencode:
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
                        .foregroundStyle(
                            viewModel.scanAlertText.contains("FAIL: Please Re-Encode")
                                ? Color.red
                                : Color.secondary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else {
            if !viewModel.scanAlertText.isEmpty {
                HStack(spacing: 8) {
                    Text(viewModel.scanAlertText)
                        .font(.caption)
                        .foregroundStyle(
                            viewModel.scanAlertText.hasPrefix("Exported ")
                                || viewModel.scanAlertText.hasPrefix("Sent ")
                                ? Color.secondary
                                : Color.red
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
