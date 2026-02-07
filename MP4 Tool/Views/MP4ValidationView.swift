import SwiftUI

struct MP4ValidationView: View {
    @StateObject private var viewModel = MP4ValidationViewModel()
    @State private var showFlaggedOnly = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusContent

            Text("Validate MP4 files in a folder (including subfolders) and flag files that may need full re-encoding before processing.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("Run validation to check MP4 compatibility.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(showFlaggedOnly ? "Show All" : "Show Flagged") {
                            showFlaggedOnly.toggle()
                        }
                        .controlSize(.small)
                        .disabled(viewModel.results.isEmpty)

                        if displayedResults.isEmpty {
                            Text(showFlaggedOnly ? "No flagged files to display." : "No results to display.")
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

                                    Text(result.issue ?? "OK")
                                        .font(.caption2)
                                        .foregroundStyle(result.isFlagged ? Color.red : Color.secondary)
                                        .lineLimit(1)
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
                .disabled(viewModel.isScanning)
            }

            ToolbarItem(placement: .navigation) {
                Button {
                    sendFlaggedToMainApp()
                } label: {
                    Label("Send Flagged to Main", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(!viewModel.canSendFlaggedToMainApp)
            }

            ToolbarItem(placement: .navigation) {
                Button {
                    viewModel.exportFlaggedToFile()
                } label: {
                    Label("Export Flagged...", systemImage: "square.and.arrow.up")
                }
                .disabled(!viewModel.canExportFlagged)
            }

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
                        showFlaggedOnly = false
                        viewModel.scan()
                    } label: {
                        Label("Validate", systemImage: "checkmark.circle")
                    }
                    .disabled(!viewModel.canScan)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
        }
    }

    private var displayedResults: [MP4ValidationResult] {
        showFlaggedOnly ? viewModel.flaggedResults : viewModel.results
    }

    private func sendFlaggedToMainApp() {
        openWindow(id: "main")
        DispatchQueue.main.async {
            viewModel.sendFlaggedToMainApp()
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
        } else if !viewModel.scanProgress.isEmpty {
            HStack(spacing: 8) {
                Text(viewModel.scanProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !viewModel.scanAlertText.isEmpty {
                    Text(viewModel.scanAlertText)
                        .font(.caption)
                        .foregroundStyle(
                            viewModel.scanAlertText.hasPrefix("Exported ")
                                || viewModel.scanAlertText.hasPrefix("Sent ")
                                ? Color.secondary
                                : (viewModel.flaggedResults.isEmpty ? Color.secondary : Color.red)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
