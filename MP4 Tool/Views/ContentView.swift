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
    let encodeVideo: Bool
    let encodeAudio: Bool
    let createSubfolders: Bool
    let automaticRename: Bool
    let deleteOriginal: Bool
    let keepEnglishAudioOnly: Bool
    let keepEnglishSubtitlesOnly: Bool
    let postEncodeScriptPath: String
    let postEncodeScriptRunTimingRaw: String
    let postEncodeScriptPassFileNameAsFirstArgument: Bool
    let isLogExpanded: Bool
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
    @ObservedObject private var updateCenter = AppUpdateCenter.shared
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("selectedMode") private var selectedModeRaw: String = ProcessingMode.encodeH265.rawValue
    @SceneStorage("crfValue") private var crfValue: Double = 23
    @SceneStorage("selectedResolution") private var selectedResolutionRaw: String = ResolutionOption.default.rawValue
    @SceneStorage("selectedPreset") private var selectedPresetRaw: String = PresetOption.fast.rawValue
    @SceneStorage("encodeVideo") private var encodeVideo: Bool = true
    @SceneStorage("encodeAudio") private var encodeAudio: Bool = true
    @SceneStorage("createSubfolders") private var createSubfolders: Bool = false
    @SceneStorage("automaticRename") private var automaticRename: Bool = false
    @SceneStorage("deleteOriginal") private var deleteOriginal: Bool = true
    @SceneStorage("keepEnglishAudioOnly") private var keepEnglishAudioOnly: Bool = true
    @SceneStorage("keepEnglishSubtitlesOnly") private var keepEnglishSubtitlesOnly: Bool = true
    @SceneStorage("postEncodeScriptPath") private var postEncodeScriptPath: String = ""
    @SceneStorage("postEncodeScriptRunTiming") private var postEncodeScriptRunTimingRaw: String = PostEncodeScriptRunTiming.afterEachItem.rawValue
    @SceneStorage("postEncodeScriptPassFileNameAsFirstArgument") private var postEncodeScriptPassFileNameAsFirstArgument: Bool = false
    @SceneStorage("isLogExpanded") private var isLogExpanded = true
    @SceneStorage("isSettingsExpanded") private var sceneIsSettingsExpanded: Bool?
    @SceneStorage("didInitializeWindowDefaults") private var didInitializeWindowDefaults = false
    @AppStorage("defaultSelectedMode") private var defaultSelectedModeRaw: String = ProcessingMode.encodeH265.rawValue
    @AppStorage("defaultCrfValue") private var defaultCrfValue: Double = 23
    @AppStorage("defaultSelectedResolution") private var defaultSelectedResolutionRaw: String = ResolutionOption.default.rawValue
    @AppStorage("defaultSelectedPreset") private var defaultSelectedPresetRaw: String = PresetOption.fast.rawValue
    @AppStorage("defaultEncodeVideo") private var defaultEncodeVideo: Bool = true
    @AppStorage("defaultEncodeAudio") private var defaultEncodeAudio: Bool = true
    @AppStorage("defaultCreateSubfolders") private var defaultCreateSubfolders: Bool = false
    @AppStorage("defaultAutomaticRename") private var defaultAutomaticRename: Bool = false
    @AppStorage("defaultDeleteOriginal") private var defaultDeleteOriginal: Bool = true
    @AppStorage("defaultKeepEnglishAudioOnly") private var defaultKeepEnglishAudioOnly: Bool = true
    @AppStorage("defaultKeepEnglishSubtitlesOnly") private var defaultKeepEnglishSubtitlesOnly: Bool = true
    @AppStorage("defaultPostEncodeScriptPath") private var defaultPostEncodeScriptPath: String = ""
    @AppStorage("defaultPostEncodeScriptRunTiming") private var defaultPostEncodeScriptRunTimingRaw: String = PostEncodeScriptRunTiming.afterEachItem.rawValue
    @AppStorage("defaultPostEncodeScriptPassFileNameAsFirstArgument") private var defaultPostEncodeScriptPassFileNameAsFirstArgument: Bool = false
    @AppStorage("defaultIsLogExpanded") private var defaultIsLogExpanded = true
    @AppStorage("defaultIsSettingsExpanded") private var defaultIsSettingsExpanded = true
    @AppStorage("lastOutputFolderPath") private var lastOutputFolderPath: String = ""
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

    private var postEncodeScriptRunTiming: PostEncodeScriptRunTiming {
        get { PostEncodeScriptRunTiming(rawValue: postEncodeScriptRunTimingRaw) ?? .afterEachItem }
        set { postEncodeScriptRunTimingRaw = newValue.rawValue }
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

    private var postEncodeScriptRunTimingBinding: Binding<PostEncodeScriptRunTiming> {
        Binding(
            get: { PostEncodeScriptRunTiming(rawValue: postEncodeScriptRunTimingRaw) ?? .afterEachItem },
            set: { postEncodeScriptRunTimingRaw = $0.rawValue }
        )
    }

    private static let cliVideoExtensions: Set<String> = ["mkv", "mp4", "avi", "mov", "m4v"]

    private var isSettingsExpanded: Bool {
        sceneIsSettingsExpanded ?? defaultIsSettingsExpanded
    }

    private var isSettingsExpandedBinding: Binding<Bool> {
        Binding(
            get: { isSettingsExpanded },
            set: { newValue in
                sceneIsSettingsExpanded = newValue
                defaultIsSettingsExpanded = newValue
            }
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
                    encodeVideo: encodeVideo,
                    encodeAudio: encodeAudio,
                    createSubfolders: createSubfolders,
                    automaticRename: automaticRename,
                    deleteOriginal: deleteOriginal,
                    keepEnglishAudioOnly: keepEnglishAudioOnly,
                    keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly,
                    postEncodeScriptPath: postEncodeScriptPath,
                    postEncodeScriptRunTiming: postEncodeScriptRunTiming,
                    postEncodeScriptPassFileNameAsFirstArgument: postEncodeScriptPassFileNameAsFirstArgument
                )
            },
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
            encodeVideo: encodeVideo,
            encodeAudio: encodeAudio,
            createSubfolders: createSubfolders,
            automaticRename: automaticRename,
            deleteOriginal: deleteOriginal,
            keepEnglishAudioOnly: keepEnglishAudioOnly,
            keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly,
            postEncodeScriptPath: postEncodeScriptPath,
            postEncodeScriptRunTimingRaw: postEncodeScriptRunTimingRaw,
            postEncodeScriptPassFileNameAsFirstArgument: postEncodeScriptPassFileNameAsFirstArgument,
            isLogExpanded: isLogExpanded
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

    private func enqueueQueuedNonMP4FlaggedFiles(_ notification: Notification) {
        guard let paths = notification.userInfo?[queueNonMP4FlaggedFilesPathsKey] as? [String],
              !paths.isEmpty else {
            return
        }

        for path in paths {
            viewModel.addVideoFile(url: URL(fileURLWithPath: path))
        }
    }

    private func enqueueQueuedMP4ValidationFlaggedFiles(_ notification: Notification) {
        guard let paths = notification.userInfo?[queueMP4ValidationFlaggedFilesPathsKey] as? [String],
              !paths.isEmpty else {
            return
        }

        for path in paths {
            viewModel.addVideoFile(url: URL(fileURLWithPath: path))
        }
    }

    private func clearCompletionNotificationsIfPossible() {
        guard !viewModel.processor.isProcessing else { return }
        viewModel.processor.clearProcessingNotifications()
    }

    private func restoreLastOutputFolderIfAvailable() {
        guard viewModel.outputFolderPath.isEmpty, !lastOutputFolderPath.isEmpty else { return }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: lastOutputFolderPath, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue {
            viewModel.setOutputFolder(path: lastOutputFolderPath)
        } else {
            lastOutputFolderPath = ""
        }
    }

    private func registerCLIHandler() {
        CLICommandCenter.shared.register(
            handler: MP4ToolCLIHandler(
                addFiles: { paths, shouldStart in
                    addFilesFromCLI(paths: paths, shouldStart: shouldStart)
                },
                startProcessing: {
                    startProcessingFromCLI()
                },
                stopProcessing: {
                    stopProcessingFromCLI()
                },
                clearQueue: {
                    clearQueueFromCLI()
                },
                status: {
                    cliStatusResponse()
                }
            )
        )
    }

    private func addFilesFromCLI(paths: [String], shouldStart: Bool) -> MP4ToolCLIResponse {
        guard !paths.isEmpty else {
            return .failure("No files were provided.", status: currentCLIStatus())
        }

        let beforeQueuedPaths = Set(viewModel.processor.videoFiles.map(\.filePath))
        let (fileURLs, skippedCount) = collectCLIFileURLs(paths: paths)

        for url in fileURLs {
            viewModel.addVideoFile(url: url)
        }

        let afterQueuedPaths = Set(viewModel.processor.videoFiles.map(\.filePath))
        let addedCount = afterQueuedPaths.subtracting(beforeQueuedPaths).count
        var messageParts = ["Queued \(addedCount) file\(addedCount == 1 ? "" : "s")."]
        if skippedCount > 0 {
            messageParts.append("Skipped \(skippedCount) unsupported or missing path\(skippedCount == 1 ? "" : "s").")
        }

        if shouldStart {
            let startResponse = startProcessingFromCLI()
            messageParts.append(startResponse.message)
            return MP4ToolCLIResponse(
                success: startResponse.success,
                message: messageParts.joined(separator: " "),
                status: currentCLIStatus()
            )
        }

        return .success(messageParts.joined(separator: " "), status: currentCLIStatus())
    }

    private func collectCLIFileURLs(paths: [String]) -> (urls: [URL], skippedCount: Int) {
        var urls: [URL] = []
        var skippedCount = 0
        let fileManager = FileManager.default

        for path in paths {
            guard let url = absoluteCLIURL(from: path) else {
                skippedCount += 1
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                skippedCount += 1
                continue
            }

            if isDirectory.boolValue {
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    skippedCount += 1
                    continue
                }

                for case let fileURL as URL in enumerator {
                    guard Self.cliVideoExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                    urls.append(fileURL.standardizedFileURL)
                }
            } else if Self.cliVideoExtensions.contains(url.pathExtension.lowercased()) {
                urls.append(url.standardizedFileURL)
            } else {
                skippedCount += 1
            }
        }

        let uniqueURLs = Dictionary(grouping: urls, by: \.path)
            .compactMap { $0.value.first }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (uniqueURLs, skippedCount)
    }

    private func absoluteCLIURL(from path: String) -> URL? {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard expandedPath.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: expandedPath).standardizedFileURL
    }

    private func startProcessingFromCLI() -> MP4ToolCLIResponse {
        guard !viewModel.processor.isProcessing else {
            return .failure("MP4 Tool is already processing.", status: currentCLIStatus())
        }

        guard viewModel.canStartProcessing else {
            return .failure("Cannot start: queue files and select an output folder first.", status: currentCLIStatus())
        }

        let selectedMode = selectedMode
        let selectedResolution = selectedResolution
        let selectedPreset = selectedPreset
        let crfValue = Int(crfValue)
        let encodeVideo = encodeVideo
        let encodeAudio = encodeAudio
        let createSubfolders = createSubfolders
        let automaticRename = automaticRename
        let deleteOriginal = deleteOriginal
        let keepEnglishAudioOnly = keepEnglishAudioOnly
        let keepEnglishSubtitlesOnly = keepEnglishSubtitlesOnly
        let postEncodeScriptPath = postEncodeScriptPath
        let postEncodeScriptRunTiming = postEncodeScriptRunTiming
        let postEncodeScriptPassFileNameAsFirstArgument = postEncodeScriptPassFileNameAsFirstArgument

        Task { @MainActor in
            viewModel.startProcessing(
                mode: selectedMode,
                crfValue: crfValue,
                resolution: selectedResolution,
                preset: selectedPreset,
                encodeVideo: encodeVideo,
                encodeAudio: encodeAudio,
                createSubfolders: createSubfolders,
                automaticRename: automaticRename,
                deleteOriginal: deleteOriginal,
                keepEnglishAudioOnly: keepEnglishAudioOnly,
                keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly,
                postEncodeScriptPath: postEncodeScriptPath,
                postEncodeScriptRunTiming: postEncodeScriptRunTiming,
                postEncodeScriptPassFileNameAsFirstArgument: postEncodeScriptPassFileNameAsFirstArgument
            )
        }

        return .success("Start requested.", status: currentCLIStatus())
    }

    private func stopProcessingFromCLI() -> MP4ToolCLIResponse {
        guard viewModel.processor.isProcessing else {
            return .success("MP4 Tool is not currently processing.", status: currentCLIStatus())
        }

        viewModel.processor.cancelScan()
        return .success("Stop requested.", status: currentCLIStatus())
    }

    private func clearQueueFromCLI() -> MP4ToolCLIResponse {
        guard !viewModel.processor.isProcessing else {
            return .failure("Cannot clear queue while processing.", status: currentCLIStatus())
        }

        viewModel.clearFilesToProcess()
        return .success("Queue cleared.", status: currentCLIStatus())
    }

    private func cliStatusResponse() -> MP4ToolCLIResponse {
        let status = currentCLIStatus()
        var parts: [String] = [
            status.isProcessing
                ? "Processing \(status.currentFileIndex)/\(status.totalFiles): \(status.currentFile)"
                : "Idle",
            "Queue: \(status.queueCount)",
            status.outputFolder.isEmpty ? "Output: not selected" : "Output: \(status.outputFolder)"
        ]

        if !status.ffmpegAvailable {
            parts.append("FFmpeg: not available")
        }
        if status.processingHadError {
            parts.append("Last run has errors")
        }

        return .success(parts.joined(separator: "\n"), status: status)
    }

    private func currentCLIStatus() -> MP4ToolCLIStatus {
        MP4ToolCLIStatus(
            isProcessing: viewModel.processor.isProcessing,
            queueCount: viewModel.processor.videoFiles.count,
            currentFileIndex: viewModel.processor.currentFileIndex,
            totalFiles: viewModel.processor.totalFiles,
            currentFile: viewModel.processor.currentFile,
            outputFolder: viewModel.outputFolderPath,
            ffmpegAvailable: viewModel.processor.ffmpegAvailable,
            processingHadError: viewModel.processor.processingHadError
        )
    }
    
    var mainContent: some View {
        HStack(spacing: 0) {
            if isSettingsExpanded {
                // Settings - Left Side
                ExpandedSettingsPanel(
                    selectedMode: selectedModeBinding,
                    crfValue: $crfValue,
                    selectedResolution: selectedResolutionBinding,
                    selectedPreset: selectedPresetBinding,
                    encodeVideo: $encodeVideo,
                    encodeAudio: $encodeAudio,
                    createSubfolders: $createSubfolders,
                    automaticRename: $automaticRename,
                    deleteOriginal: $deleteOriginal,
                    keepEnglishAudioOnly: $keepEnglishAudioOnly,
                    keepEnglishSubtitlesOnly: $keepEnglishSubtitlesOnly,
                    postEncodeScriptPath: $postEncodeScriptPath,
                    postEncodeScriptRunTiming: postEncodeScriptRunTimingBinding,
                    postEncodeScriptPassFileNameAsFirstArgument: $postEncodeScriptPassFileNameAsFirstArgument,
                    isProcessing: viewModel.processor.isProcessing,
                    isExpanded: isSettingsExpandedBinding
                )

                // Divider between panes
                Divider()
            }

            // Main Content - Right Side
            MainContentView(viewModel: viewModel)
        }
        .frame(minWidth: 800, minHeight: 360)
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
                    Button {
                        withAnimation {
                            isSettingsExpandedBinding.wrappedValue.toggle()
                        }
                    } label: {
                        Label(isSettingsExpanded ? "Hide Settings" : "Show Settings", systemImage: "sidebar.left")
                    }
                    .help(isSettingsExpanded ? "Hide settings panel" : "Show settings panel")
                }

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
                        Label("Output Folder", systemImage: "folder.badge.plus")
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
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .keyboardShortcut(".", modifiers: .command)
                    } else {
                        Button(action: {
                            viewModel.startProcessing(
                                mode: selectedMode,
                                crfValue: Int(crfValue),
                                resolution: selectedResolution,
                                preset: selectedPreset,
                                encodeVideo: encodeVideo,
                                encodeAudio: encodeAudio,
                                createSubfolders: createSubfolders,
                                automaticRename: automaticRename,
                                deleteOriginal: deleteOriginal,
                                keepEnglishAudioOnly: keepEnglishAudioOnly,
                                keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly,
                                postEncodeScriptPath: postEncodeScriptPath,
                                postEncodeScriptRunTiming: postEncodeScriptRunTiming,
                                postEncodeScriptPassFileNameAsFirstArgument: postEncodeScriptPassFileNameAsFirstArgument
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
            .overlay {
                if let update = updateCenter.availableUpdate {
                    UpdateAvailableOverlayView(
                        update: update,
                        onLater: {
                            updateCenter.dismissAvailableUpdate()
                        },
                        onDownload: {
                            updateCenter.openAvailableUpdateDownloadPage()
                        }
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: queueOffsetCheckerFailuresNotification)) { notification in
                enqueueQueuedOffsetFailures(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: queueNonMP4FlaggedFilesNotification)) { notification in
                enqueueQueuedNonMP4FlaggedFiles(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: queueMP4ValidationFlaggedFilesNotification)) { notification in
                enqueueQueuedMP4ValidationFlaggedFiles(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                clearCompletionNotificationsIfPossible()
            }
            .onAppear {
                if !hasSeenTutorial {
                    viewModel.showingTutorial = true
                }

                if sceneIsSettingsExpanded == nil {
                    sceneIsSettingsExpanded = defaultIsSettingsExpanded
                }

                if !didInitializeWindowDefaults {
                    selectedModeRaw = defaultSelectedModeRaw
                    crfValue = defaultCrfValue
                    selectedResolutionRaw = defaultSelectedResolutionRaw
                    selectedPresetRaw = defaultSelectedPresetRaw
                    encodeVideo = defaultEncodeVideo
                    encodeAudio = defaultEncodeAudio
                    createSubfolders = defaultCreateSubfolders
                    automaticRename = defaultAutomaticRename
                    deleteOriginal = defaultDeleteOriginal
                    keepEnglishAudioOnly = defaultKeepEnglishAudioOnly
                    keepEnglishSubtitlesOnly = defaultKeepEnglishSubtitlesOnly
                    postEncodeScriptPath = defaultPostEncodeScriptPath
                    postEncodeScriptRunTimingRaw = defaultPostEncodeScriptRunTimingRaw
                    postEncodeScriptPassFileNameAsFirstArgument = defaultPostEncodeScriptPassFileNameAsFirstArgument
                    isLogExpanded = defaultIsLogExpanded
                    didInitializeWindowDefaults = true
                }

                restoreLastOutputFolderIfAvailable()
                
                // Request notification permissions
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error = error {
                        print("Error requesting notification permission: \(error)")
                    }
                }

                clearCompletionNotificationsIfPossible()
                registerCLIHandler()
            }
            .onChange(of: defaultsSnapshot) { _, newValue in
                defaultSelectedModeRaw = newValue.selectedModeRaw
                defaultCrfValue = newValue.crfValue
                defaultSelectedResolutionRaw = newValue.selectedResolutionRaw
                defaultSelectedPresetRaw = newValue.selectedPresetRaw
                defaultEncodeVideo = newValue.encodeVideo
                defaultEncodeAudio = newValue.encodeAudio
                defaultCreateSubfolders = newValue.createSubfolders
                defaultAutomaticRename = newValue.automaticRename
                defaultDeleteOriginal = newValue.deleteOriginal
                defaultKeepEnglishAudioOnly = newValue.keepEnglishAudioOnly
                defaultKeepEnglishSubtitlesOnly = newValue.keepEnglishSubtitlesOnly
                defaultPostEncodeScriptPath = newValue.postEncodeScriptPath
                defaultPostEncodeScriptRunTimingRaw = newValue.postEncodeScriptRunTimingRaw
                defaultPostEncodeScriptPassFileNameAsFirstArgument = newValue.postEncodeScriptPassFileNameAsFirstArgument
                defaultIsLogExpanded = newValue.isLogExpanded
                registerCLIHandler()
            }
            .onChange(of: scenePhase, initial: false) { _, newPhase in
                guard newPhase == .active else { return }
                clearCompletionNotificationsIfPossible()
            }
            .onChange(of: viewModel.outputFolderPath) { _, newValue in
                guard !newValue.isEmpty else { return }
                lastOutputFolderPath = newValue
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
    @Binding var encodeVideo: Bool
    @Binding var encodeAudio: Bool
    @Binding var createSubfolders: Bool
    @Binding var automaticRename: Bool
    @Binding var deleteOriginal: Bool
    @Binding var keepEnglishAudioOnly: Bool
    @Binding var keepEnglishSubtitlesOnly: Bool
    @Binding var postEncodeScriptPath: String
    @Binding var postEncodeScriptRunTiming: PostEncodeScriptRunTiming
    @Binding var postEncodeScriptPassFileNameAsFirstArgument: Bool
    let isProcessing: Bool
    @Binding var isExpanded: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            SettingsView(
                selectedMode: $selectedMode,
                crfValue: $crfValue,
                selectedResolution: $selectedResolution,
                selectedPreset: $selectedPreset,
                encodeVideo: $encodeVideo,
                encodeAudio: $encodeAudio,
                createSubfolders: $createSubfolders,
                automaticRename: $automaticRename,
                deleteOriginal: $deleteOriginal,
                keepEnglishAudioOnly: $keepEnglishAudioOnly,
                keepEnglishSubtitlesOnly: $keepEnglishSubtitlesOnly,
                postEncodeScriptPath: $postEncodeScriptPath,
                postEncodeScriptRunTiming: $postEncodeScriptRunTiming,
                postEncodeScriptPassFileNameAsFirstArgument: $postEncodeScriptPassFileNameAsFirstArgument,
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
