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

struct WindowCommandHandler {
    let openInputFolder: () -> Void
    let selectOutputFolder: () -> Void
    let clearFolders: () -> Void
    let startProcessing: () -> Void
    let scanForNonMP4Files: () -> Void
    let validateMP4Files: () -> Void
    let exportLog: () -> Void
    let showTutorial: () -> Void
    let showAbout: () -> Void
    let toggleFFmpegSource: () -> Void
    let canStartProcessing: Bool
    let isProcessing: Bool
    let canClearFolders: Bool
    let canExportLog: Bool
    let canToggleFFmpeg: Bool
}

private struct DefaultsSnapshot: Equatable {
    let selectedModeRaw: String
    let crfValue: Double
    let selectedResolutionRaw: String
    let selectedPresetRaw: String
    let createSubfolders: Bool
    let deleteOriginal: Bool
    let keepEnglishAudioOnly: Bool
    let keepEnglishSubtitlesOnly: Bool
    let isLogExpanded: Bool
    let isSettingsExpanded: Bool
}

private struct WindowCommandHandlerKey: FocusedValueKey {
    typealias Value = WindowCommandHandler
}

extension FocusedValues {
    var windowCommandHandler: WindowCommandHandler? {
        get { self[WindowCommandHandlerKey.self] }
        set { self[WindowCommandHandlerKey.self] = newValue }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selectedMode") private var selectedModeRaw: String = ProcessingMode.encodeH265.rawValue
    @SceneStorage("crfValue") private var crfValue: Double = 23
    @SceneStorage("selectedResolution") private var selectedResolutionRaw: String = ResolutionOption.default.rawValue
    @SceneStorage("selectedPreset") private var selectedPresetRaw: String = PresetOption.fast.rawValue
    @SceneStorage("createSubfolders") private var createSubfolders: Bool = false
    @SceneStorage("deleteOriginal") private var deleteOriginal: Bool = true
    @SceneStorage("keepEnglishAudioOnly") private var keepEnglishAudioOnly: Bool = true
    @SceneStorage("keepEnglishSubtitlesOnly") private var keepEnglishSubtitlesOnly: Bool = true
    @SceneStorage("isLogExpanded") private var isLogExpanded = true
    @SceneStorage("isSettingsExpanded") private var isSettingsExpanded = true
    @SceneStorage("didInitializeWindowDefaults") private var didInitializeWindowDefaults = false
    @AppStorage("defaultSelectedMode") private var defaultSelectedModeRaw: String = ProcessingMode.encodeH265.rawValue
    @AppStorage("defaultCrfValue") private var defaultCrfValue: Double = 23
    @AppStorage("defaultSelectedResolution") private var defaultSelectedResolutionRaw: String = ResolutionOption.default.rawValue
    @AppStorage("defaultSelectedPreset") private var defaultSelectedPresetRaw: String = PresetOption.fast.rawValue
    @AppStorage("defaultCreateSubfolders") private var defaultCreateSubfolders: Bool = false
    @AppStorage("defaultDeleteOriginal") private var defaultDeleteOriginal: Bool = true
    @AppStorage("defaultKeepEnglishAudioOnly") private var defaultKeepEnglishAudioOnly: Bool = true
    @AppStorage("defaultKeepEnglishSubtitlesOnly") private var defaultKeepEnglishSubtitlesOnly: Bool = true
    @AppStorage("defaultIsLogExpanded") private var defaultIsLogExpanded = true
    @AppStorage("defaultIsSettingsExpanded") private var defaultIsSettingsExpanded = true
    @AppStorage("hasSeenTutorial") private var hasSeenTutorial = false

    private var selectedMode: ProcessingMode {
        get { ProcessingMode(rawValue: selectedModeRaw) ?? .encodeH265 }
        set { selectedModeRaw = newValue.rawValue }
    }

    private var selectedResolution: ResolutionOption {
        get { ResolutionOption(rawValue: selectedResolutionRaw) ?? .default }
        set { selectedResolutionRaw = newValue.rawValue }
    }

    private var selectedPreset: PresetOption {
        get { PresetOption(rawValue: selectedPresetRaw) ?? .fast }
        set { selectedPresetRaw = newValue.rawValue }
    }

    private var selectedModeBinding: Binding<ProcessingMode> {
        Binding(
            get: { ProcessingMode(rawValue: selectedModeRaw) ?? .encodeH265 },
            set: { selectedModeRaw = $0.rawValue }
        )
    }

    private var selectedResolutionBinding: Binding<ResolutionOption> {
        Binding(
            get: { ResolutionOption(rawValue: selectedResolutionRaw) ?? .default },
            set: { selectedResolutionRaw = $0.rawValue }
        )
    }

    private var selectedPresetBinding: Binding<PresetOption> {
        Binding(
            get: { PresetOption(rawValue: selectedPresetRaw) ?? .fast },
            set: { selectedPresetRaw = $0.rawValue }
        )
    }

    private var commandHandler: WindowCommandHandler {
        WindowCommandHandler(
            openInputFolder: { viewModel.selectFolder(isInput: true) },
            selectOutputFolder: { viewModel.selectFolder(isInput: false) },
            clearFolders: { viewModel.clearFolders() },
            startProcessing: {
                guard viewModel.canStartProcessing, !viewModel.processor.isProcessing else { return }
                viewModel.startProcessing(
                    mode: selectedMode,
                    crfValue: Int(crfValue),
                    resolution: selectedResolution,
                    preset: selectedPreset,
                    createSubfolders: createSubfolders,
                    deleteOriginal: deleteOriginal,
                    keepEnglishAudioOnly: keepEnglishAudioOnly,
                    keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly
                )
            },
            scanForNonMP4Files: { viewModel.scanForNonMP4Files() },
            validateMP4Files: { viewModel.validateMP4Files() },
            exportLog: { viewModel.exportLogToFile() },
            showTutorial: { viewModel.showTutorial() },
            showAbout: { viewModel.showAbout() },
            toggleFFmpegSource: { viewModel.toggleFFmpegSource() },
            canStartProcessing: viewModel.canStartProcessing,
            isProcessing: viewModel.processor.isProcessing,
            canClearFolders: !(viewModel.inputFolderPath.isEmpty && viewModel.outputFolderPath.isEmpty),
            canExportLog: !viewModel.processor.logText.isEmpty,
            canToggleFFmpeg: viewModel.processor.hasBundledFFmpeg && viewModel.processor.hasSystemFFmpeg
        )
    }

    private var defaultsSnapshot: DefaultsSnapshot {
        DefaultsSnapshot(
            selectedModeRaw: selectedModeRaw,
            crfValue: crfValue,
            selectedResolutionRaw: selectedResolutionRaw,
            selectedPresetRaw: selectedPresetRaw,
            createSubfolders: createSubfolders,
            deleteOriginal: deleteOriginal,
            keepEnglishAudioOnly: keepEnglishAudioOnly,
            keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly,
            isLogExpanded: isLogExpanded,
            isSettingsExpanded: isSettingsExpanded
        )
    }

    private func enqueueQueuedOffsetFailures(_ notification: Notification) {
        guard let paths = notification.userInfo?[queueOffsetCheckerFailuresPathsKey] as? [String],
              !paths.isEmpty else {
            return
        }

        for path in paths {
            viewModel.addVideoFile(url: URL(fileURLWithPath: path))
        }
    }
    
    var mainContent: some View {
        HStack(spacing: 0) {
            // Main Content - Left Side
            MainContentView(viewModel: viewModel)
            
            // Divider between panes
            if isSettingsExpanded {
                Divider()
            }
            
            // Settings - Right Side
            SettingsPanelContainer(
                selectedMode: selectedModeBinding,
                crfValue: $crfValue,
                selectedResolution: selectedResolutionBinding,
                selectedPreset: selectedPresetBinding,
                createSubfolders: $createSubfolders,
                deleteOriginal: $deleteOriginal,
                keepEnglishAudioOnly: $keepEnglishAudioOnly,
                keepEnglishSubtitlesOnly: $keepEnglishSubtitlesOnly,
                isProcessing: viewModel.processor.isProcessing,
                isExpanded: $isSettingsExpanded
            )
        }
        .frame(minWidth: 800, minHeight: 650)
        .safeAreaInset(edge: .bottom) {
            logPanel
        }
    }
    
    @ViewBuilder
    var logPanel: some View {
        if isLogExpanded {
            ExpandedLogPanel(isLogExpanded: $isLogExpanded, logText: viewModel.processor.logText)
        } else {
            CollapsedLogPanel(isLogExpanded: $isLogExpanded)
        }
    }
    
    var body: some View {
        mainContent
#if DEBUG
            .overlay(alignment: .bottomTrailing) {
                BetaTag()
                    .padding(12)
            }
#endif
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
                                resolution: selectedResolution,
                                preset: selectedPreset,
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
            .toolbarBackground(.hidden, for: .windowToolbar)
            .focusedSceneValue(\.windowCommandHandler, commandHandler)
            .overlay {
                if viewModel.showingTutorial {
                    TutorialView(isPresented: $viewModel.showingTutorial)
                }
            }
            .overlay {
                if viewModel.showingAbout {
                    AboutOverlayView(isPresented: $viewModel.showingAbout)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: queueOffsetCheckerFailuresNotification)) { notification in
                enqueueQueuedOffsetFailures(notification)
            }
            .onAppear {
                if !hasSeenTutorial {
                    viewModel.showingTutorial = true
                }

                if !didInitializeWindowDefaults {
                    selectedModeRaw = defaultSelectedModeRaw
                    crfValue = defaultCrfValue
                    selectedResolutionRaw = defaultSelectedResolutionRaw
                    selectedPresetRaw = defaultSelectedPresetRaw
                    createSubfolders = defaultCreateSubfolders
                    deleteOriginal = defaultDeleteOriginal
                    keepEnglishAudioOnly = defaultKeepEnglishAudioOnly
                    keepEnglishSubtitlesOnly = defaultKeepEnglishSubtitlesOnly
                    isLogExpanded = defaultIsLogExpanded
                    isSettingsExpanded = defaultIsSettingsExpanded
                    didInitializeWindowDefaults = true
                }
                
                // Request notification permissions
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error = error {
                        print("Error requesting notification permission: \(error)")
                    }
                }
            }
            .onChange(of: defaultsSnapshot) { _, newValue in
                defaultSelectedModeRaw = newValue.selectedModeRaw
                defaultCrfValue = newValue.crfValue
                defaultSelectedResolutionRaw = newValue.selectedResolutionRaw
                defaultSelectedPresetRaw = newValue.selectedPresetRaw
                defaultCreateSubfolders = newValue.createSubfolders
                defaultDeleteOriginal = newValue.deleteOriginal
                defaultKeepEnglishAudioOnly = newValue.keepEnglishAudioOnly
                defaultKeepEnglishSubtitlesOnly = newValue.keepEnglishSubtitlesOnly
                defaultIsLogExpanded = newValue.isLogExpanded
                defaultIsSettingsExpanded = newValue.isSettingsExpanded
            }
            .onChange(of: scenePhase, initial: false) { _, newPhase in
                guard newPhase == .active, !viewModel.processor.isProcessing else { return }
                viewModel.processor.clearProcessingNotifications()
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

// Log Panel Views
struct ExpandedLogPanel: View {
    @Binding var isLogExpanded: Bool
    let logText: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            
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
            
            LogView(logText: logText)
                .frame(height: 200)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// Expanded Settings Panel
struct ExpandedSettingsPanel: View {
    @Binding var selectedMode: ProcessingMode
    @Binding var crfValue: Double
    @Binding var selectedResolution: ResolutionOption
    @Binding var selectedPreset: PresetOption
    @Binding var createSubfolders: Bool
    @Binding var deleteOriginal: Bool
    @Binding var keepEnglishAudioOnly: Bool
    @Binding var keepEnglishSubtitlesOnly: Bool
    let isProcessing: Bool
    @Binding var isExpanded: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            SettingsView(
                selectedMode: $selectedMode,
                crfValue: $crfValue,
                selectedResolution: $selectedResolution,
                selectedPreset: $selectedPreset,
                createSubfolders: $createSubfolders,
                deleteOriginal: $deleteOriginal,
                keepEnglishAudioOnly: $keepEnglishAudioOnly,
                keepEnglishSubtitlesOnly: $keepEnglishSubtitlesOnly,
                isProcessing: isProcessing,
                isExpanded: $isExpanded
            )
            .frame(width: 400)
        }
    }
}

struct CollapsedLogPanel: View {
    @Binding var isLogExpanded: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
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
        }
    }
}

