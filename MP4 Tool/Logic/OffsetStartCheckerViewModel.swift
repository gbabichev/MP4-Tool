import Foundation
import AppKit
import SwiftUI
import Combine

struct OffsetStartCheckResult: Identifiable {
    static let significantOffsetThresholdSeconds: Double = 0.50

    let id = UUID()
    let fileName: String
    let filePath: String
    let firstPTS: Double?

    var hasOffsetStart: Bool {
        guard let firstPTS else { return false }
        return abs(firstPTS) >= Self.significantOffsetThresholdSeconds
    }
}

@MainActor
final class OffsetStartCheckerViewModel: ObservableObject {
    @Published var inputFolderPath: String = ""
    @Published var isScanning = false
    @Published var isFixing = false
    @Published var scanProgress = ""
    @Published var fixProgress = ""
    @Published var scanAlertText = ""
    @Published var results: [OffsetStartCheckResult] = []
    @Published var ffprobeAvailable = false
    @Published var ffmpegAvailable = false

    private var ffprobePath: String = ""
    private var ffprobeMissingMessage = ""
    private var ffmpegPath: String = ""
    private var ffmpegMissingMessage = ""
    private var scanTask: Task<Void, Never>?
    private var fixTask: Task<Void, Never>?
    private let processLock = NSLock()
    private nonisolated(unsafe) var currentProcess: Process?
    private var scanToken = UUID()
    private var fixToken = UUID()

    init() {
        locateTools()
    }

    var canScan: Bool {
        !inputFolderPath.isEmpty && ffprobeAvailable && !isScanning && !isFixing
    }

    var canCancelScan: Bool {
        isScanning
    }

    var canFix: Bool {
        !isScanning && !isFixing && ffmpegAvailable && results.contains(where: { $0.hasOffsetStart })
    }

    var canCancelFix: Bool {
        isFixing
    }

    var ffprobeStatusLabel: String {
        ffprobeAvailable ? "FFprobe: Available" : "FFprobe: Not Available"
    }

    var ffmpegStatusLabel: String {
        ffmpegAvailable ? "FFmpeg: Available" : "FFmpeg: Not Available"
    }

    func selectInputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Select folder containing MP4 files to check"

