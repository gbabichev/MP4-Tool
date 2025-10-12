//
//  ContentView.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var processor = VideoProcessor()
    @State private var inputFolderPath: String = ""
    @State private var outputFolderPath: String = ""
    @State private var selectedMode: ProcessingMode = .remux
    @State private var createSubfolders: Bool = false
    @State private var deleteOriginal: Bool = true
    @State private var showingInputPicker = false
    @State private var showingOutputPicker = false
    @State private var showingLogExporter = false
    @State private var logExportDocument: LogDocument?

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
            HStack(alignment: .top, spacing: 20) {
                // Left Column - Folder Selection
                VStack(spacing: 16) {
                    // Input Folder
                    HStack {
                        Text("Input Folder:")
                            .frame(width: 100, alignment: .leading)
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
                            .frame(width: 100, alignment: .leading)
                        TextField("Select output folder...", text: $outputFolderPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(processor.isProcessing)
                        Button("Browse") {
                            selectFolder(isInput: false)
                        }
                        .disabled(processor.isProcessing)
                    }
                }

                // Right Column - Settings
                VStack(spacing: 16) {
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
            if processor.isProcessing || !processor.logText.isEmpty {
                VStack(spacing: 12) {
                    Divider()

                    // Scan progress
                    if !processor.scanProgress.isEmpty {
                        Text(processor.scanProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }

                    // Current file info
                    if processor.isProcessing && processor.totalFiles > 0 {
                        VStack(spacing: 8) {
                            HStack {
                                Text("File \(processor.currentFileIndex)/\(processor.totalFiles)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !processor.currentFile.isEmpty {
                                    Text("•")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(processor.currentFile)
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

                        LogView(logText: processor.logText)
                            .frame(maxHeight: .infinity)
                    }
                    .padding(.horizontal)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 700)
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: .scanForNonMP4)) { _ in
            scanForNonMP4Files()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportLog)) { _ in
            exportLogToFile()
        }
        .fileExporter(
            isPresented: $showingLogExporter,
            document: logExportDocument,
            contentType: .plainText,
            defaultFilename: "MP4_Tool_Log_\(Int(Date().timeIntervalSince1970))"
        ) { result in
            switch result {
            case .success(let url):
                processor.addLog("📝 Log exported to: \(url.path)")
            case .failure(let error):
                processor.addLog("❌ Failed to export log: \(error.localizedDescription)")
            }
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

    private func exportLogToFile() {
        guard !processor.logText.isEmpty else {
            processor.addLog("⚠️ Cannot export: Log is empty")
            return
        }

        logExportDocument = LogDocument(text: processor.logText)
        showingLogExporter = true
    }
}

// Document type for log export
struct LogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let string = String(data: data, encoding: .utf8) {
            text = string
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}

// High-performance log view using NSTextView
struct LogView: NSViewRepresentable {
    let logText: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = NSTextView()

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width, .height]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Only update if text changed
        if textView.string != logText {
            let wasAtBottom = isScrolledToBottom(scrollView)

            textView.string = logText

            // Auto-scroll to bottom if we were already at the bottom
            if wasAtBottom {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    private func isScrolledToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return false }
        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.bounds.height
        return visibleRect.maxY >= documentHeight - 10 // 10px threshold
    }
}
