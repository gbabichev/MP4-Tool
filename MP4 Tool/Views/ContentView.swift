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

private struct ProcessingSettingsSnapshot: Equatable {
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
    let postProcessScriptPath: String
    let postProcessScriptRunTimingRaw: String
    let postProcessScriptPassFileNameAsFirstArgument: Bool
}

struct ContentView: View {
    @ObservedObject private var viewModel: ContentViewModel
    @ObservedObject private var updateCenter = AppUpdateCenter.shared
    @EnvironmentObject private var windowCommandRegistry: WindowCommandRegistry
    @Environment(\.scenePhase) private var scenePhase
    private let windowID: UUID
    @AppStorage("defaultSelectedMode") private var selectedModeRaw: String = ProcessingMode.encodeH265.rawValue
    @AppStorage("defaultCrfValue") private var crfValue: Double = 23
    @AppStorage("defaultSelectedResolution") private var selectedResolutionRaw: String = ResolutionOption.default.rawValue
    @AppStorage("defaultSelectedPreset") private var selectedPresetRaw: String = PresetOption.fast.rawValue
    @AppStorage("defaultEncodeVideo") private var encodeVideo: Bool = true
    @AppStorage("defaultEncodeAudio") private var encodeAudio: Bool = true
    @AppStorage("defaultCreateSubfolders") private var createSubfolders: Bool = false
    @AppStorage("defaultAutomaticRename") private var automaticRename: Bool = false
    @AppStorage("defaultDeleteOriginal") private var deleteOriginal: Bool = false
    @AppStorage("defaultKeepEnglishAudioOnly") private var keepEnglishAudioOnly: Bool = true
    @AppStorage("defaultKeepEnglishSubtitlesOnly") private var keepEnglishSubtitlesOnly: Bool = true
    @AppStorage("defaultPostProcessScriptPath") private var postProcessScriptPath: String = ""
    @AppStorage("defaultPostProcessScriptRunTiming") private var postProcessScriptRunTimingRaw: String = PostProcessScriptRunTiming.afterEachItem.rawValue
    @AppStorage("defaultPostProcessScriptPassFileNameAsFirstArgument") private var postProcessScriptPassFileNameAsFirstArgument: Bool = false
    @AppStorage("defaultIsLogExpanded") private var isLogExpanded = true
    @SceneStorage("isSettingsExpanded") private var sceneIsSettingsExpanded: Bool?
    @AppStorage("defaultIsSettingsExpanded") private var defaultIsSettingsExpanded = false
    @AppStorage("didAdoptCompactProcessingSetup") private var didAdoptCompactProcessingSetup = false
    @AppStorage("lastOutputFolderPath") private var lastOutputFolderPath: String = ""
    @AppStorage("hasSeenTutorial") private var hasSeenTutorial = false
    @AppStorage("processingNotificationsEnabled") private var processingNotificationsEnabled = true
    @AppStorage("framePreviewsEnabled") private var framePreviewsEnabled = true
    @AppStorage("stageTemporaryFilesOnDestinationVolume") private var stageTemporaryFilesOnDestinationVolume = false
    @State private var isShowingLogCopyConfirmation = false
    @State private var logCopyConfirmationTask: Task<Void, Never>?

