import SwiftUI

struct OffsetStartCheckerView: View {
    @StateObject private var viewModel = OffsetStartCheckerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusContent

            GroupBox("Folder") {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Input Folder")
                            .font(.subheadline)
                        Text(viewModel.inputFolderPath.isEmpty ? "Select folder containing MP4 files" : viewModel.inputFolderPath)
                            .font(.caption)
                            .foregroundStyle(viewModel.inputFolderPath.isEmpty ? .tertiary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button {
                        viewModel.selectInputFolder()
                    } label: {
                        Label("Choose...", systemImage: "folder")
                    }
                    .controlSize(.small)
                }
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
                    List(viewModel.results) { result in
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

                            Text(ptsLabel(for: result))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(result.hasOffsetStart ? Color.red : Color.secondary)
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
                        .foregroundStyle(viewModel.scanAlertText.contains("All checked") ? Color.secondary : Color.red)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        } else {
            HStack(spacing: 8) {
                Text(viewModel.ffprobeStatusLabel)
                    .font(.caption)
                    .foregroundStyle(viewModel.ffprobeAvailable ? Color.secondary : Color.orange)
                Text(viewModel.ffmpegStatusLabel)
                    .font(.caption)
                    .foregroundStyle(viewModel.ffmpegAvailable ? Color.secondary : Color.orange)
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
}
