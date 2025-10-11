//
//  ContentView.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var processor = VideoProcessor()
    @State private var inputFolderPath: String = ""
    @State private var outputFolderPath: String = ""
    @State private var selectedMode: ProcessingMode = .remux
    @State private var createSubfolders: Bool = false
    @State private var deleteOriginal: Bool = true
    @State private var showingInputPicker = false
    @State private var showingOutputPicker = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .imageScale(.large)
                    .font(.system(size: 50))
                    .foregroundStyle(.blue)
                Text("MP4 Tool")
                    .font(.largeTitle)
                    .bold()
                Text("Video Converter & Remuxer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top)

            Divider()

            // Configuration Section
            VStack(spacing: 16) {
                // Input Folder
                HStack {
                    Text("Input Folder:")
                        .frame(width: 120, alignment: .leading)
                    TextField("Select input folder...", text: $inputFolderPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(processor.isProcessing)
                    Button("Browse") {
                        selectFolder(isInput: true)
                    }
                    .disabled(processor.isProcessing)
                }

                // Output Folder
                HStack {
                    Text("Output Folder:")
                        .frame(width: 120, alignment: .leading)
                    TextField("Select output folder...", text: $outputFolderPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(processor.isProcessing)
                    Button("Browse") {
                        selectFolder(isInput: false)
                    }
                    .disabled(processor.isProcessing)
                }

                // Mode Selection
                HStack {
                    Text("Mode:")
                        .frame(width: 120, alignment: .leading)
                    Picker("", selection: $selectedMode) {
                        ForEach(ProcessingMode.allCases, id: \.self) { mode in
                            Text(mode.description).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(processor.isProcessing)
                }

                // Subfolder option
                HStack {
                    Text("Create Subfolders:")
                        .frame(width: 120, alignment: .leading)
                    Toggle("", isOn: $createSubfolders)
                        .disabled(processor.isProcessing)
                    Spacer()
                }

                // Delete original option
                HStack {
                    Text("Delete Original:")
                        .frame(width: 120, alignment: .leading)
                    Toggle("", isOn: $deleteOriginal)
                        .disabled(processor.isProcessing)
                    Spacer()
                }
            }
            .padding(.horizontal)

            // Start/Stop Button
            HStack(spacing: 12) {
                Button(action: startProcessing) {
                    HStack {
                        if processor.isProcessing {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text(processor.isProcessing ? "Processing..." : "Start Processing")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canStartProcessing ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(!canStartProcessing || processor.isProcessing)

                if processor.isProcessing {
                    Button(action: {
                        processor.cancelScan()
                    }) {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("Stop")
                                .bold()
                        }
                        .frame(width: 100)
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }
            }
            .padding(.horizontal)

            // Progress Section
            if processor.isProcessing || !processor.logs.isEmpty {
                VStack(spacing: 12) {
                    Divider()

                    // Scan progress
                    if !processor.scanProgress.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(processor.scanProgress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                        .padding(.horizontal)
                    }

                    // Progress Bar
                    if processor.totalFiles > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("File \(processor.currentFileIndex)/\(processor.totalFiles)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(processor.progress * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: processor.progress)
                                .progressViewStyle(.linear)
                        }
                        .padding(.horizontal)
                    }

                    // Current file info
                    if processor.isProcessing {
                        VStack(spacing: 8) {
                            if !processor.currentFile.isEmpty {
                                HStack {
                                    Text("Current:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(processor.currentFile)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                            }

                            HStack(spacing: 20) {
                                HStack {
                                    Image(systemName: "clock")
                                        .foregroundStyle(.secondary)
                                    Text("\(Int(processor.elapsedTime))s")
                                        .font(.caption)
                                }

                                HStack {
                                    Image(systemName: "doc")
                                        .foregroundStyle(.secondary)
                                    Text("\(processor.originalSize / (1024*1024))MB")
                                        .font(.caption)
                                }

                                if processor.newSize > 0 {
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.secondary)
                                    HStack {
                                        Image(systemName: "doc.fill")
                                            .foregroundStyle(.secondary)
                                        Text("\(processor.newSize / (1024*1024))MB")
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Logs
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Log Output:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(processor.logs.enumerated()), id: \.offset) { index, log in
                                        Text(log)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .id(index)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 200)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(8)
                            .onChange(of: processor.logs.count) { _ in
                                if let lastIndex = processor.logs.indices.last {
                                    withAnimation {
                                        proxy.scrollTo(lastIndex, anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }

            Spacer()
        }
        .frame(minWidth: 600, minHeight: 700)
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: .scanForNonMP4)) { _ in
            scanForNonMP4Files()
        }
    }

    private var canStartProcessing: Bool {
        !inputFolderPath.isEmpty && !outputFolderPath.isEmpty
    }

    private func selectFolder(isInput: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK {
            if let url = panel.url {
                if isInput {
                    inputFolderPath = url.path
                } else {
                    outputFolderPath = url.path
                }
            }
        }
    }

    private func startProcessing() {
        Task {
            await processor.processFolder(
                inputPath: inputFolderPath,
                outputPath: outputFolderPath,
                mode: selectedMode,
                createSubfolders: createSubfolders,
                deleteOriginal: deleteOriginal
            )
        }
    }

    private func scanForNonMP4Files() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select directory to scan for non-MP4 files"

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await processor.scanForNonMP4Files(directoryPath: url.path)
            }
        }
    }
}
