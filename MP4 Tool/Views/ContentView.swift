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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Configuration Section
            VStack(spacing: 16) {
                // Input folder display
                if !viewModel.inputFolderPath.isEmpty {
                    SettingsRow("Input Folder", subtitle: viewModel.inputFolderPath) {
                        EmptyView()
                    }
                }

                SettingsRow("Output Folder", subtitle: "Where converted files will be saved") {
                    HStack {
                        TextField("Select output folder...", text: $viewModel.outputFolderPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.processor.isProcessing)
                        Button("Browse") {
                            viewModel.selectFolder(isInput: false)
                        }
                        .disabled(viewModel.processor.isProcessing)
                    }
                }

                SettingsRow("Mode", subtitle: "Encode converts to H.265, Remux copies streams") {
                    Picker("", selection: $selectedMode) {
                        ForEach(ProcessingMode.allCases, id: \.self) { mode in
                            Text(mode.description).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.processor.isProcessing)
                }

                if selectedMode == .encode {
                    SettingsRow("Quality (CRF)", subtitle: "Lower = better quality, larger file. Default 23.") {
                        HStack {
                            Slider(value: $crfValue, in: 18...28, step: 1)
                                .frame(width: 200)
                                .disabled(viewModel.processor.isProcessing)
                            Text("\(Int(crfValue))")
                                .frame(width: 30)
                                .monospacedDigit()
                        }
                    }
                }

                SettingsRow("Create Subfolders", subtitle: "Each file will be saved in its own subfolder") {
                    Toggle("", isOn: $createSubfolders)
                        .toggleStyle(.switch)
                        .disabled(viewModel.processor.isProcessing)
                }

                SettingsRow("Delete Original", subtitle: "Remove source files after successful conversion") {
                    Toggle("", isOn: $deleteOriginal)
                        .toggleStyle(.switch)
                        .disabled(viewModel.processor.isProcessing)
                }
            }
            .padding(.horizontal)
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

                // Logs
                VStack(alignment: .leading, spacing: 4) {
                    Text("Log Output:")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LogView(logText: viewModel.processor.logText)
                        .frame(maxHeight: .infinity)
                }
                .padding(.horizontal)
            }
        }
        .frame(minWidth: 800, minHeight: 700)
        .padding()
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
        .fileExporter(
            isPresented: $viewModel.showingLogExporter,
            document: viewModel.logExportDocument,
            contentType: .plainText,
            defaultFilename: "MP4_Tool_Log_\(Int(Date().timeIntervalSince1970))"
        ) { result in
            switch result {
            case .success(let url):
                viewModel.processor.addLog("📝 Log exported to: \(url.path)")
            case .failure(let error):
                viewModel.processor.addLog("❌ Failed to export log: \(error.localizedDescription)")
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
