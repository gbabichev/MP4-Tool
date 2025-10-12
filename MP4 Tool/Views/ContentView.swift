//
//  ContentView.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @AppStorage("selectedMode") private var selectedMode: ProcessingMode = .remux
    @AppStorage("crfValue") private var crfValue: Double = 23
    @AppStorage("createSubfolders") private var createSubfolders: Bool = false
    @AppStorage("deleteOriginal") private var deleteOriginal: Bool = true
    @AppStorage("hasSeenTutorial") private var hasSeenTutorial = false
    @State private var isLogExpanded = true

    var body: some View {
        TabView {
            // Main Tab - Input/Output/Log
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                // Input/Output folder display
                VStack(spacing: 16) {
                    if !viewModel.inputFolderPath.isEmpty || !viewModel.outputFolderPath.isEmpty {
                        HStack(alignment: .top, spacing: 20) {
                            if !viewModel.inputFolderPath.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Input Folder")
                                    Text(viewModel.inputFolderPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Input Folder")
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.left")
                                            .font(.caption2)
                                        Text("Select input")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                }
                            }

                            if !viewModel.outputFolderPath.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Output Folder")
                                    Text(viewModel.outputFolderPath)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Output Folder")
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.left")
                                            .font(.caption2)
                                        Text("Select output")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                }
                            }
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
                    }
                }
                .padding(.top, 8)

                // Progress Section
                VStack(spacing: 12) {
                    Divider()
                        .padding(.top, 12)

                    // Scan progress
                    if !viewModel.processor.scanProgress.isEmpty {
                        Text(viewModel.processor.scanProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }

                    // File list
                    if !viewModel.processor.videoFiles.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Files to Process (\(viewModel.processor.videoFiles.count))")
                                    .font(.headline)
                                Spacer()
                            }
                            .padding(.horizontal)

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
                        }

                    // Collapsible Logs
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

                        if isLogExpanded {
                            LogView(logText: viewModel.processor.logText)
                                .frame(height: 200)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal)
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding()
            }
            .tabItem {
                Label("Main", systemImage: "play.rectangle")
            }

            // Settings Tab
            SettingsView(
                selectedMode: $selectedMode,
                crfValue: $crfValue,
                createSubfolders: $createSubfolders,
                deleteOriginal: $deleteOriginal,
                isProcessing: viewModel.processor.isProcessing
            )
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .frame(minWidth: 800, minHeight: 700)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: {
                    viewModel.selectFolder(isInput: true)
                }) {
                    Label("Input Folder", systemImage: "folder")
                }
                .disabled(viewModel.processor.isProcessing)
                .help(viewModel.inputFolderPath.isEmpty ? "Select input folder" : viewModel.inputFolderPath)
                //.foregroundStyle(.orange)
            }

            ToolbarItem(placement: .navigation) {
                Button(action: {
                    viewModel.selectFolder(isInput: false)
                }) {
                    Label("Output Folder", systemImage: "folder.badge.gearshape")
                }
                .disabled(viewModel.processor.isProcessing)
                .help(viewModel.outputFolderPath.isEmpty ? "Select output folder" : viewModel.outputFolderPath)
            }

            ToolbarItem(placement: .status){
                Spacer()
            }

            ToolbarItem(placement: .primaryAction) {
                if viewModel.processor.isProcessing {
                    Button(action: {
                        viewModel.processor.cancelScan()
                    }) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button(action: {
                        viewModel.startProcessing(
                            mode: selectedMode,
                            crfValue: Int(crfValue),
                            createSubfolders: createSubfolders,
                            deleteOriginal: deleteOriginal
                        )
                    }) {
                        Label("Start Processing", systemImage: "play.fill")
                    }
                    .disabled(!viewModel.canStartProcessing)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openInputFolder)) { _ in
            viewModel.selectFolder(isInput: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectOutputFolder)) { _ in
            viewModel.selectFolder(isInput: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .startProcessing)) { _ in
            if viewModel.canStartProcessing && !viewModel.processor.isProcessing {
                viewModel.startProcessing(
                    mode: selectedMode,
                    crfValue: Int(crfValue),
                    createSubfolders: createSubfolders,
                    deleteOriginal: deleteOriginal
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .scanForNonMP4)) { _ in
            viewModel.scanForNonMP4Files()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportLog)) { _ in
            viewModel.exportLogToFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearFolders)) { _ in
            viewModel.clearFolders()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTutorial)) { _ in
            viewModel.showTutorial()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAbout)) { _ in
            viewModel.showAbout()
        }
        .overlay {
            if viewModel.showingTutorial {
                TutorialView(isPresented: $viewModel.showingTutorial)
            }
        }
        .overlay {
            if viewModel.showingAbout {
                AboutView(isPresented: $viewModel.showingAbout)
            }
        }
        .onAppear {
            if !hasSeenTutorial {
                viewModel.showingTutorial = true
            }
        }
        .fileExporter(
            isPresented: $viewModel.showingLogExporter,
            document: viewModel.logExportDocument,
            contentType: .plainText,
            defaultFilename: "MP4_Tool_Log_\(Int(Date().timeIntervalSince1970))"
        ) { result in
            switch result {
            case .success(let url):
                viewModel.processor.addLog("􀈊 Log exported to: \(url.path)")
            case .failure(let error):
                viewModel.processor.addLog("􀁡 Failed to export log: \(error.localizedDescription)")
            }
        }
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
