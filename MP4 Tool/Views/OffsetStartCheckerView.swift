import SwiftUI

struct OffsetStartCheckerView: View {
    let isActive: Bool
    let navigationContent: AnyView?
    let sharedInputURL: Binding<URL?>?
    @StateObject private var viewModel = OffsetStartCheckerViewModel()
    @State private var showNeedsActionOnly = false
    @State private var selectedResultIDs: Set<UUID> = []
    @State private var lastAppliedSharedInputPath: String?

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

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Check Offset Starts scans MP4 files to make sure playback begins at 00:00 and can try to repair files in place.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("If a file still needs full re-encoding, use the \(Image(systemName: "arrowshape.turn.up.right")) toolbar button to send it to the main app queue.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if sharedInputURL == nil {
                    GroupBox("Input") {
                ToolSelectionRow(
                    title: viewModel.inputFolderPath.isEmpty ? "No Folder Selected" : "Input Folder",
                    detail: viewModel.inputFolderPath.isEmpty
                        ? "Choose a folder containing MP4 files" : viewModel.inputFolderPath,
                    isSelected: !viewModel.inputFolderPath.isEmpty,
                    emptySystemImage: "folder.badge.plus",
                    selectedSystemImage: "folder.fill",
                    chooseLabel: "Choose…",
                    openLabel: "Open",
                    chooseDisabled: viewModel.isScanning || viewModel.isFixing,
                    compactLayout: navigationContent != nil,
                    openAction: viewModel.openInputFolderInFinder,
                    chooseAction: viewModel.selectInputFolder
                )
                .padding(.vertical, 4)
                    }
                    }

                    GroupBox("Repair Output") {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Replace In Place")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("A repaired remux replaces the original only after validation succeeds.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
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
                if viewModel.isScanning || viewModel.isFixing {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(viewModel.isFixing ? "Repairing timing offsets…" : "Scanning timing offsets…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        InspectRepairProgressDetails(
                            fraction: viewModel.operationProgressFraction,
                            currentItem: viewModel.operationCurrentItem,
                            totalItems: viewModel.operationTotalItems,
                            estimatedRemaining: viewModel.operationEstimatedRemaining
                        )
                        let detail = viewModel.isFixing ? viewModel.fixProgress : viewModel.scanProgress
                        if !detail.isEmpty {
                            Text(detail)
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
                            Label(offsetResultsSummary, systemImage: "list.bullet")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Spacer()

                            ControlGroup {
                                Button {
                                    showNeedsActionOnly.toggle()
                                } label: {
                                    Label(
                                        showNeedsActionOnly ? "Show All" : "Needs Action",
                                        systemImage: showNeedsActionOnly
                                            ? "list.bullet" : "exclamationmark.circle"
                                    )
                                }
                                .disabled(viewModel.results.isEmpty)

                                Button {
                                    if allRepairableSelected {
                                        selectedResultIDs.subtract(repairableResultIDs)
                                    } else {
                                        selectedResultIDs.formUnion(repairableResultIDs)
                                    }
                                } label: {
                                    Label(
                                        allRepairableSelected ? "Deselect All" : "Select All",
                                        systemImage: allRepairableSelected
                                            ? "checkmark.circle.fill" : "checkmark.circle"
                                    )
                                }
                                .disabled(
                                    repairableResultIDs.isEmpty
                                        || viewModel.isScanning
                                        || viewModel.isFixing
                                )
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 4)

                        if displayedResults.isEmpty {
                            Text(emptyResultsMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .padding(.vertical, 12)
                        } else {
                            List(displayedResults) { result in
                                HStack(spacing: 12) {
                                    if result.hasOffsetStart {
                                        Toggle("Repair", isOn: repairSelectionBinding(for: result.id))
                                            .labelsHidden()
                                            .toggleStyle(.checkbox)
                                            .disabled(viewModel.isScanning || viewModel.isFixing)
                                            .help("Include this file in Fix Offsets")
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(URL(fileURLWithPath: result.filePath).lastPathComponent)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 860, minHeight: 560)
        .onChange(of: sharedInputURL?.wrappedValue?.path) { _, _ in
            applySharedInput()
        }
        .onChange(of: viewModel.isScanning) { _, isScanning in
            if !isScanning { applySharedInput() }
        }
        .onChange(of: viewModel.isFixing) { _, isFixing in
            if !isFixing { applySharedInput() }
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
                        .disabled(!viewModel.canExportReport)
                    } label: {
                        Label("Export CSV…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!viewModel.canExportAll)
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
                        .toolbarStopActionStyle()
                        .keyboardShortcut(".", modifiers: .command)
                    } else {
                        if !repairableResultIDs.isEmpty {
                            Button {
                                viewModel.fixOffsetStartsInPlace(resultIDs: selectedResultIDs)
                            } label: {
                                Label(
                                    selectedResultIDs.isEmpty
                                        ? "Fix Selected" : "Fix Selected (\(selectedResultIDs.count))",
                                    systemImage: "wrench.and.screwdriver"
                                )
                            }
                            .disabled(!viewModel.canFix || selectedResultIDs.isEmpty)
                        }

                        Button {
                            showNeedsActionOnly = false
                            selectedResultIDs = []
                            viewModel.scanOffsetStarts()
                        } label: {
                            Label("Scan", systemImage: "magnifyingglass")
                        }
                        .disabled(!viewModel.canScan)
                        .keyboardShortcut("r", modifiers: .command)
                    }
                }
            }
        }
        .onChange(of: repairableResultIDs) { _, newIDs in
            selectedResultIDs.formIntersection(newIDs)
        }
    }

    private var displayedResults: [OffsetStartCheckResult] {
        if showNeedsActionOnly {
            return viewModel.actionRequiredResults
        }

        return viewModel.results
    }

    private var emptyResultsMessage: String {
        if showNeedsActionOnly {
            return "No files need action."
        }

        return "No results to display."
    }

    private var offsetResultsSummary: String {
        if showNeedsActionOnly {
            return "\(displayedResults.count) need action"
        }
        return "\(viewModel.results.count) file\(viewModel.results.count == 1 ? "" : "s")"
    }

    private var repairableResultIDs: Set<UUID> {
        Set(viewModel.results.filter(\.hasOffsetStart).map(\.id))
    }

    private var allRepairableSelected: Bool {
        !repairableResultIDs.isEmpty && repairableResultIDs.isSubset(of: selectedResultIDs)
    }

    private func repairSelectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedResultIDs.contains(id) },
            set: { selected in
                if selected { selectedResultIDs.insert(id) }
                else { selectedResultIDs.remove(id) }
            }
        )
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

    private func applySharedInput() {
        guard let url = sharedInputURL?.wrappedValue,
              url.path != lastAppliedSharedInputPath,
              !viewModel.isScanning,
              !viewModel.isFixing else { return }
        lastAppliedSharedInputPath = url.path
        viewModel.acceptInput(url: url)
    }

}
