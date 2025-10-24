//
//  ContentViewModel.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

@MainActor
class ContentViewModel: ObservableObject {
    let processor = VideoProcessor()
    @Published var inputFolderPath: String = ""
    @Published var outputFolderPath: String = ""
    @Published var showingLogExporter = false
    @Published var logExportDocument: LogDocument?
    @Published var showingTutorial = false
    @Published var showingAbout = false

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

        if panel.runModal() == .OK {
            if let url = panel.url {
                if isInput {
                    setInputFolder(path: url.path)
                } else {
                    setOutputFolder(path: url.path)
                }
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

    func setOutputFolder(path: String) {
        outputFolderPath = path
        checkForSameFolderWarning()

        // Check for conflicts with existing files in queue
        for (index, _) in processor.videoFiles.enumerated() {
            processor.checkFileForConflicts(fileIndex: index, outputPath: path, createSubfolders: false)
        }
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
        createSubfolders: Bool,
        deleteOriginal: Bool,
        keepEnglishAudioOnly: Bool,
        keepEnglishSubtitlesOnly: Bool
    ) {
        // Re-check for file conflicts in case settings changed (like createSubfolders)
        _ = processor.checkForFileConflicts(
            inputPath: inputFolderPath,
            outputPath: outputFolderPath,
            createSubfolders: createSubfolders
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

        Task {
            await processor.processFolder(
                inputPath: inputFolderPath,
                outputPath: outputFolderPath,
                mode: mode,
                crfValue: crfValue,
                createSubfolders: createSubfolders,
                deleteOriginal: deleteOriginal,
                keepEnglishAudioOnly: keepEnglishAudioOnly,
                keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly
            )
        }
    }

    func scanForNonMP4Files() {
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
        processor.totalFiles = 0
        processor.processingHadError = false
    }

    func removeFile(at index: Int) {
        guard index < processor.videoFiles.count else { return }
        processor.videoFiles.remove(at: index)
        processor.totalFiles = processor.videoFiles.count
    }

    func addVideoFile(url: URL) {
        // Check if file already exists in list
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

            processor.videoFiles.append(fileInfo)
            processor.totalFiles = processor.videoFiles.count

            // Check for conflicts with the output folder
            if !outputFolderPath.isEmpty {
                let fileIndex = processor.videoFiles.count - 1
                processor.checkFileForConflicts(fileIndex: fileIndex, outputPath: outputFolderPath, createSubfolders: false)
            }
        }
    }

    func showTutorial() {
        showingTutorial = true
    }

    func showAbout() {
        showingAbout = true
    }
}
