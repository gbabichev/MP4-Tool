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
    @StateObject private var viewModel = MetadataCleanerViewModel()
    @State private var selectedResultIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusContent

            Text("Find release-group and attribution metadata, then remove only those fields with a validated in-place remux. Ordinary movie metadata, track descriptions, languages, subtitle roles, chapters, and media streams are preserved.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
                    openAction: viewModel.revealInput,
                    chooseAction: viewModel.selectInput
                )
                .padding(.vertical, 4)
            }

            GroupBox("Files with Junk Metadata") {
                if viewModel.results.isEmpty {
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
                        Button(allCleanableSelected ? "Deselect All" : "Select All") {
                            if allCleanableSelected {
                                selectedResultIDs.subtract(cleanableIDs)
                            } else {
                                selectedResultIDs.formUnion(cleanableIDs)
                            }
                        }
                        .controlSize(.small)
                        .disabled(viewModel.isBusy || cleanableIDs.isEmpty)

                        List(viewModel.results) { result in
                            HStack(spacing: 12) {
                                Toggle("Clean", isOn: selectionBinding(for: result.id))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                    .disabled(viewModel.isBusy || !result.needsCleaning)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.fileName)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 820, minHeight: 560)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
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

    private var emptyResultsMessage: String {
        if viewModel.isScanning { return "Scanning MP4 metadata…" }
        if viewModel.statusMessage.contains("No junk metadata") { return "No junk metadata found." }
        return "Scan an MP4 file or folder to find metadata that can be cleaned."
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

    @ViewBuilder
    private var statusContent: some View {
        HStack(spacing: 8) {
            Image(systemName: viewModel.hasTools ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(viewModel.hasTools ? Color.green : Color.orange)
            Text(viewModel.hasTools ? "FFmpeg ready" : "FFmpeg and FFprobe are required")
                .font(.caption)
                .foregroundStyle(.secondary)
            if viewModel.isBusy { ProgressView().controlSize(.small) }
            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
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
            if let url = collector.first() { viewModel.acceptInput(url: url) }
        }
        return true
    }
}
