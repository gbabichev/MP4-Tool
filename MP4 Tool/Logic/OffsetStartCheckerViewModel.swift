import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

let queueOffsetCheckerFailuresNotification = Notification.Name("MP4Tool.QueueOffsetCheckerFailures")
let queueOffsetCheckerFailuresPathsKey = "paths"

enum OffsetFixOutcome: String {
    case notAttempted
    case fixedByRemux
    case failedNeedsReencode
}

struct OffsetStartCheckResult: Identifiable {
    static let significantOffsetThresholdSeconds: Double = 0.50

    let id = UUID()
    let fileName: String
    let filePath: String
    let firstPTS: Double?
    let fixOutcome: OffsetFixOutcome

    init(
        fileName: String,
        filePath: String,
        firstPTS: Double?,
        fixOutcome: OffsetFixOutcome = .notAttempted
    ) {
        self.fileName = fileName
        self.filePath = filePath
        self.firstPTS = firstPTS
        self.fixOutcome = fixOutcome
    }

    var hasOffsetStart: Bool {
        guard let firstPTS else { return false }
        return abs(firstPTS) >= Self.significantOffsetThresholdSeconds
    }

    var needsTimingAttention: Bool {
        fixOutcome == .failedNeedsReencode || firstPTS == nil || hasOffsetStart
    }
}

@MainActor
final class OffsetStartCheckerViewModel: ObservableObject {
    private struct FileFixResult {
        let outcome: OffsetFixOutcome
        let resultingFirstPTS: Double?
    }

    @Published var inputFolderPath: String = ""
    @Published var isScanning = false
    @Published var isFixing = false
    @Published var hasCompletedFixPass = false
    @Published var scanProgress = ""
    @Published var fixProgress = ""
    @Published var scanAlertText = ""
    @Published var results: [OffsetStartCheckResult] = []
    @Published var operationProgressFraction: Double = 0
    @Published var operationCurrentItem = 0
    @Published var operationTotalItems = 0
    @Published var operationEstimatedRemaining: TimeInterval?
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

    var canFix: Bool {
        !isScanning && !isFixing && ffmpegAvailable && ffprobeAvailable && results.contains(where: { $0.hasOffsetStart })
    }

    var failureResults: [OffsetStartCheckResult] {
        results.filter(isFailureResult)
    }

    var actionRequiredResults: [OffsetStartCheckResult] {
        results.filter(isActionRequiredResult)
    }

    var canExportFailures: Bool {
        !isScanning && !isFixing && !failureResults.isEmpty
    }

    var canExportReport: Bool {
        !isScanning && !isFixing && !actionRequiredResults.isEmpty
    }

    var canExportAll: Bool {
        !isScanning && !isFixing && !results.isEmpty
    }

    var canSendFailuresToMainApp: Bool {
        !isScanning && !isFixing && hasCompletedFixPass && !failureResults.isEmpty
    }

    func selectInputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Select folder containing MP4 files to check"