    init(viewModel: ContentViewModel, windowID: UUID) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        self.windowID = windowID
    }

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

    private var postProcessScriptRunTiming: PostProcessScriptRunTiming {
        get { PostProcessScriptRunTiming(rawValue: postProcessScriptRunTimingRaw) ?? .afterEachItem }
        set {
            postProcessScriptRunTimingRaw = newValue.rawValue
            if newValue != .afterEachItem {
                postProcessScriptPassFileNameAsFirstArgument = false
            }
        }
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

    private var postProcessScriptRunTimingBinding: Binding<PostProcessScriptRunTiming> {
        Binding(
            get: { PostProcessScriptRunTiming(rawValue: postProcessScriptRunTimingRaw) ?? .afterEachItem },
            set: { newValue in
                postProcessScriptRunTimingRaw = newValue.rawValue
                if newValue != .afterEachItem {
                    postProcessScriptPassFileNameAsFirstArgument = false
                }
            }
        )
    }

    private static let cliVideoExtensions: Set<String> = ["mkv", "mp4", "avi", "mov", "m4v"]

    private var isSettingsExpanded: Bool {
        guard didAdoptCompactProcessingSetup else { return false }
        return sceneIsSettingsExpanded ?? defaultIsSettingsExpanded
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

    private var commandActions: WindowCommandActions {
        WindowCommandActions(
            openInputFolder: { viewModel.selectFolder(isInput: true) },
            selectOutputFolder: { viewModel.selectFolder(isInput: false) },
            clearFolders: { viewModel.clearFolders() },
            startProcessing: {
                startProcessingFromWindowCommand()
            },
            exportLog: { viewModel.exportLogToFile() },
            showTutorial: { viewModel.showTutorial() },
            showAbout: { viewModel.showAbout() }
        )
    }

    private var commandAvailability: WindowCommandAvailability {
        WindowCommandAvailability(
            canStartProcessing: viewModel.canStartProcessing,
            isProcessing: viewModel.processor.isProcessing,
            canClearFolders: !(viewModel.inputFolderPath.isEmpty && viewModel.outputFolderPath.isEmpty),
            canExportLog: !viewModel.processor.logText.isEmpty
        )
    }

    private var processingSettingsSnapshot: ProcessingSettingsSnapshot {
        ProcessingSettingsSnapshot(
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
            postProcessScriptPath: postProcessScriptPath,
            postProcessScriptRunTimingRaw: postProcessScriptRunTimingRaw,
            postProcessScriptPassFileNameAsFirstArgument: postProcessScriptPassFileNameAsFirstArgument
        )
    }

    private func refreshSettingsConsumers() {
        registerCLIHandler()
        registerWindowCommands()
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

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                print("Error requesting notification permission: \(error)")
            }
        }
    }

    private func copyLogToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.processor.logText, forType: .string)

        logCopyConfirmationTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) {
            isShowingLogCopyConfirmation = true
        }

        logCopyConfirmationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }

            withAnimation(.easeIn(duration: 0.2)) {
                isShowingLogCopyConfirmation = false
            }
        }
    }

    private func restoreLastOutputFolderIfAvailable() {
        guard viewModel.outputFolderPath.isEmpty, !lastOutputFolderPath.isEmpty else { return }
        viewModel.setOutputFolder(path: lastOutputFolderPath)
    }

    private func startProcessingFromWindowCommand() {
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
            postProcessScriptPath: postProcessScriptPath,
            postProcessScriptRunTiming: postProcessScriptRunTiming,
            postProcessScriptPassFileNameAsFirstArgument: postProcessScriptPassFileNameAsFirstArgument,
            stageTemporaryFilesOnDestinationVolume: stageTemporaryFilesOnDestinationVolume
        )
    }

    private func registerWindowCommands() {
        windowCommandRegistry.register(
            windowID: windowID,
            actions: commandActions,
            availability: commandAvailability
        )
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
        let postProcessScriptPath = postProcessScriptPath
        let postProcessScriptRunTiming = postProcessScriptRunTiming
        let postProcessScriptPassFileNameAsFirstArgument = postProcessScriptPassFileNameAsFirstArgument
        let stageTemporaryFilesOnDestinationVolume = stageTemporaryFilesOnDestinationVolume

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
                postProcessScriptPath: postProcessScriptPath,
                postProcessScriptRunTiming: postProcessScriptRunTiming,
                postProcessScriptPassFileNameAsFirstArgument: postProcessScriptPassFileNameAsFirstArgument,
                stageTemporaryFilesOnDestinationVolume: stageTemporaryFilesOnDestinationVolume
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

        if status.isProcessing {
            if let totalETASeconds = status.totalETASeconds {
                parts.append("ETA: \(formatCLIStatusDuration(seconds: totalETASeconds))")
            } else {
                parts.append("ETA: calculating")
            }
        }

        if !status.ffmpegAvailable {
            parts.append("FFmpeg: not available")
        }
        if status.processingHadError {
            parts.append("Last run has errors")
        }

        return .success(parts.joined(separator: "\n"), status: status)
    }

    private func currentCLIStatus() -> MP4ToolCLIStatus {
        let eta = viewModel.processor.processingETASnapshot()
        return MP4ToolCLIStatus(
            isProcessing: viewModel.processor.isProcessing,
            queueCount: viewModel.processor.videoFiles.count,
            currentFileIndex: viewModel.processor.currentFileIndex,
            totalFiles: viewModel.processor.totalFiles,
            currentFile: viewModel.processor.currentFile,
            currentFileETASeconds: eta.currentFileSeconds,
            totalETASeconds: eta.totalSeconds,
            outputFolder: viewModel.outputFolderPath,
            ffmpegAvailable: viewModel.processor.ffmpegAvailable,
            processingHadError: viewModel.processor.processingHadError
        )
    }

    private func formatCLIStatusDuration(seconds: Int) -> String {
        let totalSeconds = max(seconds, 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m \(remainingSeconds)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        return "\(remainingSeconds)s"
    }
    
    var mainContent: some View {
        HStack(spacing: 0) {
            if isSettingsExpanded {
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
                    postProcessScriptPath: $postProcessScriptPath,
                    postProcessScriptRunTiming: postProcessScriptRunTimingBinding,
                    postProcessScriptPassFileNameAsFirstArgument: $postProcessScriptPassFileNameAsFirstArgument,
                    isProcessing: viewModel.processor.isProcessing,
                    isExpanded: isSettingsExpandedBinding
                )

                Divider()
            }

            GeometryReader { geometry in
                ScrollView(.vertical) {
                    centerContent
                        .frame(
                            minHeight: geometry.size.height,
                            alignment: .top
                        )
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(WindowActivationObserver(windowID: windowID, registry: windowCommandRegistry))
        .inspector(isPresented: $isLogExpanded) {
            LogInspectorView(
                logText: viewModel.processor.logText,
                isShowingCopyConfirmation: isShowingLogCopyConfirmation
            )
            .inspectorColumnWidth(min: 280, ideal: 400, max: 700)
        }
    }

    private var centerContent: some View {
        VStack(spacing: 0) {
            if viewModel.processor.isProcessing {
                ProcessingProgressCard(processor: viewModel.processor)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            CompactProcessingSetupView(
                selectedMode: selectedModeBinding,
                crfValue: $crfValue,
                selectedResolution: selectedResolutionBinding,
                encoderPreset: selectedPresetBinding,
                encodeVideo: $encodeVideo,
                encodeAudio: $encodeAudio,
                createSubfolders: $createSubfolders,
                automaticRename: $automaticRename,
                deleteOriginal: $deleteOriginal,
                keepEnglishAudioOnly: $keepEnglishAudioOnly,
                keepEnglishSubtitlesOnly: $keepEnglishSubtitlesOnly,
                postProcessScriptPath: $postProcessScriptPath,
                postProcessScriptRunTiming: postProcessScriptRunTimingBinding,
                postProcessScriptPassFileNameAsFirstArgument: $postProcessScriptPassFileNameAsFirstArgument,
                outputFolderPath: viewModel.outputFolderPath,
                ffmpegAvailable: viewModel.processor.ffmpegAvailable,
                hasBundledFFmpeg: viewModel.processor.hasBundledFFmpeg,
                hasSystemFFmpeg: viewModel.processor.hasSystemFFmpeg,
                isUsingSystemFFmpeg: viewModel.processor.isUsingSystemFFmpeg,
                isProcessing: viewModel.processor.isProcessing,
                notificationsEnabled: $processingNotificationsEnabled,
                framePreviewsEnabled: $framePreviewsEnabled,
                stageTemporaryFilesOnDestinationVolume: $stageTemporaryFilesOnDestinationVolume,
                isSettingsExpanded: isSettingsExpandedBinding,
                onSelectFFmpegSource: { useSystem in
                    viewModel.processor.toggleFFmpegSource(useSystem: useSystem)
                },
                onChooseOutputFolder: {
                    viewModel.selectFolder(isInput: false)
                },
                onOpenOutputFolder: {
                    viewModel.openOutputFolderInFinder()
                },
                onSetOutputFolder: { path in
                    viewModel.setOutputFolder(path: path)
                }
            )

            MainContentView(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, alignment: .top)
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

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isLogExpanded.toggle()
                        }
                    } label: {
                        Label(isLogExpanded ? "Hide Log" : "Show Log", systemImage: "sidebar.trailing")
                    }
                    .help(isLogExpanded ? "Hide log inspector" : "Show log inspector")
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    if isLogExpanded && !viewModel.processor.logText.isEmpty {
                        Button(action: copyLogToClipboard) {
                            Label("Copy Log", systemImage: "doc.on.doc")
                        }
                        .help("Copy log to clipboard")

                        Button {
                            viewModel.exportLogToFile()
                        } label: {
                            Label("Export Log", systemImage: "square.and.arrow.up")
                        }
                        .help("Export log")

                        Button {
                            viewModel.processor.logText = ""
                        } label: {
                            Label("Clear Log", systemImage: "trash")
                        }
                        .help("Clear log")
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    if viewModel.processor.isProcessing {
                        Menu {
                            if viewModel.processor.stopAfterCurrentFileRequested {
                                Button {
                                    viewModel.processor.cancelStopAfterCurrentFile()
                                } label: {
                                    Label("Continue Batch", systemImage: "play.fill")
                                }
                            } else {
                                Button {
                                    viewModel.processor.requestStopAfterCurrentFile()
                                } label: {
                                    Label("Stop After Current File", systemImage: "hourglass")
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                viewModel.processor.cancelScan()
                            } label: {
                                Label("Stop Now", systemImage: "stop.fill")
                            }
                        } label: {
                            Label(
                                viewModel.processor.stopAfterCurrentFileRequested
                                    ? "Stopping After Current File"
                                    : "Stop",
                                systemImage: viewModel.processor.stopAfterCurrentFileRequested
                                    ? "hourglass"
                                    : "stop.fill"
                            )
                        } primaryAction: {
                            viewModel.processor.cancelScan()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .help(
                            viewModel.processor.stopAfterCurrentFileRequested
                                ? "The current file will finish, then the batch will stop"
                                : "Stop now, or use the menu to stop after the current file"
                        )
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
                                postProcessScriptPath: postProcessScriptPath,
                                postProcessScriptRunTiming: postProcessScriptRunTiming,
                                postProcessScriptPassFileNameAsFirstArgument: postProcessScriptPassFileNameAsFirstArgument,
                                stageTemporaryFilesOnDestinationVolume: stageTemporaryFilesOnDestinationVolume
                            )
                        }) {
                            Label("Start Processing", systemImage: "play.fill")
                        }
                        .disabled(!viewModel.canStartProcessing)
                    }
                }
            }
            .onDisappear {
                logCopyConfirmationTask?.cancel()
            }
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
            .overlay {
                if let summary = viewModel.processor.completionSummary {
                    ProcessingCompletionOverlayView(summary: summary) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.processor.completionSummary = nil
                        }
                    }
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
                if !didAdoptCompactProcessingSetup {
                    sceneIsSettingsExpanded = false
                    defaultIsSettingsExpanded = false
                    didAdoptCompactProcessingSetup = true
                }

                if !hasSeenTutorial {
                    viewModel.showingTutorial = true
                }

                if sceneIsSettingsExpanded == nil {
                    sceneIsSettingsExpanded = defaultIsSettingsExpanded
                }
                restoreLastOutputFolderIfAvailable()
                
                viewModel.processor.setNotificationsEnabled(processingNotificationsEnabled)
                viewModel.processor.setFramePreviewsEnabled(framePreviewsEnabled)
                if processingNotificationsEnabled {
                    requestNotificationPermission()
                }

                clearCompletionNotificationsIfPossible()
                registerCLIHandler()
                registerWindowCommands()
            }
            .onChange(of: processingNotificationsEnabled) { _, enabled in
                viewModel.processor.setNotificationsEnabled(enabled)
                if enabled {
                    requestNotificationPermission()
                }
            }
            .onChange(of: framePreviewsEnabled) { _, enabled in
                viewModel.processor.setFramePreviewsEnabled(enabled)
            }
            .task {
                var candidateSnapshot: ProcessingSettingsSnapshot?
                var registeredSnapshot: ProcessingSettingsSnapshot?

                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    } catch {
                        return
                    }

                    let snapshot = processingSettingsSnapshot
                    guard candidateSnapshot == snapshot else {
                        candidateSnapshot = snapshot
                        continue
                    }

                    guard registeredSnapshot != snapshot else { continue }
                    refreshSettingsConsumers()
                    registeredSnapshot = snapshot
                }
            }
            .onChange(of: commandAvailability) { _, newValue in
                windowCommandRegistry.updateAvailability(newValue, for: windowID)
            }
            .onChange(of: scenePhase, initial: false) { _, newPhase in
                guard newPhase == .active else { return }
                clearCompletionNotificationsIfPossible()
            }
            .onChange(of: viewModel.outputFolderPath) { _, newValue in
                guard !newValue.isEmpty else { return }
                lastOutputFolderPath = newValue
            }
            .onDisappear {
                windowCommandRegistry.unregister(windowID: windowID)
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

private struct CompactProcessingSetupView: View {
    @Binding var selectedMode: ProcessingMode
    @Binding var crfValue: Double
    @Binding var selectedResolution: ResolutionOption
    @Binding var encoderPreset: PresetOption
    @Binding var encodeVideo: Bool
    @Binding var encodeAudio: Bool
    @Binding var createSubfolders: Bool
    @Binding var automaticRename: Bool
    @Binding var deleteOriginal: Bool
    @Binding var keepEnglishAudioOnly: Bool
    @Binding var keepEnglishSubtitlesOnly: Bool
    @Binding var postProcessScriptPath: String
    @Binding var postProcessScriptRunTiming: PostProcessScriptRunTiming
    @Binding var postProcessScriptPassFileNameAsFirstArgument: Bool
    let outputFolderPath: String
    let ffmpegAvailable: Bool
    let hasBundledFFmpeg: Bool
    let hasSystemFFmpeg: Bool
    let isUsingSystemFFmpeg: Bool
    let isProcessing: Bool
    @Binding var notificationsEnabled: Bool
    @Binding var framePreviewsEnabled: Bool
    @Binding var stageTemporaryFilesOnDestinationVolume: Bool
    @Binding var isSettingsExpanded: Bool
    let onSelectFFmpegSource: (Bool) -> Void
    let onChooseOutputFolder: () -> Void
    let onOpenOutputFolder: () -> Void
    let onSetOutputFolder: (String) -> Void

    @AppStorage("processingPresets") private var encodedPresets = ""
    @AppStorage("selectedProcessingPresetID") private var selectedPresetIDRawValue = ""

    private var userPresets: [ProcessingPreset] {
        guard let data = encodedPresets.data(using: .utf8),
              let presets = try? JSONDecoder().decode([ProcessingPreset].self, from: data) else {
            return []
        }
        return presets.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var presets: [ProcessingPreset] {
        ProcessingPreset.builtInPresets + userPresets
    }

    private var selectedPresetID: UUID? {
        get { UUID(uuidString: selectedPresetIDRawValue) }
        nonmutating set { selectedPresetIDRawValue = newValue?.uuidString ?? "" }
    }

    private var selectedPresetIDBinding: Binding<UUID?> {
        Binding(
            get: { selectedPresetID },
            set: { selectedPresetID = $0 }
        )
    }

    private var selectedProcessingPreset: ProcessingPreset? {
        guard let selectedPresetID else { return nil }
        return presets.first { $0.id == selectedPresetID }
    }

    private var isModified: Bool {
        guard let selectedProcessingPreset else { return false }
        return currentPreset(
            id: selectedProcessingPreset.id,
            name: selectedProcessingPreset.name
        ) != selectedProcessingPreset
    }

    private var settingsSummary: String {
        switch selectedMode {
        case .remux:
            return "Remux • Copy streams without re-encoding"
        case .encodeH264, .encodeH265:
            let codec = selectedMode == .encodeH265 ? "H.265" : "H.264"
            let resolution = selectedResolution == .default
                ? "Original" : selectedResolution.description
            return "\(codec) • CRF \(Int(crfValue)) • \(resolution) • \(encoderPreset.description)"
        }
    }

    private var ffmpegSourceBinding: Binding<Bool> {
        Binding(
            get: { isUsingSystemFFmpeg },
            set: { newValue in
                onSelectFFmpegSource(newValue)
            }
        )
    }

    private var availableFFmpegSourceCount: Int {
        (hasBundledFFmpeg ? 1 : 0) + (hasSystemFFmpeg ? 1 : 0)
    }

    private var ffmpegSourceDescription: String {
        guard ffmpegAvailable else { return "FFmpeg and FFprobe were not found" }
        return isUsingSystemFFmpeg
            ? "Uses the version installed on this Mac"
            : "Uses the version included with MP4 Tool"
    }

    private var stagingLocation: ProcessingStagingLocation {
        ProcessingStagingStorage.location(
            outputPath: outputFolderPath,
            preferDestinationVolume: stageTemporaryFilesOnDestinationVolume
        )
    }

    private var effectiveDestinationStagingBinding: Binding<Bool> {
        Binding(
            get: {
                stageTemporaryFilesOnDestinationVolume
                    && stagingLocation.destinationVolumeIsEligible
            },
            set: { stageTemporaryFilesOnDestinationVolume = $0 }
        )
    }

    private var scratchSpaceDescription: String {
        let available = stagingLocation.availableBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " available"
        } ?? "Available space unknown"
        return "\(available) • \(stagingLocation.directoryURL.path)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Processing Setup", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))

                if isModified {
                    Label("Modified", systemImage: "pencil.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }

                Spacer()

                Button(isSettingsExpanded ? "Done" : "Customize…") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSettingsExpanded.toggle()
                    }
                }
                .controlSize(.small)
                .disabled(isProcessing)
            }

            HStack(spacing: 12) {
                Picker("Preset", selection: selectedPresetIDBinding) {
                    Text("Custom Settings")
                        .tag(nil as UUID?)
                    ForEach(presets) { preset in
                        Text(presetDisplayName(preset))
                            .tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)
                .disabled(isProcessing)

                Text(settingsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }

            Divider()

            AdaptiveProcessingSetupPair {
                HStack(spacing: 10) {
                    Image(systemName: ffmpegAvailable ? "terminal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(ffmpegAvailable ? Color.accentColor : Color.orange)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("FFmpeg")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)

                        Text(ffmpegSourceDescription)
                            .font(.caption2)
                            .foregroundStyle(ffmpegAvailable ? Color.secondary : Color.orange)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    if ffmpegAvailable {
                        Picker("FFmpeg Source", selection: ffmpegSourceBinding) {
                            if hasBundledFFmpeg {
                                Text("Bundled").tag(false)
                            }
                            if hasSystemFFmpeg {
                                Text("System").tag(true)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 105)
                        .disabled(isProcessing || availableFFmpegSourceCount < 2)
                        .help(
                            availableFFmpegSourceCount < 2
                                ? "Only one FFmpeg source is available"
                                : "Choose which FFmpeg installation to use"
                        )
                    } else {
                        Text("Not Available")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity)
            } trailing: {
                HStack(spacing: 10) {
                    Image(systemName: outputFolderPath.isEmpty ? "folder.badge.plus" : "folder.fill")
                        .foregroundStyle(
                            outputFolderPath.isEmpty ? Color.secondary : Color.accentColor
                        )
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Output Folder")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)

                        Text(outputFolderPath.isEmpty ? "Choose or drop an output folder here" : outputFolderPath)
                            .font(.caption2)
                            .foregroundStyle(outputFolderPath.isEmpty ? .tertiary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    Button("Choose…", action: onChooseOutputFolder)
                        .controlSize(.small)
                        .disabled(isProcessing)

                    Button("Open", action: onOpenOutputFolder)
                        .controlSize(.small)
                        .disabled(outputFolderPath.isEmpty)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: nil, perform: handleOutputFolderDrop)
            }

            Divider()

            AdaptiveProcessingSetupPair(horizontalMinimumWidth: 620) {
                ProcessingSetupToggle(
                    title: "Enable Notifications",
                    subtitle: "Notify when processing finishes in the background",
                    systemImage: "bell.fill",
                    isOn: $notificationsEnabled
                )
            } trailing: {
                ProcessingSetupToggle(
                    title: "Enable Previews",
                    subtitle: "Refresh the current frame while encoding",
                    systemImage: "photo.fill",
                    isOn: $framePreviewsEnabled
                )
            }

            Divider()

            AdaptiveProcessingSetupPair(horizontalMinimumWidth: 620) {
                HStack(spacing: 10) {
                    Image(systemName: stagingLocation.usesDestinationVolume ? "externaldrive.fill" : "internaldrive.fill")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scratch Space")
                            .font(.caption.weight(.medium))
                        Text(scratchSpaceDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity)
            } trailing: {
                ProcessingSetupToggle(
                    title: "Stage on Destination Volume",
                    subtitle: stagingLocation.destinationVolumeIsEligible
                        ? "Write temporary output beside the destination"
                        : "Requires a writable local destination volume",
                    systemImage: "externaldrive.badge.checkmark",
                    isOn: effectiveDestinationStagingBinding
                )
                .disabled(isProcessing || !stagingLocation.destinationVolumeIsEligible)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .onAppear(perform: clearInvalidSelection)
        .onChange(of: encodedPresets) { _, _ in
            clearInvalidSelection()
        }
        .onChange(of: selectedPresetID) { _, presetID in
            guard let presetID,
                  let preset = presets.first(where: { $0.id == presetID }) else {
                return
            }
            apply(preset)
        }
    }

    private func presetDisplayName(_ preset: ProcessingPreset) -> String {
        var name = ProcessingPreset.builtInPresets.contains { $0.id == preset.id }
            ? "\(preset.name) (Built-in)" : preset.name
        if preset.id == selectedPresetID, isModified {
            name += " • Modified"
        }
        return name
    }

    private func clearInvalidSelection() {
        guard selectedPresetID != nil, selectedProcessingPreset == nil else { return }
        selectedPresetID = nil
    }

    private func handleOutputFolderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isProcessing, let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, error in
            guard let url, error == nil else { return }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return
            }

            DispatchQueue.main.async {
                onSetOutputFolder(url.path)
            }
        }

        return true
    }

    private func currentPreset(id: UUID, name: String) -> ProcessingPreset {
        ProcessingPreset(
            id: id,
            name: name,
            modeRawValue: selectedMode.rawValue,
            crfValue: crfValue,
            resolutionRawValue: selectedResolution.rawValue,
            encoderPresetRawValue: encoderPreset.rawValue,
            encodeVideo: encodeVideo,
            encodeAudio: encodeAudio,
            createSubfolders: createSubfolders,
            automaticRename: automaticRename,
            deleteOriginal: deleteOriginal,
            keepEnglishAudioOnly: keepEnglishAudioOnly,
            keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly,
            postProcessScriptPath: postProcessScriptPath,
            postProcessScriptRunTimingRawValue: postProcessScriptRunTiming.rawValue,
            postProcessScriptPassFileNameAsFirstArgument:
                postProcessScriptRunTiming == .afterEachItem
                && postProcessScriptPassFileNameAsFirstArgument
        )
    }

    private func apply(_ preset: ProcessingPreset) {
        selectedMode = preset.mode
        crfValue = min(max(preset.crfValue, 0), 50)
        selectedResolution = preset.resolution
        encoderPreset = preset.encoderPreset
        encodeVideo = preset.encodeVideo
        encodeAudio = preset.encodeAudio
        createSubfolders = preset.createSubfolders
        automaticRename = preset.automaticRename
        deleteOriginal = preset.deleteOriginal
        keepEnglishAudioOnly = preset.keepEnglishAudioOnly
        keepEnglishSubtitlesOnly = preset.keepEnglishSubtitlesOnly
        postProcessScriptPath = preset.postProcessScriptPath
        postProcessScriptRunTiming = preset.postProcessScriptRunTiming
        postProcessScriptPassFileNameAsFirstArgument =
            preset.postProcessScriptRunTiming == .afterEachItem
            && preset.postProcessScriptPassFileNameAsFirstArgument
    }
}

private struct AdaptiveProcessingSetupPair<Leading: View, Trailing: View>: View {
    let horizontalMinimumWidth: CGFloat
    private let leading: () -> Leading
    private let trailing: () -> Trailing

    init(
        horizontalMinimumWidth: CGFloat = 720,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.horizontalMinimumWidth = horizontalMinimumWidth
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                leading()
                Divider()
                    .frame(height: 34)
                trailing()
            }
            .frame(minWidth: horizontalMinimumWidth)

            VStack(spacing: 9) {
                leading()
                Divider()
                trailing()
            }
        }
    }
}

private struct ProcessingSetupToggle: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LogInspectorView: View {
    let logText: String
    let isShowingCopyConfirmation: Bool
    
    var body: some View {
        Group {
            if logText.isEmpty {
                ContentUnavailableView(
                    "No Log Output",
                    systemImage: "terminal",
                    description: Text("Processing details will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LogView(logText: logText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            if isShowingCopyConfirmation {
                Label("Copied to Clipboard", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
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
    @Binding var postProcessScriptPath: String
    @Binding var postProcessScriptRunTiming: PostProcessScriptRunTiming
    @Binding var postProcessScriptPassFileNameAsFirstArgument: Bool
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
                postProcessScriptPath: $postProcessScriptPath,
                postProcessScriptRunTiming: $postProcessScriptRunTiming,
                postProcessScriptPassFileNameAsFirstArgument: $postProcessScriptPassFileNameAsFirstArgument,
                isProcessing: isProcessing,
                isExpanded: $isExpanded
            )
            .frame(width: 400)
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
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        
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
