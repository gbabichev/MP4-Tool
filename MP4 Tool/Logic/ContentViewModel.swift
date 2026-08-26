//
//  ContentViewModel.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

@MainActor
class ContentViewModel: ObservableObject {
    let processor = VideoProcessor()
    @Published var inputFolderPath: String = ""
    @Published var outputFolderPath: String = ""
    @Published var showingLogExporter = false
    @Published var logExportDocument: LogDocument?
    @Published var showingTutorial = false
    @Published var showingAbout = false
    @Published var selectedFileIDs: Set<UUID> = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Forward processor's objectWillChange to our objectWillChange
        processor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        .store(in: &cancellables)
    }

    var canStartProcessing: Bool {
        !outputFolderPath.isEmpty && !processor.videoFiles.isEmpty
    }

    func formattedTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return "\(minutes)m \(remainingSeconds)s"
    }

    func selectFolder(isInput: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = isInput ? "Select folder containing video files to encode" : "Select folder where encoded files will be saved"

        CleanFilePanelPresenter.present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            if isInput {
                self.setInputFolder(path: url.path)
            } else {
                self.setOutputFolder(path: url.path)
            }
        }
    }

    func setInputFolder(path: String) {
        inputFolderPath = path
        // Auto-scan input folder for video files
        Task {
            await processor.scanInputFolder(directoryPath: path, outputPath: outputFolderPath)
        }
        checkForSameFolderWarning()
    }

    func setOutputFolder(path: String, createIfMissing: Bool = false) {
        outputFolderPath = path
        if createIfMissing {
            _ = ensureOutputFolderExists()
        }
        checkForSameFolderWarning()

        // Check for conflicts with existing files in queue
        for (index, _) in processor.videoFiles.enumerated() {
            processor.checkFileForConflicts(fileIndex: index, outputPath: path, createSubfolders: false)
        }
    }

    @discardableResult
    func ensureOutputFolderExists() -> Bool {
        guard !outputFolderPath.isEmpty else { return false }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputFolderPath, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return true
            }

            processor.addLog("Output path exists but is not a folder: \(outputFolderPath)")
            return false
        }

        do {
            try FileManager.default.createDirectory(atPath: outputFolderPath, withIntermediateDirectories: true)
            processor.addLog("Created output directory: \(outputFolderPath)")
            return true
        } catch {
            processor.addLog("Failed to create output directory: \(error.localizedDescription)")
            return false
        }
    }

    private func validateOutputFolderForProcessing() -> Bool {
        guard !outputFolderPath.isEmpty else { return false }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: outputFolderPath, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            let issue = exists ? "is not a folder" : "no longer exists"
            processor.addLog("Output folder \(issue): \(outputFolderPath)")

            let alert = NSAlert()
            alert.messageText = exists ? "Invalid Output Folder" : "Output Folder Not Found"
            alert.informativeText = "The selected output folder \(issue):\n\n\(outputFolderPath)\n\nPlease choose another output folder before starting."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Choose Folder…")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                selectFolder(isInput: false)
            }
            return false
        }

        return true
    }

    func openOutputFolderInFinder() {
        guard ensureOutputFolderExists() else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: outputFolderPath, isDirectory: true))
    }

    private func checkForSameFolderWarning() {
        guard !inputFolderPath.isEmpty && !outputFolderPath.isEmpty else { return }

        if inputFolderPath == outputFolderPath {
            let alert = NSAlert()
            alert.messageText = "Warning: Same Folder Selected"
            alert.informativeText = "Input and output folders are the same. This may cause file deletion if the file extensions match. It's recommended to use different folders."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func startProcessing(
        mode: ProcessingMode,
        crfValue: Int,
        resolution: ResolutionOption,
        preset: PresetOption,
        encodeVideo: Bool,
        encodeAudio: Bool,
        createSubfolders: Bool,
        automaticRename: Bool,
        deleteOriginal: Bool,
        keepEnglishAudioOnly: Bool,
        keepEnglishSubtitlesOnly: Bool,
        postProcessScriptPath: String,
        postProcessScriptRunTiming: PostProcessScriptRunTiming,
        postProcessScriptPassFileNameAsFirstArgument: Bool,
        stageTemporaryFilesOnDestinationVolume: Bool
    ) {
        guard validateOutputFolderForProcessing() else { return }
        guard validateStorageForProcessing(
            stageTemporaryFilesOnDestinationVolume: stageTemporaryFilesOnDestinationVolume
        ) else { return }

        // Re-check for file conflicts in case settings changed (like createSubfolders)
        _ = processor.checkForFileConflicts(
            outputPath: outputFolderPath,
            createSubfolders: createSubfolders,
            automaticRename: automaticRename
        )

        // Check if any files have conflicts
        let hasConflicts = processor.videoFiles.contains { $0.hasConflict }

        if hasConflicts {
            // Show alert about file conflicts
            let alert = NSAlert()
            alert.messageText = "File Conflict Warning"
            alert.informativeText = "Some files have conflicts (marked with ! in the list). Review them in the file list and proceed only if intentional."

            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Proceed")

            let response = alert.runModal()
            guard response == .alertSecondButtonReturn else { return }
        }

        // Starting the batch confirms any replacement warnings. Remove them from
        // the queue immediately instead of showing "Needs Attention" throughout
        // a run the user has already approved.
        for index in processor.videoFiles.indices {
            processor.videoFiles[index].hasConflict = false
            processor.videoFiles[index].conflictReason = ""
        }

        Task {
            await processor.processFolder(
                inputPath: inputFolderPath,
                outputPath: outputFolderPath,
                mode: mode,
                crfValue: crfValue,
                resolution: resolution,
                preset: preset,
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
    }

    private func validateStorageForProcessing(
        stageTemporaryFilesOnDestinationVolume: Bool
    ) -> Bool {
        let largestInputBytes = processor.videoFiles.compactMap { file in
            (try? FileManager.default.attributesOfItem(atPath: file.filePath))?[.size] as? Int64
        }.max() ?? 0
        let location = ProcessingStagingStorage.location(
            outputPath: outputFolderPath,
            preferDestinationVolume: stageTemporaryFilesOnDestinationVolume
        )

        guard let issue = ProcessingStagingStorage.capacityIssue(
            estimatedOutputBytes: largestInputBytes,
            location: location,
            outputPath: outputFolderPath
        ) else {
            return true
        }

        processor.addLog("Storage preflight failed: \(issue)")
        let alert = NSAlert()
        alert.messageText = "Not Enough Processing Space"
        alert.informativeText = "\(issue)\n\nStaging location:\n\(location.directoryURL.path)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return false
    }

    func exportLogToFile() {
        guard !processor.logText.isEmpty else {
            processor.addLog("􀇾 Cannot export: Log is empty")
            return
        }

        logExportDocument = LogDocument(text: processor.logText)
        showingLogExporter = true
    }

    func clearFolders() {
        inputFolderPath = ""
        outputFolderPath = ""
        processor.logText = ""
        processor.videoFiles = []
        selectedFileIDs.removeAll()
        processor.totalFiles = 0
        processor.processingHadError = false
        processor.clearDockBadge()
    }

    func clearFilesToProcess() {
        processor.videoFiles = []
        selectedFileIDs.removeAll()
        processor.totalFiles = 0
        processor.processingHadError = false
    }

    func removeFile(at index: Int) {
        guard index < processor.videoFiles.count else { return }
        selectedFileIDs.remove(processor.videoFiles[index].id)
        processor.videoFiles.remove(at: index)
        processor.totalFiles = processor.videoFiles.count
    }

    func addVideoFile(url: URL) {
        // Check if file already exists in list or pending batch
        if processor.videoFiles.contains(where: { $0.filePath == url.path }) {
            return
        }

        // Reset error flag when new files are added
        processor.processingHadError = false

        // Get file info
        let fileName = url.lastPathComponent
        let fileExtension = url.pathExtension.uppercased()

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? Int64 {
            let sizeMB = Int(fileSize / (1024 * 1024))

            let fileInfo = VideoFileInfo(
                fileName: fileName,
                filePath: url.path,
                fileExtension: fileExtension,
                fileSizeMB: sizeMB
            )

            // Always add to videoFiles so UI sees the file immediately
            processor.videoFiles.append(fileInfo)

            if processor.isProcessing {
                // Track in pending batch for processing later
                processor.addToPendingBatch(fileInfo)
            } else {
                // Sort files alphabetically by file path if not processing
                processor.videoFiles.sort { $0.filePath < $1.filePath }

                // Check for conflicts with the output folder
                if !outputFolderPath.isEmpty {
                    // Find the index of the newly added file after sorting
                    if let fileIndex = processor.videoFiles.firstIndex(where: { $0.filePath == url.path }) {
                        processor.checkFileForConflicts(fileIndex: fileIndex, outputPath: outputFolderPath, createSubfolders: false)
                    }
                }
            }

            processor.totalFiles = processor.videoFiles.count
        }
    }

    func showTutorial() {
        showingTutorial = true
    }

    func showAbout() {
        showingAbout = true
    }

}
