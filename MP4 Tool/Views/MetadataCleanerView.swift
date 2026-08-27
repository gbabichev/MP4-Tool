import SwiftUI
import UniformTypeIdentifiers

private final class MetadataCleanerDroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func first() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return urls.first
    }
}

struct MetadataCleanerView: View {
    let isActive: Bool
    let navigationContent: AnyView?
    let sharedInputURL: Binding<URL?>?
    @StateObject private var viewModel = MetadataCleanerViewModel()
    @State private var selectedResultIDs: Set<UUID> = []
    @State private var showNeedsCleaningOnly = false
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

                    Text("Find release-group and attribution metadata, then remove only those fields with a validated in-place remux. Ordinary movie metadata, track descriptions, languages, subtitle roles, chapters, and media streams are preserved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if sharedInputURL == nil {
                    GroupBox("Input") {
                ToolSelectionRow(
                    title: viewModel.inputTitle,
                    detail: viewModel.inputDetail,
                    isSelected: !viewModel.inputPath.isEmpty,
                    emptySystemImage: "folder.badge.plus",
                    selectedSystemImage: viewModel.inputIsFolder ? "folder.fill" : "film.stack.fill",
                    chooseLabel: "Choose…",
                    openLabel: "Reveal",
                    chooseDisabled: viewModel.isBusy,
                    compactLayout: navigationContent != nil,
                    openAction: viewModel.revealInput,
                    chooseAction: viewModel.selectInput
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
                                Text("The original is replaced only after the cleaned copy passes validation.")
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
                if viewModel.isBusy {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text(metadataActivityTitle)
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)
                } else if viewModel.results.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tag.slash")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(emptyResultsMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Label(metadataResultsSummary, systemImage: "list.bullet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                            Spacer()

                            ControlGroup {
                                Button {
                                    showNeedsCleaningOnly.toggle()
                                } label: {
                                    Label(
                                        showNeedsCleaningOnly ? "Show All" : "Needs Cleanup",
                                        systemImage: showNeedsCleaningOnly
                                            ? "list.bullet" : "exclamationmark.triangle"
                                    )
                                }
                                .disabled(viewModel.results.isEmpty)

                                Button {
                                    if allCleanableSelected {
                                        selectedResultIDs.subtract(cleanableIDs)
                                    } else {
                                        selectedResultIDs.formUnion(cleanableIDs)
                                    }
                                } label: {
                                    Label(
                                        allCleanableSelected ? "Deselect All" : "Select All",
                                        systemImage: allCleanableSelected
                                            ? "checkmark.circle.fill" : "checkmark.circle"
                                    )
                                }
                                .disabled(viewModel.isBusy || cleanableIDs.isEmpty)
                            }
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 4)

                        if displayedResults.isEmpty {
                            Text("No files need cleanup.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .padding(.vertical, 12)
                        } else {
                        List(displayedResults) { result in
                            HStack(spacing: 12) {
                                Toggle("Clean", isOn: selectionBinding(for: result.id))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                    .disabled(viewModel.isBusy || !result.needsCleaning)

                                VStack(alignment: .leading, spacing: 3) {
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

                                VStack(alignment: .trailing, spacing: 3) {
                                    if let message = result.actionMessage {
                                        Text(message)
                                            .font(.caption2)
                                            .foregroundStyle(message == "Cleaned" ? Color.green : Color.orange)
                                    }
                                    if result.needsCleaning {
                                        Text(result.issues.joined(separator: " • "))
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                            .lineLimit(2)
                                            .help(result.issues.joined(separator: "\n"))
                                    }
                                }
                                .frame(maxWidth: 420, alignment: .trailing)
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
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .onChange(of: sharedInputURL?.wrappedValue?.path) { _, _ in
            applySharedInput()
        }
        .onChange(of: viewModel.isBusy) { _, isBusy in
            if !isBusy { applySharedInput() }
        }
        .onAppear(perform: applySharedInput)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            if isActive {
                ToolbarItem(placement: .navigation) {
                    Button {
                        viewModel.exportCSV()
                    } label: {
                        Label("Export CSV…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!viewModel.canExport)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    if viewModel.isBusy {
                        Button {
                            viewModel.cancel()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        if !cleanableIDs.isEmpty {
                            Button {
                                viewModel.clean(resultIDs: selectedResultIDs)
                            } label: {
                                Label(
                                    selectedResultIDs.isEmpty
                                        ? "Clean Selected" : "Clean Selected (\(selectedResultIDs.count))",
                                    systemImage: "eraser"
                                )
                            }
                            .disabled(selectedResultIDs.isEmpty)
                        }

                        Button {
                            selectedResultIDs = []
                            viewModel.scan()
                        } label: {
                            Label("Scan", systemImage: "magnifyingglass")
                        }
                        .disabled(!viewModel.canScan)
                    }
                }
            }
        }
        .onChange(of: cleanableIDs) { _, newIDs in
            selectedResultIDs.formIntersection(newIDs)
        }
    }

    private var cleanableIDs: Set<UUID> {
        Set(viewModel.cleanableResults.map(\.id))
    }

    private var allCleanableSelected: Bool {
        !cleanableIDs.isEmpty && cleanableIDs.isSubset(of: selectedResultIDs)
    }

    private var displayedResults: [MetadataCleanerResult] {
        showNeedsCleaningOnly ? viewModel.cleanableResults : viewModel.results
    }

    private var metadataResultsSummary: String {
        if showNeedsCleaningOnly {
            return "\(displayedResults.count) need cleanup of \(viewModel.results.count)"
        }
        return "\(viewModel.results.count) file\(viewModel.results.count == 1 ? "" : "s")"
    }

    private var emptyResultsMessage: String {
        if viewModel.statusMessage.contains("No junk metadata") { return "No junk metadata found." }
        return "Scan an MP4 file or folder to find metadata that can be cleaned."
    }

    private var metadataActivityTitle: String {
        if viewModel.isCleaning { return "Cleaning MP4 metadata…" }
        if viewModel.isResolvingInput { return "Preparing metadata scan…" }
        return "Scanning MP4 metadata…"
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

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let collector = MetadataCleanerDroppedURLCollector()
        let group = DispatchGroup()
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url { collector.append(url) }
                    group.leave()
                }
            }
        }
        guard accepted else { return false }
        group.notify(queue: .main) {
            if let url = collector.first() {
                if let sharedInputURL {
                    sharedInputURL.wrappedValue = url
                } else {
                    viewModel.acceptInput(url: url)
                }
            }
        }
        return true
    }

    private func applySharedInput() {
        guard let url = sharedInputURL?.wrappedValue,
              url.path != lastAppliedSharedInputPath,
              !viewModel.isBusy else { return }
        lastAppliedSharedInputPath = url.path
        viewModel.acceptInput(url: url)
    }
}
