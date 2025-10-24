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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Input/Output folder display
            VStack(spacing: 0) {
                // Input Folder
                HStack(alignment: .top) {
                    if !viewModel.inputFolderPath.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input Folder")
                                .bold()
                            Text(viewModel.inputFolderPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Input Folder")
                                .bold()
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.caption2)
                                Text("Select input or drop folder here")
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
                .padding(.top, 8)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers, isInput: true)
                }

                Divider()
                    .padding(.vertical, 8)

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
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers: providers, isInput: false)
                }
            }

            Divider()
                .padding(.top, 12)

            // Status Section - Always visible
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Status")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)

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
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !viewModel.processor.currentFile.isEmpty {
                                    Text("•")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(viewModel.processor.currentFile)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }

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
                            if !viewModel.processor.encodingProgress.isEmpty {
                                Text(viewModel.processor.encodingProgress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    // Empty state when no activity
                    if viewModel.processor.scanProgress.isEmpty && !viewModel.processor.isProcessing {
                        Text("Ready")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(height: 24)
                    }

                    // Total processing time
                    if viewModel.processor.videoFiles.contains(where: { $0.status == .completed }) {
                        let totalSeconds = viewModel.processor.videoFiles
                            .filter { $0.status == .completed }
                            .reduce(0) { $0 + $1.processingTimeSeconds }
                        let totalMinutes = totalSeconds / 60
                        let totalRemainingSeconds = totalSeconds % 60

                        Divider()
                            .padding(.vertical, 4)

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
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
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
                .padding(.top, 8)

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
                    List {
                        ForEach(Array(viewModel.processor.videoFiles.enumerated()), id: \.element.id) { index, file in
                            FileListRow(
                                file: file,
                                index: index,
                                isProcessing: viewModel.processor.isProcessing,
                                onRemove: {
                                    viewModel.removeFile(at: index)
                                }
                            )
                        }
                    }
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleFileDrop(providers: providers)
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
                    if isInput {
                        viewModel.setInputFolder(path: url.path)
                    } else {
                        viewModel.setOutputFolder(path: url.path)
                    }
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

            Text(file.fileName)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(file.status == .completed ? .green : .primary)

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
