import Foundation
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

let queueMP4ValidationFlaggedFilesNotification = Notification.Name("MP4Tool.QueueMP4ValidationFlaggedFiles")
let queueMP4ValidationFlaggedFilesPathsKey = "paths"

struct MP4ValidationResult: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let issue: String?

    var isFlagged: Bool {
        issue != nil
    }
}

@MainActor
final class MP4ValidationViewModel: ObservableObject {
    @Published var inputFolderPath: String = ""
    @Published var isScanning = false
    @Published var scanProgress = ""
    @Published var scanAlertText = ""
    @Published var results: [MP4ValidationResult] = []

    private var ffprobePath: String = ""
    private var ffprobeAvailable = false
    private var scanTask: Task<Void, Never>?
    private var scanToken = UUID()
    private let processLock = NSLock()
    private nonisolated(unsafe) var currentProcess: Process?
    private var exportDialogHostWindow: NSWindow?

    var canScan: Bool {
        !inputFolderPath.isEmpty && !isScanning
    }

    var flaggedResults: [MP4ValidationResult] {
        results.filter(\.isFlagged)
    }

    var canExportFlagged: Bool {
        !isScanning && !flaggedResults.isEmpty
    }

    var canSendFlaggedToMainApp: Bool {
        !isScanning && !flaggedResults.isEmpty
    }

    init() {
        locateFFprobe()
    }

    func selectInputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Select folder to validate MP4 files"