// Settings Panel Container - Handles expanded/collapsed states
struct SettingsPanelContainer: View {
    @Binding var selectedMode: ProcessingMode
    @Binding var crfValue: Double
    @Binding var selectedResolution: ResolutionOption
    @Binding var selectedPreset: PresetOption
    @Binding var createSubfolders: Bool
    @Binding var deleteOriginal: Bool
    @Binding var keepEnglishAudioOnly: Bool
    @Binding var keepEnglishSubtitlesOnly: Bool
    let isProcessing: Bool
    @Binding var isExpanded: Bool
    
    var body: some View {
        if isExpanded {
            ExpandedSettingsPanel(
                selectedMode: $selectedMode,
                crfValue: $crfValue,
                selectedResolution: $selectedResolution,
                selectedPreset: $selectedPreset,
                createSubfolders: $createSubfolders,
                deleteOriginal: $deleteOriginal,
                keepEnglishAudioOnly: $keepEnglishAudioOnly,
                keepEnglishSubtitlesOnly: $keepEnglishSubtitlesOnly,
                isProcessing: isProcessing,
                isExpanded: $isExpanded
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            CollapsedSettingsPanel(isExpanded: $isExpanded)
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }
}

// Collapsed Settings Panel
struct CollapsedSettingsPanel: View {
    @Binding var isExpanded: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            Button(action: {
                withAnimation {
                    isExpanded = true
                }
            }) {
                Image(systemName: "chevron.left")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Expand Settings")
            
            Spacer()
        }
        .frame(width: 44)
        .padding(.vertical)
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
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width, .height]
        
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        
        // Add rounded corners
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 8
        scrollView.layer?.masksToBounds = true
        
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
