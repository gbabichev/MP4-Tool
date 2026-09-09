//
//  MainContentView.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct MainContentView: View {
    @ObservedObject var viewModel: ContentViewModel
    @Binding var isCollapsed: Bool
    @State private var draggedPendingFileID: UUID?

    private var selectedFileIDs: Set<UUID> {
        viewModel.selectedFileIDs
    }

    private var selectedFileIDsBinding: Binding<Set<UUID>> {
        Binding(
            get: { viewModel.selectedFileIDs },
            set: { newSelection in
                guard newSelection != viewModel.selectedFileIDs else { return }

                // List can normalize its selection while SwiftUI is updating the
                // view hierarchy. Publish the persisted selection on the next run
                // loop so that normalization does not mutate observable state mid-update.
                DispatchQueue.main.async {
                    guard newSelection != viewModel.selectedFileIDs else { return }
                    viewModel.selectedFileIDs = newSelection
                }
            }
        )
    }

    var body: some View {
        if isCollapsed {
            queueSection
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding()
        } else {
            queueSection
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    "Queue (\(viewModel.processor.videoFiles.count))",
                    systemImage: "list.bullet"
                )
                .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    chooseFilesToAdd()
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .controlSize(.small)
                .help(
                    viewModel.processor.isProcessing
                        ? "Add files to the active batch"
                        : "Add files to the queue"
                )

                Button {
                    viewModel.clearFilesToProcess()
                    viewModel.selectedFileIDs.removeAll()
                } label: {
                    Label("Clear Queue", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(viewModel.processor.isProcessing || viewModel.processor.videoFiles.isEmpty)
                .help("Clear queue")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isCollapsed ? "Show queue" : "Hide queue")
                .help(isCollapsed ? "Show queue" : "Hide queue")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, isCollapsed ? 12 : 0)

            if !isCollapsed && viewModel.processor.videoFiles.isEmpty {
                // Empty state with drop zone
                VStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Drop video files here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleFileDrop(providers: providers)
                }
            } else if !isCollapsed {
                List(selection: selectedFileIDsBinding) {
                    ForEach(viewModel.processor.videoFiles) { file in
                        queueRow(for: file)
                            .tag(file.id)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .modifier(
                                PendingQueueReorderModifier(
                                    file: file,
                                    processor: viewModel.processor,
                                    draggedFileID: $draggedPendingFileID
                                )
                            )
                            .contextMenu {
                                contextMenuItems(for: file)
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.04))
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleFileDrop(providers: providers)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.allowedContentTypes = ["mkv", "mp4", "avi", "mov", "m4v"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.message = viewModel.processor.isProcessing
            ? "Choose videos to add to the active batch"
            : "Choose videos to process"
        panel.prompt = "Add"

        CleanFilePanelPresenter.present(panel) { response in
            guard response == .OK else { return }
            addURLsToQueue(panel.urls)
        }
    }

    private func addURLsToQueue(_ urls: [URL]) {
        let videoFormats = Set(["mkv", "mp4", "avi", "mov", "m4v"])

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    continue
                }

                for case let fileURL as URL in enumerator
                where videoFormats.contains(fileURL.pathExtension.lowercased()) {
                    viewModel.addVideoFile(url: fileURL)
                }
            } else if videoFormats.contains(url.pathExtension.lowercased()) {
                viewModel.addVideoFile(url: url)
            }
        }
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        let videoFormats = ["mkv", "mp4", "avi", "mov", "m4v"]

        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url = url, error == nil else { return }

                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

                if exists && isDirectory.boolValue {
                    // It's a folder - recursively enumerate all video files in it
                    DispatchQueue.main.async {
                        if let enumerator = FileManager.default.enumerator(
                            at: url,
                            includingPropertiesForKeys: [.isRegularFileKey],
                            options: [.skipsHiddenFiles, .skipsPackageDescendants]
                        ) {
                            for case let fileURL as URL in enumerator {
                                let ext = fileURL.pathExtension.lowercased()
                                if videoFormats.contains(ext) {
                                    viewModel.addVideoFile(url: fileURL)
                                }
                            }
                        }
                    }
                } else {
                    // It's a file - check if it's a video
                    let ext = url.pathExtension.lowercased()
                    if videoFormats.contains(ext) {
                        DispatchQueue.main.async {
                            viewModel.addVideoFile(url: url)
                        }
                    }
                }
            }
        }

        return true
    }

    private func statusIcon(for file: VideoFileInfo) -> some View {
        Group {
            if file.status == .pending && file.hasConflict {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help(file.conflictReason)
            } else {
                switch file.status {
                case .pending:
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                case .processing:
                    ProgressView()
                        .scaleEffect(0.8)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .skipped:
                    Image(systemName: "forward.end.circle.fill")
                        .foregroundStyle(.orange)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func queueRow(for file: VideoFileInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                statusIcon(for: file)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(file.fileName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 5) {
                        Text(file.fileExtension)
                        Text("•")
                        Text("\(file.fileSizeMB) MB")
                            .monospacedDigit()

                        if file.status == .completed && file.newSizeMB > 0 {
                            Text("→")
                            Text("\(file.newSizeMB) MB")
                                .monospacedDigit()
                        }

                        if file.status == .completed && file.processingTimeSeconds > 0 {
                            Text("•")
                            Text(formattedProcessingDuration(file.processingTimeSeconds))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if file.status == .pending {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Drag to reorder pending files")
                        .accessibilityLabel("Drag to reorder")
                }

                Text(queueStatusTitle(for: file))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(queueStatusColor(for: file))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(queueStatusColor(for: file).opacity(0.12))
                    )

                Button(role: .destructive) {
                    removeSingleFile(fileID: file.id)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(file.status == .processing)
                .help(
                    file.status == .processing
                        ? "The active file cannot be removed"
                        : "Remove from queue"
                )
                .accessibilityLabel("Remove \(file.fileName) from queue")
            }

            if file.status == .pending && file.hasConflict && !file.conflictReason.isEmpty {
                Label(file.conflictReason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 36)
            } else if file.status == .skipped {
                Label("No retained English audio tracks", systemImage: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 36)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(queueRowBackground(for: file))
        )
    }

    private func queueStatusTitle(for file: VideoFileInfo) -> String {
        if file.status == .pending && file.hasConflict { return "Needs Attention" }
        switch file.status {
        case .pending: return "Queued"
        case .processing:
            let percent = Int((viewModel.processor.currentFileProgressFraction * 100).rounded())
            return "Processing \(percent)%"
        case .completed: return "Completed"
        case .skipped: return "Skipped"
        case .failed: return "Failed"
        }
    }

    private func queueStatusColor(for file: VideoFileInfo) -> Color {
        if file.status == .pending && file.hasConflict { return .orange }
        switch file.status {
        case .pending: return .secondary
        case .processing: return .accentColor
        case .completed: return .green
        case .skipped: return .orange
        case .failed: return .red
        }
    }

    private func queueRowBackground(for file: VideoFileInfo) -> Color {
        switch file.status {
        case .processing:
            return Color.accentColor.opacity(0.08)
        case .failed:
            return Color.red.opacity(0.06)
        case .skipped:
            return Color.orange.opacity(0.06)
        default:
            return Color.primary.opacity(0.035)
        }
    }

    private func formattedProcessingDuration(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    @ViewBuilder
    private func contextMenuItems(for file: VideoFileInfo) -> some View {
        Button(action: {
            openParentFolderInFinder(filePath: file.filePath)
        }) {
            Label("Open Parent Folder in Finder", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive, action: {
            removeFile(filePath: file.filePath)
        }) {
            if selectedFileIDs.contains(file.id) && selectedFileIDs.count > 1 {
                Label("Remove Selected (\(selectedFileIDs.count))", systemImage: "trash")
            } else {
                Label("Remove from List", systemImage: "trash")
            }
        }
        .disabled(file.status == .processing)
    }

    private func removeSelectedFiles() {
        let indicesToRemove = viewModel.processor.videoFiles
            .enumerated()
            .filter { selectedFileIDs.contains($0.element.id) }
            .map { $0.offset }
            .sorted(by: >)

        for index in indicesToRemove {
            viewModel.removeFile(at: index)
        }

        viewModel.selectedFileIDs.removeAll()
    }

    private func removeFile(filePath: String) {
        if let index = viewModel.processor.videoFiles.firstIndex(where: { $0.filePath == filePath }) {
            let fileID = viewModel.processor.videoFiles[index].id

            // If the file is part of a multi-selection, remove all selected files
            if selectedFileIDs.contains(fileID) && selectedFileIDs.count > 1 {
                removeSelectedFiles()
            } else {
                // Otherwise, just remove this one file
                viewModel.removeFile(at: index)
                viewModel.selectedFileIDs.remove(fileID)
            }
        }
    }

    private func removeSingleFile(fileID: UUID) {
        guard let index = viewModel.processor.videoFiles.firstIndex(where: { $0.id == fileID }),
              viewModel.processor.videoFiles[index].status != .processing else {
            return
        }
        viewModel.removeFile(at: index)
        viewModel.selectedFileIDs.remove(fileID)
    }

    private func openParentFolderInFinder(filePath: String) {
        let fileURL = URL(fileURLWithPath: filePath)
        let parentURL = fileURL.deletingLastPathComponent()
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: parentURL.path)
    }
}

private struct PendingQueueReorderModifier: ViewModifier {
    let file: VideoFileInfo
    let processor: VideoProcessor
    @Binding var draggedFileID: UUID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if file.status == .pending {
            content
                .onDrag {
                    draggedFileID = file.id
                    return NSItemProvider(object: file.id.uuidString as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: PendingQueueDropDelegate(
                        targetFileID: file.id,
                        processor: processor,
                        draggedFileID: $draggedFileID
                    )
                )
        } else {
            content
        }
    }
}

private struct PendingQueueDropDelegate: DropDelegate {
    let targetFileID: UUID
    let processor: VideoProcessor
    @Binding var draggedFileID: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggedFileID, draggedFileID != targetFileID else { return false }
        return processor.videoFiles.contains { $0.id == draggedFileID && $0.status == .pending }
            && processor.videoFiles.contains { $0.id == targetFileID && $0.status == .pending }
    }

    func dropEntered(info: DropInfo) {
        guard let draggedFileID, draggedFileID != targetFileID else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            processor.movePendingFile(draggedFileID, relativeTo: targetFileID)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedFileID = nil
        return true
    }
}

struct ProcessingProgressCard: View {
    @ObservedObject var processor: VideoProcessor
    @Binding var isCollapsed: Bool

    private var isScanning: Bool {
        processor.currentFile.isEmpty && !processor.scanProgress.isEmpty
    }

    private var title: String {
        if isScanning { return "Preparing Batch" }
        switch processor.activeMode {
        case .smart:
            switch processor.activeItemMode {
            case .remux: return "Smart Remuxing in Progress"
            case .encodeH264, .encodeH265: return "Smart Encoding in Progress"
            case .smart, nil: return "Smart Processing in Progress"
            }
        case .remux:
            return "Remuxing in Progress"
        case .encodeH264, .encodeH265:
            return "Encoding in Progress"
        case nil:
            return "Processing in Progress"
        }
    }

    private var completedCount: Int {
        processor.videoFiles.filter { $0.status == .completed }.count
    }

    private var failedCount: Int {
        processor.videoFiles.filter { $0.status == .failed }.count
    }

    private var skippedCount: Int {
        processor.videoFiles.filter { $0.status == .skipped }.count
    }

    private var overallProgress: Double {
        guard processor.totalFiles > 0 else { return 0 }
        let finishedUnits = Double(completedCount + skippedCount + failedCount)
        let currentUnits = processor.videoFiles.contains { $0.status == .processing }
            ? processor.currentFileProgressFraction : 0
        return min(max((finishedUnits + currentUnits) / Double(processor.totalFiles), 0), 1)
    }

    private var currentPercent: Int {
        Int((min(max(processor.currentFileProgressFraction, 0), 1) * 100).rounded())
    }

    private var overallPercent: Int {
        Int((overallProgress * 100).rounded())
    }

    private var showsFramePreview: Bool {
        processor.framePreviewsEnabled
            && (processor.activeItemMode == .encodeH264 || processor.activeItemMode == .encodeH265)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let eta = processor.processingETASnapshot()
            let batchElapsed = processor.processingStartedAt.map {
                max(context.date.timeIntervalSince($0), 0)
            } ?? 0

            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "gearshape.2.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)

                        Text(
                            isScanning
                                ? processor.scanProgress
                                : "File \(processor.currentFileIndex) of \(processor.totalFiles)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Spacer()

                    Text("\(overallPercent)%")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isCollapsed.toggle()
                        }
                    } label: {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isCollapsed ? "Show progress details" : "Hide progress details")
                    .help(isCollapsed ? "Show progress details" : "Hide progress details")
                }

                if !isCollapsed {
                    if isScanning {
                        ProgressView()
                            .progressViewStyle(.linear)
                    } else {
                        VStack(spacing: 5) {
                            HStack(spacing: 10) {
                                Text("Overall progress")
                                Spacer(minLength: 12)
                                Text("\(completedCount) completed")
                                if failedCount > 0 {
                                    Text("• \(failedCount) failed")
                                        .foregroundStyle(.red)
                                }

                                Divider()
                                    .frame(height: 30)

                                ProcessingMetric(
                                    icon: "film.stack",
                                    title: "Batch",
                                    value: "\(completedCount + failedCount) / \(processor.totalFiles)"
                                )
                                Divider()
                                    .frame(height: 30)
                                ProcessingMetric(
                                    icon: "clock",
                                    title: "Elapsed",
                                    value: formattedDuration(batchElapsed)
                                )
                                Divider()
                                    .frame(height: 30)
                                ProcessingMetric(
                                    icon: "hourglass",
                                    title: "Remaining",
                                    value: eta.totalSeconds.map { formattedDuration(TimeInterval($0)) }
                                        ?? "Calculating…"
                                )
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)

                            ProgressView(value: overallProgress, total: 1)
                                .progressViewStyle(.linear)
                        }

                        HStack(alignment: .center, spacing: 12) {
                            if showsFramePreview {
                                framePreview
                            }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Current File")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(processor.currentFile.isEmpty ? "Getting ready…" : processor.currentFile)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                Text("\(currentPercent)%")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                            }

                            ProgressView(value: processor.currentFileProgressFraction, total: 1)
                                .progressViewStyle(.linear)

                            HStack(spacing: 8) {
                                Label(
                                    eta.currentFileSeconds.map {
                                        "ETA \(formattedDuration(TimeInterval($0)))"
                                    } ?? "Estimating current file…",
                                    systemImage: "clock.arrow.circlepath"
                                )

                                Spacer()

                                if processor.originalSize > 0 {
                                    Text(formattedBytes(processor.originalSize))
                                    Image(systemName: "arrow.right")
                                    Text(
                                        processor.newSize > 0
                                            ? formattedBytes(processor.newSize) : "Preparing…"
                                    )
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.secondary.opacity(0.06))
                        )
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                        Text("Add more files below at any time; they’ll join this batch.")
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if processor.processingHadError {
                        Label("One or more files encountered an error. Processing will continue.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 7)
        }
    }

    @ViewBuilder
    private var framePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.78))

            if let preview = processor.currentFramePreview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preview")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 128, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .accessibilityLabel("Current video frame preview")
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(Int(interval.rounded()), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

private struct ProcessingMetric: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