        if panel.runModal() == .OK, let url = panel.url {
            inputFolderPath = url.path
        }
    }

    func scanOffsetStarts() {
        guard canScan else { return }
        results = []
        scanProgress = "Preparing scan..."
        fixProgress = ""
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
        scanProgress = "Scan canceled."
        isScanning = false
    }

    func fixOffsetStartsInPlace() {
        guard canFix else { return }
        fixProgress = "Preparing fixes..."
        scanAlertText = ""
        isFixing = true

        fixTask?.cancel()
        fixToken = UUID()
        let token = fixToken
        fixTask = Task {
            await runFix(token: token)
        }
    }

    func cancelFix() {
        guard isFixing else { return }
        fixTask?.cancel()
        fixToken = UUID()
        terminateCurrentProcess()
        fixProgress = "Fix canceled."
        isFixing = false
    }

    private func runScan(token: UUID) async {
        guard ffprobeAvailable else {
            scanAlertText = ffprobeMissingMessage
            scanProgress = ""
            isScanning = false
            return
        }

        let videoFiles = collectVideoFilesRecursively(in: inputFolderPath)

        if videoFiles.isEmpty {
            scanProgress = "No MP4 files found in folder or subfolders."
            scanAlertText = ""
            isScanning = false
            return
        }

        for (index, fileInfo) in videoFiles.enumerated() {
            if Task.isCancelled || token != scanToken {
                scanProgress = "Scan canceled."
                isScanning = false
                return
            }

            scanProgress = "Checking \(index + 1)/\(videoFiles.count): \(fileInfo.relativePath)"
            let filePath = fileInfo.fullPath
            let firstPTS = await firstVideoPacketPTS(filePath: filePath)
            let result = OffsetStartCheckResult(fileName: fileInfo.relativePath, filePath: filePath, firstPTS: firstPTS)
            results.append(result)
        }

        if token != scanToken {
            scanProgress = "Scan canceled."
            isScanning = false
            return
        }

        let offsetCount = results.filter { $0.hasOffsetStart }.count
        let unreadableCount = results.filter { $0.firstPTS == nil }.count

        scanProgress = "Checked \(results.count) file(s)."
        if unreadableCount > 0 {
            scanAlertText = "\(offsetCount) significant offset start(s) (>= \(OffsetStartCheckResult.significantOffsetThresholdSeconds)s), \(unreadableCount) unreadable file(s)."
        } else if offsetCount > 0 {
            scanAlertText = "\(offsetCount) file(s) start with significant non-zero pts_time (>= \(OffsetStartCheckResult.significantOffsetThresholdSeconds)s)."
        } else {
            scanAlertText = "No significant offsets found (threshold: \(OffsetStartCheckResult.significantOffsetThresholdSeconds)s)."
        }

        isScanning = false
    }

    private func runFix(token: UUID) async {
        guard ffmpegAvailable else {
            scanAlertText = ffmpegMissingMessage
            fixProgress = ""
            isFixing = false
            return
        }

        let targets = results.filter { $0.hasOffsetStart }
        if targets.isEmpty {
            fixProgress = ""
            scanAlertText = "No offset starts to fix."
            isFixing = false
            return
        }

        var replacedCount = 0
        var failedFiles: [String] = []

        for (index, result) in targets.enumerated() {
            if Task.isCancelled || token != fixToken {
                fixProgress = "Fix canceled."
                isFixing = false
                return
            }

            fixProgress = "Fixing \(index + 1)/\(targets.count): \(result.fileName)"

            if await fixOffsetForFileInPlace(filePath: result.filePath) {
                replacedCount += 1
            } else {
                failedFiles.append(result.fileName)
            }
        }

        if token != fixToken {
            fixProgress = "Fix canceled."
            isFixing = false
            return
        }

        // Refresh pts values after replacements so the list reflects current state.
        for index in results.indices {
            let filePath = results[index].filePath
            let refreshedPTS = await firstVideoPacketPTS(filePath: filePath)
            let existing = results[index]
            results[index] = OffsetStartCheckResult(
                fileName: existing.fileName,
                filePath: existing.filePath,
                firstPTS: refreshedPTS
            )
        }

        let remainingOffsets = results.filter { $0.hasOffsetStart }.count
        fixProgress = "Fix complete."
        if failedFiles.isEmpty {
            scanAlertText = "Replaced \(replacedCount) file(s) in place. Remaining offset starts: \(remainingOffsets)."
        } else {
            scanAlertText = "Replaced \(replacedCount) file(s). Failed: \(failedFiles.count). Remaining offset starts: \(remainingOffsets)."
        }
        isFixing = false
    }

    private func fixOffsetForFileInPlace(filePath: String) async -> Bool {
        let originalURL = URL(fileURLWithPath: filePath)
        let folderURL = originalURL.deletingLastPathComponent()
        let tmpName = originalURL.deletingPathExtension().lastPathComponent + ".offsetfix.\(UUID().uuidString).mp4"
        let tmpURL = folderURL.appendingPathComponent(tmpName)

        let arguments = [
            "-i", filePath,
            "-map", "0",
            "-c", "copy",
            "-avoid_negative_ts", "make_zero",
            "-y",
            "-loglevel", "quiet",
            tmpURL.path
        ]

        let exitCode = await runProcess(path: ffmpegPath, arguments: arguments)
        guard exitCode == 0 else {
            try? FileManager.default.removeItem(at: tmpURL)
            return false
        }

        do {
            _ = try FileManager.default.replaceItemAt(originalURL, withItemAt: tmpURL)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return false
        }
    }

    private func collectVideoFilesRecursively(in rootPath: String) -> [(relativePath: String, fullPath: String)] {
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

    private func firstVideoPacketPTS(filePath: String) async -> Double? {
        let arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "packet=pts_time",
            "-read_intervals", "%+#1",
            "-of", "default=noprint_wrappers=1:nokey=1",
            filePath
        ]

        guard let output = await runProcessCaptureStdout(path: ffprobePath, arguments: arguments) else {
            return nil
        }

        let firstLine = output
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let firstLine, !firstLine.isEmpty else {
            return nil
        }

        return Double(firstLine)
    }

    private func runProcessCaptureStdout(path: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    self.processLock.lock()
                    self.currentProcess = process
                    self.processLock.unlock()

                    try process.run()
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

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
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

    private func runProcess(path: String, arguments: [String]) async -> Int32? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = Pipe()
                process.standardError = Pipe()

                do {
                    self.processLock.lock()
                    self.currentProcess = process
                    self.processLock.unlock()

                    try process.run()
                    process.waitUntilExit()

                    self.processLock.lock()
                    if self.currentProcess === process {
                        self.currentProcess = nil
                    }
                    self.processLock.unlock()

                    continuation.resume(returning: process.terminationStatus)
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

    private func locateTools() {
        if let bundledPath = Self.findBundledBinary(named: "ffprobe") {
            ffprobePath = bundledPath
            ffprobeAvailable = true
        } else if let systemPath = Self.findInPath(command: "ffprobe") {
            ffprobePath = systemPath
            ffprobeAvailable = true
        } else {
            ffprobeAvailable = false
            ffprobeMissingMessage = "Missing required tool: ffprobe. Please install ffprobe or bundle it with the app."
        }

        if let bundledPath = Self.findBundledBinary(named: "ffmpeg") {
            ffmpegPath = bundledPath
            ffmpegAvailable = true
        } else if let systemPath = Self.findInPath(command: "ffmpeg") {
            ffmpegPath = systemPath
            ffmpegAvailable = true
        } else {
            ffmpegAvailable = false
            ffmpegMissingMessage = "Missing required tool: ffmpeg. Please install ffmpeg or bundle it with the app."
        }
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
}
