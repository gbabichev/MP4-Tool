import SwiftUI
import UniformTypeIdentifiers

private final class MP4ValidationDroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func snapshot() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

struct MP4ValidationView: View {
    @StateObject private var viewModel = MP4ValidationViewModel()
    @State private var showFlaggedOnly = false
    @State private var selectedRepairResultIDs = Set<UUID>()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusContent

            Text("Validate dropped MP4 files or MP4 files in a folder and its subfolders. Finds compatibility failures and suspicious audio authoring such as multiple default tracks or inactive multichannel audio.")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox("Folder") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Button("Open") {
                            viewModel.openInputFolderInFinder()
                        }
                        .controlSize(.small)
                        .disabled(viewModel.inputFolderPath.isEmpty && viewModel.droppedFilePaths.isEmpty)

                        Text("Input")
                            .font(.subheadline)
                    }
                    Text(viewModel.inputSelectionDescription)
                        .font(.caption)
                        .foregroundStyle(
                            viewModel.inputFolderPath.isEmpty && viewModel.droppedFilePaths.isEmpty
                                ? .tertiary : .secondary
                        )
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
                        HStack(spacing: 8) {
                            Button(showFlaggedOnly ? "Show All" : "Show Flagged") {
                                showFlaggedOnly.toggle()
                            }
                            .controlSize(.small)
                            .disabled(viewModel.results.isEmpty)

                            Button(allRepairableResultsSelected ? "Deselect All" : "Select All") {
                                if allRepairableResultsSelected {
                                    selectedRepairResultIDs.subtract(repairableResultIDs)
                                } else {
                                    selectedRepairResultIDs.formUnion(repairableResultIDs)
                                }
                            }
                            .controlSize(.small)
                            .disabled(
                                repairableResultIDs.isEmpty
                                    || viewModel.isScanning
                                    || viewModel.isRepairing
                            )
                        }

                        if displayedResults.isEmpty {
                            Text(showFlaggedOnly ? "No flagged files to display." : "No results to display.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .padding(.vertical, 12)
                        } else {
                            List(displayedResults) { result in
                                HStack(spacing: 12) {
                                    if result.isRepairable {
                                        Toggle("Repair", isOn: repairSelectionBinding(for: result.id))
                                            .labelsHidden()
                                            .toggleStyle(.checkbox)
                                            .disabled(viewModel.isScanning || viewModel.isRepairing)
                                            .help("Include this file in Repair Selected")
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.fileName)
                                            .lineLimit(1)
                                            .truncationMode(.middle)

                                        if let repairMessage = result.repairMessage {
                                            Text(repairMessage)
                                                .font(.caption2)
                                                .foregroundStyle(
                                                    repairMessage.hasPrefix("Saved ") ? Color.green : Color.orange
                                                )
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        Text(result.filePath)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer()

                                    Text(result.issue ?? "OK")
                                        .font(.caption2)
                                        .foregroundStyle(resultColor(result))
                                        .lineLimit(1)
                                        .help(result.issue ?? "No issues found")
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
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFolderDrop(providers: providers)
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    viewModel.selectInputFolder()
                } label: {
                    Label("Choose Folder...", systemImage: "folder")
                }
                .disabled(viewModel.isScanning || viewModel.isRepairing)
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

            ToolbarItem(placement: .navigation) {
                Button {
                    viewModel.repairSelected(resultIDs: selectedRepairResultIDs)
                } label: {
                    Label(
                        selectedRepairCount > 0 ? "Repair Selected (\(selectedRepairCount))" : "Repair Selected",
                        systemImage: "wrench.and.screwdriver"
                    )
                }
                .disabled(selectedRepairCount == 0 || viewModel.isScanning || viewModel.isRepairing)
                .help("Create repaired copies beside the originals")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if viewModel.isRepairing {
                    Button {
                        viewModel.cancelRepair()
                    } label: {
                        Label("Stop Repair", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                } else if viewModel.isScanning {
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
                        selectedRepairResultIDs.removeAll()
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

    private var selectedRepairCount: Int {
        viewModel.results.filter {
            selectedRepairResultIDs.contains($0.id) && $0.isRepairable
        }.count
    }

    private var repairableResultIDs: Set<UUID> {
        Set(viewModel.results.filter(\.isRepairable).map(\.id))
    }

    private var allRepairableResultsSelected: Bool {
        !repairableResultIDs.isEmpty
            && repairableResultIDs.isSubset(of: selectedRepairResultIDs)
    }

    private func repairSelectionBinding(for resultID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedRepairResultIDs.contains(resultID) },
            set: { isSelected in
                if isSelected {
                    selectedRepairResultIDs.insert(resultID)
                } else {
                    selectedRepairResultIDs.remove(resultID)
                }
            }
        )
    }

    private func resultColor(_ result: MP4ValidationResult) -> Color {
        switch result.severity {
        case .warning: return .orange
        case .error: return .red
        case nil: return .secondary
        }
    }

    private func sendFlaggedToMainApp() {
        openWindow(id: "main")
        DispatchQueue.main.async {
            viewModel.sendFlaggedToMainApp()
        }
    }

    private func handleFolderDrop(providers: [NSItemProvider]) -> Bool {
        guard !viewModel.isScanning, !viewModel.isRepairing else { return false }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let collector = MP4ValidationDroppedURLCollector()
        let group = DispatchGroup()
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url, error == nil else {
                    group.leave()
                    return
                }
                DispatchQueue.main.async {
                    collector.append(url)
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            let urls = collector.snapshot()
            guard !urls.isEmpty else { return }

            if urls.count == 1 {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(
                    atPath: urls[0].path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue {
                    _ = viewModel.setInputFolder(url: urls[0])
                    return
                }
            }

            _ = viewModel.setDroppedFiles(urls: urls)
        }

        return true
    }

    @ViewBuilder
    private var statusContent: some View {
        if viewModel.isScanning || viewModel.isRepairing {
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
                                || viewModel.scanAlertText.hasPrefix("Repaired files ")
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
