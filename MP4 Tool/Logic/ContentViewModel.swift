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
        !inputFolderPath.isEmpty && !outputFolderPath.isEmpty
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
                    inputFolderPath = url.path
                    // Auto-scan input folder for video files
                    Task {
                        await processor.scanInputFolder(directoryPath: url.path)
                    }
                } else {
                    outputFolderPath = url.path
                }
            }
        }
    }

    func startProcessing(mode: ProcessingMode, crfValue: Int, createSubfolders: Bool, deleteOriginal: Bool, keepEnglishAudioOnly: Bool) {
        Task {
            await processor.processFolder(
                inputPath: inputFolderPath,
                outputPath: outputFolderPath,
                mode: mode,
                crfValue: crfValue,
                createSubfolders: createSubfolders,
                deleteOriginal: deleteOriginal,
                keepEnglishAudioOnly: keepEnglishAudioOnly
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
    }

    func showTutorial() {
        showingTutorial = true
    }

    func showAbout() {
        showingAbout = true
    }
}