        if panel.runModal() == .OK, let url = panel.url {
            inputFolderPath = url.path
        }
    }

    func openInputFolderInFinder() {
        guard !inputFolderPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: inputFolderPath, isDirectory: true))
    }

    func scan() {
        guard canScan else { return }
        results = []
        scanProgress = "Preparing validation..."
        scanAlertText = ""
        isScanning = true

        scanTask?.cancel()
        scanToken = UUID()
        let token = scanToken
        scanTask = Task {
            await runScan(token: token)
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanToken = UUID()
        terminateCurrentProcess()
        scanProgress = "Validation canceled."
        isScanning = false
    }

    func exportFlaggedToFile() {
        let flaggedPaths = flaggedResults.map(\.filePath)
        guard !flaggedPaths.isEmpty else {
            scanAlertText = "No flagged files to export."
            return
        }

        let hostWindow = makeHiddenChromeHostWindow()
        exportDialogHostWindow = hostWindow
        hostWindow.makeKeyAndOrderFront(nil)

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "validate-mp4-flagged-files.txt"

        panel.beginSheetModal(for: hostWindow) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }

                defer {
                    self.exportDialogHostWindow?.orderOut(nil)
                    self.exportDialogHostWindow = nil
                }

                guard response == .OK, let url = panel.url else {
                    return
                }

                let body = flaggedPaths.joined(separator: "\n")
                do {
                    try body.write(to: url, atomically: true, encoding: .utf8)
                    self.scanAlertText = "Exported \(flaggedPaths.count) flagged path(s) to \(url.path)."
                } catch {
                    self.scanAlertText = "Failed to export flagged files: \(error.localizedDescription)"
                }
            }
        }
    }

    func sendFlaggedToMainApp() {
        let flaggedPaths = flaggedResults.map(\.filePath)
        guard !flaggedPaths.isEmpty else {
            scanAlertText = "No flagged files to send to main app."
            return
        }

        NotificationCenter.default.post(
            name: queueMP4ValidationFlaggedFilesNotification,
            object: nil,
            userInfo: [queueMP4ValidationFlaggedFilesPathsKey: flaggedPaths]
        )
        scanAlertText = "Sent \(flaggedPaths.count) flagged file(s) to main app."
    }

    private func runScan(token: UUID) async {
        let files = collectMP4FilesRecursively(in: inputFolderPath)

        if files.isEmpty {
            scanProgress = "No MP4 files found in folder or subfolders."
            scanAlertText = ""
            isScanning = false
            return
        }

        for (index, fileInfo) in files.enumerated() {
            if Task.isCancelled || token != scanToken {
                scanProgress = "Validation canceled."
                isScanning = false
                return
            }

            scanProgress = "Validating \(index + 1)/\(files.count): \(fileInfo.relativePath)"

            let issue = await validationIssue(filePath: fileInfo.fullPath)
            results.append(
                MP4ValidationResult(
                    fileName: fileInfo.relativePath,
                    filePath: fileInfo.fullPath,
                    issue: issue
                )
            )
        }

        if token != scanToken {
            scanProgress = "Validation canceled."
            isScanning = false
            return
        }

        let flaggedCount = flaggedResults.count
        scanProgress = "Checked \(results.count) MP4 file(s)."

        var parts: [String] = []
        parts.append("Flagged file(s): \(flaggedCount)")
        if !ffprobeAvailable {
            parts.append("ffprobe not found; codec checks were skipped")
        }
        scanAlertText = parts.joined(separator: ". ") + "."

        isScanning = false
    }

    private func validationIssue(filePath: String) async -> String? {
        var reasons: [String] = []

        if ffprobeAvailable {
            if let hasAV1 = await hasAV1Video(filePath: filePath), hasAV1 {
                reasons.append("AV1 video")
            }

            if let hasDTS = await hasDTSAudio(filePath: filePath), hasDTS {
                reasons.append("DTS audio")
            }
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
        do {
            let isPlayable = try await asset.load(.isPlayable)
            if !isPlayable {
                reasons.append("not playable")
            }
        } catch {
            reasons.append("could not be opened")
        }

        guard !reasons.isEmpty else {
            return nil
        }

        return reasons.joined(separator: ", ")
    }

    private func hasAV1Video(filePath: String) async -> Bool? {
        let arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name",
            "-of", "default=noprint_wrappers=1:nokey=1",
            filePath
        ]

        guard let output = await runProcessCaptureStdout(path: ffprobePath, arguments: arguments) else {
            return nil
        }

        let codec = output
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard let codec else {
            return nil
        }

        return codec == "av1"
    }

    private func hasDTSAudio(filePath: String) async -> Bool? {
        let arguments = [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=codec_name",
            "-of", "default=noprint_wrappers=1:nokey=1",
            filePath
        ]

        guard let output = await runProcessCaptureStdout(path: ffprobePath, arguments: arguments) else {
            return nil
        }

        let codecs = output
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            .filter { !$0.isEmpty }

        return codecs.contains(where: { $0.contains("dts") || $0.contains("dca") })
    }

    private func collectMP4FilesRecursively(in rootPath: String) -> [(relativePath: String, fullPath: String)] {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        var files: [(relativePath: String, fullPath: String)] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "mp4" else {
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else {
                continue
            }

            let relativePath = fileURL.path.replacingOccurrences(of: rootPath + "/", with: "")
            files.append((relativePath: relativePath, fullPath: fileURL.path))
        }

        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private func runProcessCaptureStdout(path: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice

                do {
                    self.processLock.lock()
                    self.currentProcess = process
                    self.processLock.unlock()

                    try process.run()
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    self.processLock.lock()
                    if self.currentProcess === process {
                        self.currentProcess = nil
                    }
                    self.processLock.unlock()

                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: nil)
                        return
                    }

                    let output = String(data: outputData, encoding: .utf8)
                    continuation.resume(returning: output)
                } catch {
                    self.processLock.lock()
                    if self.currentProcess === process {
                        self.currentProcess = nil
                    }
                    self.processLock.unlock()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func terminateCurrentProcess() {
        processLock.lock()
        let process = currentProcess
        processLock.unlock()

        process?.terminate()
    }

    private func locateFFprobe() {
        if let bundledPath = Self.findBundledBinary(named: "ffprobe") {
            ffprobePath = bundledPath
            ffprobeAvailable = true
            return
        }

        if let systemPath = Self.findInPath(command: "ffprobe") {
            ffprobePath = systemPath
            ffprobeAvailable = true
            return
        }

        ffprobePath = ""
        ffprobeAvailable = false
    }

    private static func findBundledBinary(named name: String) -> String? {
        if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "bin") {
            let path = url.path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }

        if let url = Bundle.main.url(forResource: name, withExtension: nil) {
            let path = url.path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }

        let fallback = (Bundle.main.resourcePath ?? "") + "/bin/\(name)"
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    private static func findInPath(command: String) -> String? {
        let commonPaths = [
            "/usr/local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "/usr/bin/\(command)",
            "/bin/\(command)"
        ]

        for path in commonPaths where FileManager.default.fileExists(atPath: path) {
            return path
        }

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "which \(command)"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {
            return nil
        }

        return nil
    }

    private func makeHiddenChromeHostWindow() -> NSWindow {
        let size = NSSize(width: 640, height: 480)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2)
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovable = false
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        return window
    }
}
