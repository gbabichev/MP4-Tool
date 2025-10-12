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
    @Binding var isLogExpanded: Bool
    @State private var fileListHeight: CGFloat = 400

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

            // Scan progress
            if !viewModel.processor.scanProgress.isEmpty {
                Text(viewModel.processor.scanProgress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            // File list - Resizable height
            if !viewModel.processor.videoFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Files to Process (\(viewModel.processor.videoFiles.count))")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    List {
                            ForEach(Array(viewModel.processor.videoFiles.enumerated()), id: \.element.id) { index, file in
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
                                }
                                .listRowBackground(index % 2 == 0 ? Color.clear : Color.secondary.opacity(0.08))
                            }

                            // Total processing time
                            if viewModel.processor.videoFiles.contains(where: { $0.status == .completed }) {
                                let totalSeconds = viewModel.processor.videoFiles
                                    .filter { $0.status == .completed }
                                    .reduce(0) { $0 + $1.processingTimeSeconds }
                                let totalMinutes = totalSeconds / 60
                                let totalRemainingSeconds = totalSeconds % 60

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
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                        .frame(height: fileListHeight)
                }

                // Resizable divider
                ResizableDivider(height: $fileListHeight, minHeight: 150, maxHeight: 600)
            }

            // Current file info
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
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // Log Section - Expands to fill remaining space
            VStack(alignment: .leading, spacing: 4) {
                Button(action: {
                    withAnimation {
                        isLogExpanded.toggle()
                    }
                }) {
                    HStack {
                        Text("Log Output")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: isLogExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .padding(.horizontal)
                .padding(.top, 12)

                if isLogExpanded {
                    LogView(logText: viewModel.processor.logText)
                        .frame(maxHeight: .infinity)
                        .transition(.opacity)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
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
}

// Resizable divider component
struct ResizableDivider: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.3))
            .frame(height: 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        let newHeight = height + value.translation.height
                        height = min(max(newHeight, minHeight), maxHeight)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}
