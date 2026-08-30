import SwiftUI
import UniformTypeIdentifiers
import AppKit

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
    let isActive: Bool
    let navigationContent: AnyView?
    let sharedInputURL: Binding<URL?>?
    @StateObject private var viewModel = MP4ValidationViewModel()
    @State private var showFlaggedOnly = false
    @State private var selectedRepairResultIDs = Set<UUID>()
    @State private var lastAppliedSharedInputPath: String?
    @AppStorage("mp4ValidatorReplaceOriginal") private var useOriginalRepairFilename = false
    @AppStorage("mp4ValidatorUseCustomRepairFolder") private var useCustomRepairFolder = false
    @AppStorage("mp4ValidatorRepairFolderPath") private var customRepairFolderPath = ""

    init(
        isActive: Bool = true,
        navigationContent: AnyView? = nil,
        sharedInputURL: Binding<URL?>? = nil
    ) {
        self.isActive = isActive
        self.navigationContent = navigationContent
        self.sharedInputURL = sharedInputURL
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let navigationContent {
                        navigationContent
                    }

                    Text("Validate dropped MP4 files or MP4 files in a folder and its subfolders. Finds compatibility failures and suspicious audio authoring such as multiple default tracks or inactive multichannel audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if sharedInputURL == nil {
                    GroupBox("Input") {
                ToolSelectionRow(
                    title: inputSelectionTitle,
                    detail: viewModel.inputSelectionDescription,
                    isSelected: hasInputSelection,
                    emptySystemImage: "folder.badge.plus",
                    selectedSystemImage: viewModel.droppedFilePaths.isEmpty
                        ? "folder.fill" : "doc.on.doc.fill",
                    chooseLabel: "Choose…",
                    openLabel: viewModel.droppedFilePaths.isEmpty ? "Open" : "Reveal",
                    chooseDisabled: viewModel.isScanning || viewModel.isRepairing,
                    compactLayout: navigationContent != nil,
                    openAction: viewModel.openInputFolderInFinder,
                    chooseAction: viewModel.selectInput
                )
                .padding(.vertical, 4)
            }
                    }

                    GroupBox("Repair Output") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: useOriginalRepairFilename ? "doc" : "doc.badge.plus")
                            .foregroundStyle(useOriginalRepairFilename ? Color.orange : Color.accentColor)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep Original Name")
                                .font(.subheadline)
                            Text(
                                useOriginalRepairFilename
                                    ? useCustomRepairFolder
                                        ? "Use the source filename in the selected destination folder"
                                        : "Safely replace the source only after the repair passes validation"
                                    : "Keep the source and append _fixed to the repaired copy"
                            )
                            .font(.caption)
                            .foregroundStyle(
                                useOriginalRepairFilename && !useCustomRepairFolder
                                    ? Color.orange : Color.secondary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Toggle("Keep Original Name", isOn: $useOriginalRepairFilename)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(viewModel.isScanning || viewModel.isRepairing)
                    }

                    Divider()

                    HStack(spacing: 10) {
                        Image(systemName: useCustomRepairFolder ? "folder.fill.badge.plus" : "folder.fill")
                            .foregroundStyle(useCustomRepairFolder ? Color.accentColor : Color.secondary)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save to Another Folder")
                                .font(.subheadline)
                            Text(repairLocationDescription)
                                .font(.caption)
                                .foregroundStyle(
                                    useCustomRepairFolder && customRepairFolderPath.isEmpty
                                        ? Color.orange : Color.secondary
                                )
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer(minLength: 8)

                        Toggle("Save to Another Folder", isOn: $useCustomRepairFolder)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(viewModel.isScanning || viewModel.isRepairing)
                    }

                    if useCustomRepairFolder {
                        HStack(spacing: 8) {
                            Spacer()
                            Button("Choose…", action: chooseCustomRepairFolder)
                                .controlSize(.small)
                                .disabled(viewModel.isRepairing)

                            Button("Open", action: openCustomRepairFolder)
                                .controlSize(.small)
                                .disabled(customRepairFolderPath.isEmpty)
                        }
                    }
                }
                .padding(.vertical, 4)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 340, idealWidth: 380, maxWidth: 420)
            .background(Color.secondary.opacity(0.035))

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                GroupBox {
                if viewModel.isScanning || viewModel.isRepairing {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(viewModel.isRepairing ? "Repairing MP4 files…" : "Validating MP4 files…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        InspectRepairProgressDetails(
                            fraction: viewModel.operationProgressFraction,
                            currentItem: viewModel.operationCurrentItem,
                            totalItems: viewModel.operationTotalItems,
                            estimatedRemaining: viewModel.operationEstimatedRemaining
                        )
                        if !viewModel.scanProgress.isEmpty {
                            Text(viewModel.scanProgress)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.vertical, 12)
                } else if viewModel.results.isEmpty {
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
                            Label(resultsSummary, systemImage: "list.bullet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Spacer()

                            ControlGroup {
                                Button {
                                    showFlaggedOnly.toggle()
                                } label: {
                                    Label(
                                        showFlaggedOnly ? "Show All" : "Flagged Only",
                                        systemImage: showFlaggedOnly ? "list.bullet" : "exclamationmark.triangle"
                                    )
                                }
                                .disabled(viewModel.results.isEmpty)

                                Button {
                                    if allRepairableResultsSelected {
                                        selectedRepairResultIDs.subtract(repairableResultIDs)
                                    } else {
                                        selectedRepairResultIDs.formUnion(repairableResultIDs)
                                    }
                                } label: {
                                    Label(
                                        allRepairableResultsSelected ? "Deselect All" : "Select All",
                                        systemImage: allRepairableResultsSelected
                                            ? "checkmark.circle.fill" : "checkmark.circle"
                                    )
                                }
                                .disabled(
                                    repairableResultIDs.isEmpty
                                        || viewModel.isScanning
                                        || viewModel.isRepairing
                                )
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 4)

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
                                        Text(URL(fileURLWithPath: result.filePath).lastPathComponent)
                                            .lineLimit(1)
                                            .truncationMode(.middle)

                                        if let repairMessage = result.repairMessage {
                                            Text(repairMessage)
                                                .font(.caption2)
                                                .foregroundStyle(
                                                    repairMessage.hasPrefix("Saved ")
                                                        || repairMessage.hasPrefix("Replaced ")
                                                        ? Color.green : Color.orange
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 860, minHeight: 560)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFolderDrop(providers: providers)
        }
        .onChange(of: sharedInputURL?.wrappedValue?.path) { _, _ in
            applySharedInput()
        }
        .onChange(of: viewModel.isScanning) { _, isScanning in
            if !isScanning { applySharedInput() }
        }
        .onChange(of: viewModel.isRepairing) { _, isRepairing in
            if !isRepairing { applySharedInput() }
        }
        .onAppear(perform: applySharedInput)
        .toolbar {
            if isActive {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button {
                            viewModel.exportCSVReport(includeAll: true)
                        } label: {
                            Label("Export All…", systemImage: "list.bullet")
                        }

                        Button {
                            viewModel.exportCSVReport(includeAll: false)
                        } label: {
                            Label("Export Issues…", systemImage: "exclamationmark.triangle")
                        }
                        .disabled(!viewModel.canExportFlagged)
                    } label: {
                        Label("Export CSV…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!viewModel.canExportAll)
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
                        if !repairableResultIDs.isEmpty {
                            Button {
                                viewModel.repairSelected(
                                    resultIDs: selectedRepairResultIDs,
                                    useOriginalFilename: useOriginalRepairFilename,
                                    customOutputFolderPath: useCustomRepairFolder
                                        ? customRepairFolderPath : nil
                                )
                            } label: {
                                Label(
                                    selectedRepairCount > 0
                                        ? "Repair Selected (\(selectedRepairCount))"
                                        : "Repair Selected",
                                    systemImage: "wrench.and.screwdriver"
                                )
                            }
                            .disabled(selectedRepairCount == 0 || !repairDestinationIsReady)
                            .help(repairActionHelp)
                        }

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
    }

    private var repairDestinationIsReady: Bool {
        !useCustomRepairFolder || customRepairFolderIsValid
    }

    private var hasInputSelection: Bool {
        !viewModel.inputFolderPath.isEmpty || !viewModel.droppedFilePaths.isEmpty
    }

    private var inputSelectionTitle: String {
        if !viewModel.droppedFilePaths.isEmpty {
            return viewModel.droppedFilePaths.count == 1
                ? "Input MP4 File"
                : "Input MP4 Files"
        }
        return viewModel.inputFolderPath.isEmpty ? "No Input Selected" : "Input Folder"
    }

    private var customRepairFolderIsValid: Bool {
        guard !customRepairFolderPath.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: customRepairFolderPath,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue && FileManager.default.isWritableFile(atPath: customRepairFolderPath)
    }

    private var repairLocationDescription: String {
        if useCustomRepairFolder {
            return customRepairFolderPath.isEmpty
                ? "Choose where repaired files should be saved"
                : customRepairFolderPath
        }
        return "Save repaired files beside their sources"
    }

    private var repairActionHelp: String {
        if useOriginalRepairFilename && useCustomRepairFolder {
            return "Save repaired files in the selected folder using their original filenames"
        }
        if useOriginalRepairFilename {
            return "Replace each original only after its repair passes validation"
        }
        if useCustomRepairFolder {
            return "Create _fixed copies in the selected folder"
        }
        return "Create _fixed copies beside the originals"
    }

    private func chooseCustomRepairFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose where repaired MP4 files should be saved"

        if !customRepairFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customRepairFolderPath, isDirectory: true)
        }

        CleanFilePanelPresenter.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            customRepairFolderPath = url.path
        }
    }

    private func openCustomRepairFolder() {
        guard customRepairFolderIsValid else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: customRepairFolderPath, isDirectory: true))
    }

    private var displayedResults: [MP4ValidationResult] {
        showFlaggedOnly ? viewModel.flaggedResults : viewModel.results
    }

    private var resultsSummary: String {
        if showFlaggedOnly {
            return "\(displayedResults.count) flagged of \(viewModel.results.count)"
        }
        return "\(viewModel.results.count) file\(viewModel.results.count == 1 ? "" : "s")"
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

            if let sharedInputURL, let firstURL = urls.first {
                sharedInputURL.wrappedValue = firstURL
                return
            }

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

    private func applySharedInput() {
        guard let url = sharedInputURL?.wrappedValue,
              url.path != lastAppliedSharedInputPath,
              !viewModel.isScanning,
              !viewModel.isRepairing else { return }

        if viewModel.setInput(url: url) {
            lastAppliedSharedInputPath = url.path
        }
    }

}