        CleanFilePanelPresenter.present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.inputFolderPath = url.path
        }
    }

    func acceptInput(url: URL) {
        guard !isScanning, !isFixing else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue || url.pathExtension.lowercased() == "mp4" else {
            scanAlertText = "Choose an MP4 file or a folder containing MP4 files."
            return
        }

        inputFolderPath = url.path
        results = []
        scanProgress = ""
        fixProgress = ""
        scanAlertText = isDirectory.boolValue
            ? "Ready to scan this folder and its subfolders."
            : "Ready to inspect this MP4 file."
    }

    func openInputFolderInFinder() {
        guard !inputFolderPath.isEmpty else { return }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: inputFolderPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            NSWorkspace.shared.open(URL(fileURLWithPath: inputFolderPath, isDirectory: true))
        } else {
            NSWorkspace.shared.selectFile(
                inputFolderPath,
                inFileViewerRootedAtPath: URL(fileURLWithPath: inputFolderPath)
                    .deletingLastPathComponent().path
            )
        }
    }

    func scanOffsetStarts() {
        guard canScan else { return }
        hasCompletedFixPass = false
        results = []
        scanProgress = "Preparing scan..."
        fixProgress = ""
        scanAlertText = ""
        resetOperationProgress()
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

    func fixOffsetStartsInPlace(resultIDs: Set<UUID>) {
        guard canFix, !resultIDs.isEmpty else { return }
        fixProgress = "Preparing fixes..."
        scanAlertText = ""
        resetOperationProgress()
        isFixing = true

        fixTask?.cancel()
        fixToken = UUID()
        let token = fixToken
        fixTask = Task {
            await runFix(token: token, resultIDs: resultIDs)
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

    func resetAll() {
        scanTask?.cancel()
        fixTask?.cancel()
        scanToken = UUID()
        fixToken = UUID()
        terminateCurrentProcess()
        inputFolderPath = ""
        results = []
        scanProgress = ""
        fixProgress = ""
        scanAlertText = ""
        hasCompletedFixPass = false
        isScanning = false
        isFixing = false
        resetOperationProgress()
    }

    func removeResult(id: UUID) {
        guard !isScanning && !isFixing else { return }
        results.removeAll { $0.id == id }
    }

    func exportFailuresToFile() {
        let failedPaths = failureResults.map(\.filePath)
        guard !failedPaths.isEmpty else {
            scanAlertText = "No failures to export."
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "offset-failures.txt"

        CleanFilePanelPresenter.present(panel) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                guard response == .OK, let url = panel.url else {
                    return
                }

                let body = failedPaths.joined(separator: "\n")
                do {
                    try body.write(to: url, atomically: true, encoding: .utf8)
                    self.scanAlertText = "Exported \(failedPaths.count) failure path(s) to \(url.path)."
                } catch {
                    self.scanAlertText = "Failed to export failures: \(error.localizedDescription)"
                }
            }
        }
    }

    func exportCSVReport(includeAll: Bool) {
        let sourceResults = includeAll ? results : actionRequiredResults
        let reportRows = sourceResults.map { result in
            (
                itemName: URL(fileURLWithPath: result.filePath).lastPathComponent,
                path: result.filePath,
                issue: result.needsTimingAttention ? timingIssueDescription(for: result) : ""
            )
        }
        guard !reportRows.isEmpty else {
            scanAlertText = includeAll ? "No results to export." : "No timing issues to export."
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = includeAll
            ? "mp4-timing-all.csv" : "mp4-timing-issues.csv"

        CleanFilePanelPresenter.present(panel) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                guard response == .OK, let url = panel.url else { return }

                let header = ["Item Name", "Path", "Timing Issue"]
                    .map(self.csvField).joined(separator: ",")
                let rows = reportRows.map { row in
                    [row.itemName, row.path, row.issue]
                        .map(self.csvField).joined(separator: ",")
                }
                let body = "\u{FEFF}" + ([header] + rows).joined(separator: "\r\n") + "\r\n"

                do {
                    try body.write(to: url, atomically: true, encoding: .utf8)
                    let scope = includeAll ? "result" : "issue"
                    self.scanAlertText = "Exported \(reportRows.count) timing \(scope)(s) to \(url.path)."
                } catch {
                    self.scanAlertText = "Failed to export CSV report: \(error.localizedDescription)"
                }
            }
        }
    }

    func sendFailuresToMainApp() {
        let failedPaths = failureResults.map(\.filePath)
        guard !failedPaths.isEmpty else {
            scanAlertText = "No failed files to send to main app."
            return
        }

        NotificationCenter.default.post(
            name: queueOffsetCheckerFailuresNotification,
            object: nil,
            userInfo: [queueOffsetCheckerFailuresPathsKey: failedPaths]
        )
        scanAlertText = "Sent \(failedPaths.count) failed file(s) to main app."
    }

    private func runScan(token: UUID) async {
        let sleepAssertion = SystemSleepAssertion(reason: "MP4 Tool is scanning video start offsets")
        defer { sleepAssertion.invalidate() }

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

        let operationStartedAt = Date()
        resetOperationProgress(totalItems: videoFiles.count)
        for (index, fileInfo) in videoFiles.enumerated() {
            if Task.isCancelled || token != scanToken {
                scanProgress = "Scan canceled."
                isScanning = false
                return
            }

            updateOperationProgress(
                currentItem: index + 1,
                totalItems: videoFiles.count,
                startedAt: operationStartedAt
            )
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

    private func runFix(token: UUID, resultIDs: Set<UUID>) async {
        let sleepAssertion = SystemSleepAssertion(reason: "MP4 Tool is repairing video start offsets")
        defer { sleepAssertion.invalidate() }

        guard ffmpegAvailable && ffprobeAvailable else {
            scanAlertText = ffmpegAvailable ? ffprobeMissingMessage : ffmpegMissingMessage
            fixProgress = ""
            isFixing = false
            return
        }

        let targets = results.filter { resultIDs.contains($0.id) && $0.hasOffsetStart }
        if targets.isEmpty {
            fixProgress = ""
            scanAlertText = "No offset starts to fix."
            isFixing = false
            return
        }

        var fixedByRemuxCount = 0
        var failedNeedsReencode: [String] = []
        var outcomeByPath: [String: OffsetFixOutcome] = [:]
        var resultingPTSByPath: [String: Double] = [:]
        let operationStartedAt = Date()
        resetOperationProgress(totalItems: targets.count)

        for (index, result) in targets.enumerated() {
            if Task.isCancelled || token != fixToken {
                fixProgress = "Fix canceled."
                isFixing = false
                return
            }

            updateOperationProgress(
                currentItem: index + 1,
                totalItems: targets.count,
                startedAt: operationStartedAt
            )
            fixProgress = "Fixing \(index + 1)/\(targets.count): \(result.fileName)"

            let fixResult = await fixOffsetForFileInPlace(
                filePath: result.filePath
            )
            outcomeByPath[result.filePath] = fixResult.outcome
            if let resultingFirstPTS = fixResult.resultingFirstPTS {
                resultingPTSByPath[result.filePath] = resultingFirstPTS
            }

            switch fixResult.outcome {
            case .fixedByRemux:
                fixedByRemuxCount += 1
            case .failedNeedsReencode:
                failedNeedsReencode.append(result.fileName)
            case .notAttempted:
                failedNeedsReencode.append(result.fileName)
            }
        }

        if token != fixToken {
            fixProgress = "Fix canceled."
            isFixing = false
            return
        }

        // Apply outcomes and known post-fix pts values from each remux attempt.
        for index in results.indices {
            let filePath = results[index].filePath
            let existing = results[index]
            results[index] = OffsetStartCheckResult(
                fileName: existing.fileName,
                filePath: existing.filePath,
                firstPTS: resultingPTSByPath[filePath] ?? existing.firstPTS,
                fixOutcome: outcomeByPath[filePath] ?? existing.fixOutcome
            )
        }

        fixProgress = "Fix complete."
        var statusParts: [String] = []
        statusParts.append("Checked \(results.count) file(s)")
        statusParts.append("Processed \(targets.count) file(s)")
        statusParts.append("Fixed \(fixedByRemuxCount) file(s)")

        if !failedNeedsReencode.isEmpty {
            statusParts.append("FAIL: Please Re-Encode: \(failedNeedsReencode.count)")
        }

        scanAlertText = statusParts.joined(separator: ". ") + "."
        hasCompletedFixPass = true
        isFixing = false
    }

    private func resetOperationProgress(totalItems: Int = 0) {
        operationProgressFraction = 0
        operationCurrentItem = 0
        operationTotalItems = totalItems
        operationEstimatedRemaining = nil
    }

    private func updateOperationProgress(currentItem: Int, totalItems: Int, startedAt: Date) {
        operationCurrentItem = currentItem
        operationTotalItems = totalItems
        operationProgressFraction = totalItems > 0 ? Double(currentItem) / Double(totalItems) : 0

        let completedBeforeCurrent = currentItem - 1
        guard completedBeforeCurrent > 0 else {
            operationEstimatedRemaining = nil
            return
        }
        let averageDuration = Date().timeIntervalSince(startedAt) / Double(completedBeforeCurrent)
        operationEstimatedRemaining = averageDuration * Double(totalItems - completedBeforeCurrent)
    }

    private func fixOffsetForFileInPlace(filePath: String) async -> FileFixResult {
        await attemptRemuxFix(filePath: filePath)
    }

    private func attemptRemuxFix(filePath: String) async -> FileFixResult {
        let originalURL = URL(fileURLWithPath: filePath)
        let tmpURL = temporaryOutputURL(for: originalURL, suffix: "remux")

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
            return FileFixResult(outcome: .failedNeedsReencode, resultingFirstPTS: nil)
        }

        guard let remuxedFirstPTS = await firstVideoPacketPTS(filePath: tmpURL.path) else {
            try? FileManager.default.removeItem(at: tmpURL)
            return FileFixResult(outcome: .failedNeedsReencode, resultingFirstPTS: nil)
        }

        let remuxedMagnitude = abs(remuxedFirstPTS)

        guard remuxedMagnitude < OffsetStartCheckResult.significantOffsetThresholdSeconds else {
            try? FileManager.default.removeItem(at: tmpURL)
            return FileFixResult(outcome: .failedNeedsReencode, resultingFirstPTS: nil)
        }

        do {
            _ = try FileManager.default.replaceItemAt(originalURL, withItemAt: tmpURL)
            return FileFixResult(outcome: .fixedByRemux, resultingFirstPTS: remuxedFirstPTS)
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return FileFixResult(outcome: .failedNeedsReencode, resultingFirstPTS: nil)
        }
    }

    private func temporaryOutputURL(for originalURL: URL, suffix: String) -> URL {
        let folderURL = originalURL.deletingLastPathComponent()
        let baseName = originalURL.deletingPathExtension().lastPathComponent
        let name = "\(baseName).offsetfix.\(suffix).\(UUID().uuidString).mp4"
        return folderURL.appendingPathComponent(name)
    }

    private func isFailureResult(_ result: OffsetStartCheckResult) -> Bool {
        if result.fixOutcome == .failedNeedsReencode {
            return true
        }

        if result.firstPTS == nil {
            return true
        }

        return false
    }

    private func isActionRequiredResult(_ result: OffsetStartCheckResult) -> Bool {
        if isFailureResult(result) {
            return true
        }

        if result.hasOffsetStart {
            return true
        }

        return false
    }

    private func timingIssueDescription(for result: OffsetStartCheckResult) -> String {
        if result.fixOutcome == .failedNeedsReencode {
            return "Timing repair failed; full re-encode required"
        }
        guard let firstPTS = result.firstPTS else {
            return "Unable to read the first video packet timestamp"
        }
        return String(format: "Video starts at %.3f seconds", firstPTS)
    }

    private func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func collectVideoFilesRecursively(in rootPath: String) -> [(relativePath: String, fullPath: String)] {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            let url = URL(fileURLWithPath: rootPath)
            guard url.pathExtension.lowercased() == "mp4" else { return [] }
            return [(relativePath: url.lastPathComponent, fullPath: rootPath)]
        }

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

    private func runProcess(path: String, arguments: [String]) async -> Int32? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

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
