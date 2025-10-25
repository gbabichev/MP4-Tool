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
    @State private var selectedFileIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Output Folder
            HStack(alignment: .top) {
                if !viewModel.outputFolderPath.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Output Folder")
                            .bold()
                        Text(viewModel.outputFolderPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Output Folder")
                            .bold()
                        HStack(spacing: 4) {
                            Image(systemName: "folder.badge.gearshape")
                                .font(.caption2)
                            Text("Select output or drop folder here")
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .frame(minHeight: 35)
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.top, 12)
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers, isInput: false)
            }

            // Status Section - Always visible
            HStack {
                Text("Status")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 12)

            VStack(spacing: 8) {
                // Scan progress
                if !viewModel.processor.scanProgress.isEmpty {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(viewModel.processor.scanProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                // Processing progress
                if viewModel.processor.isProcessing && viewModel.processor.totalFiles > 0 {
                    VStack(spacing: 8) {
                        HStack {
                            Text("File \(viewModel.processor.currentFileIndex)/\(viewModel.processor.totalFiles)")
                                .font(.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            if !viewModel.processor.currentFile.isEmpty {
                                Text("•")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(viewModel.processor.currentFile)
                                    .font(.body)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .padding(.top, 4)

                        HStack(spacing: 20) {
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                                Text(viewModel.formattedTime(viewModel.processor.elapsedTime))
                                    .font(.caption)
                            }

                            HStack {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                Text("\(viewModel.processor.originalSize / (1024*1024))MB")
                                    .font(.caption)
                            }

                            if viewModel.processor.newSize > 0 {
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Image(systemName: "doc.fill")
                                        .foregroundStyle(.secondary)
                                    Text("\(viewModel.processor.newSize / (1024*1024))MB")
                                        .font(.caption)
                                }
                            }
                        }

                        // Encoding progress message
                        Text(viewModel.processor.encodingProgress.isEmpty ? "Getting ready..." : viewModel.processor.encodingProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Empty state when no activity
                if viewModel.processor.scanProgress.isEmpty && !viewModel.processor.isProcessing {
                    HStack {
                        Spacer()
                        Text("Ready! Add files & select an output folder to begin")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                // Total processing time
                if viewModel.processor.videoFiles.contains(where: { $0.status == .completed }) {
                    let totalSeconds = viewModel.processor.videoFiles
                        .filter { $0.status == .completed }
                        .reduce(0) { $0 + $1.processingTimeSeconds }
                    let totalMinutes = totalSeconds / 60
                    let totalRemainingSeconds = totalSeconds % 60

                    Divider()
                        .padding(.vertical, 8)

                    HStack {
                        Text("Total Processing Time:")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(totalMinutes)m \(totalRemainingSeconds)s")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(viewModel.processor.processingHadError ? Color.red.opacity(0.15) : Color.secondary.opacity(0.05))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top, 8)

            // File list - Fills available space
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Files to Process (\(viewModel.processor.videoFiles.count))")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 12)

                if viewModel.processor.videoFiles.isEmpty {
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
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleFileDrop(providers: providers)
                    }
                } else {
                    VStack(spacing: 8) {
                        Table(viewModel.processor.videoFiles, selection: $selectedFileIDs) {
                            TableColumn("Status") { file in
                                statusIcon(for: file)
                                    .frame(width: 24)
                            }
                            .width(ideal: 30)

                            TableColumn("Name") { file in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.fileName)
                                        .font(.body)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(file.status == .completed ? .green : .primary)

                                    if file.hasConflict && !file.conflictReason.isEmpty {
                                        Text(file.conflictReason)
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                .contextMenu {
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
                                }
                            }

                            TableColumn("Type") { file in
                                Text("[\(file.fileExtension)]")
                                    .font(.body)
                                    .foregroundStyle(file.status == .completed ? .green : .secondary)
                            }
                            .width(ideal: 70)

                            TableColumn("Size") { file in
                                Text("\(file.fileSizeMB) MB")
                                    .font(.body)
                                    .foregroundStyle(file.status == .completed ? .green : .secondary)
                                    .monospacedDigit()
                            }
                            .width(ideal: 80)

                            TableColumn("Time") { file in
                                if file.status == .completed && file.processingTimeSeconds > 0 {
                                    let minutes = file.processingTimeSeconds / 60
                                    let seconds = file.processingTimeSeconds % 60
                                    Text("\(minutes)m \(seconds)s")
                                        .font(.body)
                                        .foregroundStyle(.green)
                                        .monospacedDigit()
                                } else {
                                    Text("")
                                }
                            }
                            .width(ideal: 70)
                        }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            handleFileDrop(providers: providers)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func handleDrop(providers: [NSItemProvider], isInput: Bool) -> Bool {
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, error in
            guard let url = url, error == nil else { return }

            // Check if it's a directory
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                DispatchQueue.main.async {
                    viewModel.setOutputFolder(path: url.path)
                }
            }
        }

        return true
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
            if file.hasConflict {
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
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
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

        selectedFileIDs.removeAll()
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
                selectedFileIDs.remove(fileID)
            }
        }
    }

    private func openParentFolderInFinder(filePath: String) {
        let fileURL = URL(fileURLWithPath: filePath)
        let parentURL = fileURL.deletingLastPathComponent()
        NSWorkspace.shared.selectFile(filePath, inFileViewerRootedAtPath: parentURL.path)
    }
}

// File list row with hover to show remove button
struct FileListRow: View {
    let file: VideoFileInfo
    let index: Int
    let isProcessing: Bool
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack {
            // Status indicator
            Group {
                switch file.status {
                case .pending:
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                case .processing:
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 24, height: 24)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(file.fileName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(file.status == .completed ? .green : .primary)

                    if file.hasConflict {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .font(.body)
                            .help(file.conflictReason)
                    }
                }

                if file.hasConflict && !file.conflictReason.isEmpty {
                    Text(file.conflictReason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if file.status == .completed && file.processingTimeSeconds > 0 {
                let minutes = file.processingTimeSeconds / 60
                let seconds = file.processingTimeSeconds % 60
                Text("\(minutes)m \(seconds)s")
                    .font(.body)
                    .foregroundStyle(.green)
                    .monospacedDigit()
            }

            Text("[\(file.fileExtension)]")
                .font(.body)
                .foregroundStyle(file.status == .completed ? .green : .secondary)
                .padding(.horizontal, 6)

            Text("\(file.fileSizeMB) MB")
                .font(.body)
                .foregroundStyle(file.status == .completed ? .green : .secondary)
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)

            // Remove button (visible on hover)
            if isHovering && !isProcessing {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            }
        }
        .listRowBackground(index % 2 == 0 ? Color.clear : Color.secondary.opacity(0.08))
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button(action: {
                openParentFolderInFinder()
            }) {
                Label("Open Parent Folder in Finder", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive, action: onRemove) {
                Label("Remove from List", systemImage: "trash")
            }
        }
    }

    private func openParentFolderInFinder() {
        let fileURL = URL(fileURLWithPath: file.filePath)
        let parentURL = fileURL.deletingLastPathComponent()
        NSWorkspace.shared.selectFile(file.filePath, inFileViewerRootedAtPath: parentURL.path)
    }
}
