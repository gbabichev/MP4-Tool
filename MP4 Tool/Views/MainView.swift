//
//  MainContentView.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI

struct MainContentView: View {
    @ObservedObject var viewModel: ContentViewModel
    @Binding var isLogExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Input/Output folder display
            VStack(spacing: 0) {
                if !viewModel.inputFolderPath.isEmpty || !viewModel.outputFolderPath.isEmpty {
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
                                    Image(systemName: "arrow.left")
                                        .font(.caption2)
                                    Text("Select input")
                                }
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .frame(minHeight: 35)
                    .padding(.horizontal)
                    .padding(.top, 8)

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
                                    Image(systemName: "arrow.left")
                                        .font(.caption2)
                                    Text("Select output")
                                }
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .frame(minHeight: 35)
                    .padding(.horizontal)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.badge.questionmark")
                            .foregroundStyle(.secondary)
                        Text("Click buttons in toolbar to select folders")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 35)
                    .padding(.horizontal)
                    .padding(.top, 8)
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

            // File list - Fixed height, scrollable
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
                        .frame(height: 400)
                }
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
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
