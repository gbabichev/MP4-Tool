import Foundation
import AppKit
import SwiftUI
import Combine

struct OffsetStartCheckResult: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let firstPTS: Double?

    var hasOffsetStart: Bool {
        guard let firstPTS else { return false }
        return abs(firstPTS) > 0.0001
    }
}

@MainActor
final class OffsetStartCheckerViewModel: ObservableObject {
    @Published var inputFolderPath: String = ""
    @Published var isScanning = false
    @Published var scanProgress = ""
    @Published var scanAlertText = ""
    @Published var results: [OffsetStartCheckResult] = []
    @Published var ffprobeAvailable = false

    private var ffprobePath: String = ""
    private var ffprobeMissingMessage = ""
    private var scanTask: Task<Void, Never>?
    private let processLock = NSLock()
    private nonisolated(unsafe) var currentScanProcess: Process?
    private var scanToken = UUID()

    init() {
        locateFFprobe()
    }

    var canScan: Bool {
        !inputFolderPath.isEmpty && ffprobeAvailable && !isScanning
    }

    var canCancelScan: Bool {
        isScanning
    }

    var ffprobeStatusLabel: String {
        ffprobeAvailable ? "FFprobe: Available" : "FFprobe: Not Available"
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
        terminateCurrentScanProcess()
        scanProgress = "Scan canceled."
        isScanning = false
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
            scanAlertText = "\(offsetCount) offset start(s), \(unreadableCount) unreadable file(s)."
        } else if offsetCount > 0 {
            scanAlertText = "\(offsetCount) file(s) start with non-zero pts_time."
        } else {
            scanAlertText = "All checked files start at pts_time 0."
        }

        isScanning = false
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
                    self.currentScanProcess = process
                    self.processLock.unlock()

                    try process.run()
                    process.waitUntilExit()

                    self.processLock.lock()
                    if self.currentScanProcess === process {
                        self.currentScanProcess = nil
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
                    if self.currentScanProcess === process {
                        self.currentScanProcess = nil
                    }
                    self.processLock.unlock()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func terminateCurrentScanProcess() {
        processLock.lock()
        let process = currentScanProcess
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

        ffprobeAvailable = false
        ffprobeMissingMessage = "Missing required tool: ffprobe. Please install ffprobe or bundle it with the app."
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
