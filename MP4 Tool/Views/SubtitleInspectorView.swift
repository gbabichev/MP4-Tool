import SwiftUI

struct SubtitleInspectorView: View {
    let isActive: Bool
    let navigationContent: AnyView?
    let sharedInputURL: Binding<URL?>?

    @StateObject private var viewModel = SubtitleInspectorViewModel()
    @State private var showNeedsAttentionOnly = false
    @State private var selectedResultIDs: Set<UUID> = []
    @State private var lastAppliedSharedInputPath: String?
    @AppStorage("subtitleInspectorRequireEnglish") private var requireEnglishSubtitles = false

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
        Group {
            if isActive {
                NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let navigationContent {
                        navigationContent
                    }

                    if navigationContent == nil {
                        Text(subtitleScanDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    GroupBox("Scan Options") {
                        HStack(spacing: 10) {
                            Image(systemName: "character.book.closed")
                                .foregroundStyle(requireEnglishSubtitles ? Color.accentColor : Color.secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Scan for English Subtitles")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("Require at least one subtitle track explicitly tagged English.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 8)

                            Toggle("Scan for English Subtitles", isOn: $requireEnglishSubtitles)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .disabled(viewModel.isScanning)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationSplitViewColumnWidth(
                min: navigationContent == nil ? 340 : 360,
                ideal: 380,
                max: 420
            )
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                GroupBox {
                    if viewModel.isScanning {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Scanning subtitle tracks…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            InspectRepairProgressDetails(
                                fraction: viewModel.operationProgressFraction,
                                currentItem: viewModel.operationCurrentItem,
                                totalItems: viewModel.operationTotalItems,
                                estimatedRemaining: viewModel.operationEstimatedRemaining
                            )
                            if !viewModel.statusMessage.isEmpty {
                                Text(viewModel.statusMessage)
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
                            Image(systemName: "captions.bubble")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text(emptyResultsMessage)
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
                                        showNeedsAttentionOnly.toggle()
                                    } label: {
                                        Label(
                                            showNeedsAttentionOnly ? "Show All" : "Issues Only",
                                            systemImage: showNeedsAttentionOnly
                                                ? "list.bullet" : "captions.bubble.fill"
                                        )
                                    }
                                    .disabled(viewModel.results.isEmpty)

                                    Button {
                                        if allAttentionResultsSelected {
                                            selectedResultIDs.subtract(attentionResultIDs)
                                        } else {
                                            selectedResultIDs.formUnion(attentionResultIDs)
                                        }
                                    } label: {
                                        Label(
                                            allAttentionResultsSelected ? "Deselect All" : "Select All",
                                            systemImage: allAttentionResultsSelected
                                                ? "checkmark.circle.fill" : "checkmark.circle"
                                        )
                                    }
                                    .disabled(attentionResultIDs.isEmpty || viewModel.isScanning)
                                }
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 8)
                            .padding(.top, 4)

                            if displayedResults.isEmpty {
                                Text("No subtitle issues to display.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                    .padding(.vertical, 12)
                            } else {
                                List(displayedResults) { result in
                                    HStack(spacing: 12) {
                                        if result.needsAttention {
                                            Toggle("Select", isOn: selectionBinding(for: result.id))
                                                .labelsHidden()
                                                .toggleStyle(.checkbox)
                                                .disabled(viewModel.isScanning)
                                                .help("Select this subtitle issue")
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

                                        Spacer(minLength: 12)

                                        Text(result.issue)
                                            .font(.caption2)
                                            .foregroundStyle(resultColor(result))
                                            .lineLimit(1)
                                            .help(result.issue)

                                        Button(role: .destructive) {
                                            selectedResultIDs.remove(result.id)
                                            viewModel.removeResult(id: result.id)
                                        } label: {
                                            Image(systemName: "trash")
                                                .frame(width: 20, height: 20)
                                        }
                                        .buttonStyle(.borderless)
                                        .controlSize(.small)
                                        .disabled(viewModel.isScanning)
                                        .help("Remove from results")
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            selectedResultIDs.remove(result.id)
                                            viewModel.removeResult(id: result.id)
                                        } label: {
                                            Label("Remove from Results", systemImage: "trash")
                                        }
                                        .disabled(viewModel.isScanning)
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
                .navigationSplitViewStyle(.balanced)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onChange(of: sharedInputURL?.wrappedValue?.path) { _, _ in
            applySharedInput()
        }
        .onChange(of: viewModel.isScanning) { _, isScanning in
            if !isScanning { applySharedInput() }
        }
        .onChange(of: attentionResultIDs) { _, newIDs in
            selectedResultIDs.formIntersection(newIDs)
        }
        .onChange(of: requireEnglishSubtitles) { _, _ in
            selectedResultIDs = []
            showNeedsAttentionOnly = false
            viewModel.resetResultsForOptionChange()
        }
        .onAppear(perform: applySharedInput)
        .onReceive(NotificationCenter.default.publisher(for: inspectRepairResetAllNotification)) { _ in
            showNeedsAttentionOnly = false
            selectedResultIDs.removeAll()
            lastAppliedSharedInputPath = nil
            viewModel.resetAll()
        }
        .toolbar {
            if isActive {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button {
                            viewModel.exportCSV(includeAll: true)
                        } label: {
                            Label("Export All…", systemImage: "list.bullet")
                        }

                        Button {
                            viewModel.exportCSV(includeAll: false)
                        } label: {
                            Label("Export Issues…", systemImage: "exclamationmark.triangle")
                        }
                        .disabled(!viewModel.canExportIssues)
                    } label: {
                        Label("Export CSV…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!viewModel.canExport)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    if viewModel.isScanning {
                        Button {
                            viewModel.cancel()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .toolbarStopActionStyle()
                    } else {
                        Button {
                            selectedResultIDs = []
                            viewModel.scan(requireEnglish: requireEnglishSubtitles)
                        } label: {
                            Label("Scan", systemImage: "magnifyingglass")
                        }
                        .disabled(!viewModel.canScan)
                    }
                }
            }
        }
    }

    private var attentionResultIDs: Set<UUID> {
        Set(viewModel.attentionResults.map(\.id))
    }

    private var allAttentionResultsSelected: Bool {
        !attentionResultIDs.isEmpty && attentionResultIDs.isSubset(of: selectedResultIDs)
    }

    private var displayedResults: [SubtitleInspectionResult] {
        showNeedsAttentionOnly ? viewModel.attentionResults : viewModel.results
    }

    private var resultsSummary: String {
        if showNeedsAttentionOnly {
            return "\(displayedResults.count) need attention of \(viewModel.results.count)"
        }
        return "\(viewModel.results.count) file\(viewModel.results.count == 1 ? "" : "s")"
    }

    private var emptyResultsMessage: String {
        if viewModel.statusMessage.contains("Scan option changed") {
            return "Run a new scan using the selected subtitle rule."
        }
        return requireEnglishSubtitles
            ? "Run a scan to find MP4 files without English-tagged subtitles."
            : "Run a scan to find MP4 files without subtitle tracks."
    }

    private var subtitleScanDescription: String {
        if requireEnglishSubtitles {
            return "Find MP4 files that do not contain a subtitle track explicitly tagged English. Files with subtitles in other languages are distinguished from files with no subtitle tracks."
        }
        return "Find MP4 files that do not contain any subtitle tracks. Files that cannot be inspected are called out separately rather than being reported as missing subtitles."
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedResultIDs.contains(id) },
            set: { selected in
                if selected { selectedResultIDs.insert(id) }
                else { selectedResultIDs.remove(id) }
            }
        )
    }

    private func resultColor(_ result: SubtitleInspectionResult) -> Color {
        switch result.status {
        case .subtitlesPresent(_, let englishCount, let requiresEnglish):
            requiresEnglish && englishCount == 0 ? .orange : .secondary
        case .missing: .orange
        case .unreadable: .red
        }
    }

    private func applySharedInput() {
        guard let url = sharedInputURL?.wrappedValue,
              url.path != lastAppliedSharedInputPath,
              !viewModel.isScanning else { return }
        lastAppliedSharedInputPath = url.path
        viewModel.acceptInput(url: url)
    }
}
