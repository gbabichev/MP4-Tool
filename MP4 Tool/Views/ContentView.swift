//
//  ContentView.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import UserNotifications

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @AppStorage("selectedMode") private var selectedMode: ProcessingMode = .encodeH265
    @AppStorage("crfValue") private var crfValue: Double = 23
    @AppStorage("createSubfolders") private var createSubfolders: Bool = false
    @AppStorage("deleteOriginal") private var deleteOriginal: Bool = true
    @AppStorage("keepEnglishAudioOnly") private var keepEnglishAudioOnly: Bool = true
    @AppStorage("keepEnglishSubtitlesOnly") private var keepEnglishSubtitlesOnly: Bool = true
    @AppStorage("hasSeenTutorial") private var hasSeenTutorial = false
    @AppStorage("isLogExpanded") private var isLogExpanded = true

    var body: some View {
        HStack(spacing: 0) {
            // Main Content - Left Side
            MainContentView(viewModel: viewModel)

            // Divider
            Divider()

            // Settings - Right Side
            SettingsView(
                selectedMode: $selectedMode,
                crfValue: $crfValue,
                createSubfolders: $createSubfolders,
                deleteOriginal: $deleteOriginal,
                keepEnglishAudioOnly: $keepEnglishAudioOnly,
                keepEnglishSubtitlesOnly: $keepEnglishSubtitlesOnly,
                isProcessing: viewModel.processor.isProcessing
            )
            .frame(width: 400)
        }
        .frame(minWidth: 850, minHeight: 600)
        .safeAreaInset(edge: .bottom) {
            if isLogExpanded {
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
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .padding(.horizontal)
                    .padding(.top, 12)

                    LogView(logText: viewModel.processor.logText)
                        .frame(height: 200)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                .background(Color.gray.opacity(0.12))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    Button(action: {
                        withAnimation {
                            isLogExpanded.toggle()
                        }
                    }) {
                        HStack {
                            Text("Log Output")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.12))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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

            ToolbarItem(placement: .navigation) {
                Button(action: {
                    viewModel.clearFolders()
                }) {
                    Label("Clear All", systemImage: "arrow.counterclockwise")
                }
                .disabled(viewModel.processor.isProcessing || (viewModel.inputFolderPath.isEmpty && viewModel.outputFolderPath.isEmpty))
                .help("Clear input and output folders")
            }

            ToolbarItem(placement: .status) {
                if !viewModel.processor.ffmpegAvailable {
                    Button(action: {
                        // Show alert with explanation
                        let alert = NSAlert()
                        alert.messageText = "FFmpeg Not Found"
                        alert.informativeText = viewModel.processor.ffmpegMissingMessage
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }) {
                        Label("FFmpeg Missing", systemImage: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                    .help(viewModel.processor.ffmpegMissingMessage)
                }
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
                            deleteOriginal: deleteOriginal,
                            keepEnglishAudioOnly: keepEnglishAudioOnly,
                            keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly
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
                        deleteOriginal: deleteOriginal,
                        keepEnglishAudioOnly: keepEnglishAudioOnly,
                        keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly
                    )
                }
            }
        .onReceive(NotificationCenter.default.publisher(for: .scanForNonMP4)) { _ in
            viewModel.scanForNonMP4Files()
        }
        .onReceive(NotificationCenter.default.publisher(for: .validateMP4Files)) { _ in
            viewModel.validateMP4Files()
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Clear notifications when app gets focus
            viewModel.processor.clearProcessingNotifications()
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

            // Request notification permissions
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error = error {
                    print("Error requesting notification permission: \(error)")
                }
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
        textView.backgroundColor = NSColor(white: 0.94, alpha: 1.0)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width, .height]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.backgroundColor = NSColor(white: 0.94, alpha: 1.0)
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
