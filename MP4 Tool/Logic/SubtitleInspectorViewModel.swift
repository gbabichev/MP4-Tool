import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

private struct SubtitleInspectorProbeOutput: Decodable {
    let streams: [SubtitleInspectorProbeStream]
}

private struct SubtitleInspectorProbeStream: Decodable {
    let index: Int
    let tags: [String: String]?
}

private nonisolated final class SubtitleInspectorProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var outputData = Data()
    private var errorData = Data()

    func appendOutput(_ data: Data) {
        lock.lock()
        outputData.append(data)
        lock.unlock()
    }

    func appendError(_ data: Data) {
        lock.lock()
        errorData.append(data)
        lock.unlock()
    }

    func result(exitCode: Int32) -> (exitCode: Int32, stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        return (
            exitCode,
            String(data: outputData, encoding: .utf8) ?? "",
            String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}

enum SubtitleInspectionStatus {
    case subtitlesPresent(totalCount: Int, englishCount: Int, requiresEnglish: Bool)
    case missing
    case unreadable
}

struct SubtitleInspectionResult: Identifiable {
    let id = UUID()
    let filePath: String
    let status: SubtitleInspectionStatus

    var needsAttention: Bool {
        switch status {
        case .subtitlesPresent(_, let englishCount, let requiresEnglish):
            requiresEnglish && englishCount == 0
        case .missing, .unreadable: true
        }
    }

    var issue: String {
        switch status {
        case .subtitlesPresent(let totalCount, let englishCount, let requiresEnglish):
            if requiresEnglish {
                guard englishCount > 0 else {
                    return "Subtitle tracks exist, but none are tagged English"
                }
                return "\(englishCount) English subtitle track\(englishCount == 1 ? "" : "s") (\(totalCount) total)"
            }
            return "\(totalCount) subtitle track\(totalCount == 1 ? "" : "s")"
        case .missing:
            return "No subtitle tracks found"
        case .unreadable:
            return "Unable to inspect subtitle tracks"
        }
    }
}

@MainActor
final class SubtitleInspectorViewModel: ObservableObject {
    @Published var inputPath = ""
    @Published var inputIsFolder = false
    @Published var isScanning = false
    @Published var statusMessage = ""
    @Published var results: [SubtitleInspectionResult] = []
    @Published var operationProgressFraction: Double = 0
    @Published var operationCurrentItem = 0
    @Published var operationTotalItems = 0
    @Published var operationEstimatedRemaining: TimeInterval?

    private var ffprobePath = ""
    private var scanTask: Task<Void, Never>?
    private let processLock = NSLock()
    private nonisolated(unsafe) var currentProcess: Process?

    var canScan: Bool { !inputPath.isEmpty && !ffprobePath.isEmpty && !isScanning }
    var attentionResults: [SubtitleInspectionResult] { results.filter(\.needsAttention) }
    var canExport: Bool { !results.isEmpty && !isScanning }
    var canExportIssues: Bool { !attentionResults.isEmpty && !isScanning }

    init() {
        ffprobePath = Self.findExecutable(named: "ffprobe") ?? ""
    }

    func acceptInput(url: URL) {
        guard !isScanning else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue || url.pathExtension.lowercased() == "mp4" else {
            statusMessage = "Choose an MP4 file or a folder containing MP4 files."
            return
        }
        inputPath = url.path
        inputIsFolder = isDirectory.boolValue
        results = []
        statusMessage = inputIsFolder
            ? "Ready to scan this folder and its subfolders."
            : "Ready to inspect this MP4 file."
    }

    func scan(requireEnglish: Bool) {
        guard canScan else { return }
        results = []
        statusMessage = inputIsFolder ? "Discovering MP4 files…" : "Preparing MP4 file…"
        resetOperationProgress()
        isScanning = true
        scanTask?.cancel()
        scanTask = Task { await runScan(requireEnglish: requireEnglish) }
    }

    func resetResultsForOptionChange() {
        guard !isScanning else { return }
        results = []
        statusMessage = inputPath.isEmpty
            ? ""
            : "Scan option changed. Run a new subtitle scan."
    }

    func cancel() {
        guard isScanning else { return }
        scanTask?.cancel()
        terminateCurrentProcess()
        statusMessage = "Scan canceled."
        isScanning = false
    }

    func resetAll() {
        scanTask?.cancel()
        terminateCurrentProcess()
        inputPath = ""
        inputIsFolder = false
        results = []
        statusMessage = ""
        isScanning = false
        resetOperationProgress()
    }

    func removeResult(id: UUID) {
        guard !isScanning else { return }
        results.removeAll { $0.id == id }
    }

    func exportCSV(includeAll: Bool) {
        let sourceResults = includeAll ? results : attentionResults
        let reportRows = sourceResults.map {
            (
                itemName: URL(fileURLWithPath: $0.filePath).lastPathComponent,
                path: $0.filePath,
                issue: $0.issue
            )
        }
        guard !reportRows.isEmpty else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = includeAll
            ? "mp4-subtitles-all.csv" : "mp4-subtitles-issues.csv"
        CleanFilePanelPresenter.present(panel) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                guard response == .OK, let url = panel.url else { return }

                let header = ["Item Name", "Path", "Subtitle Issue"]
                    .map(self.csvField).joined(separator: ",")
                let rows = reportRows.map { row in
                    [row.itemName, row.path, row.issue]
                        .map(self.csvField).joined(separator: ",")
                }
                let body = "\u{FEFF}" + ([header] + rows).joined(separator: "\r\n") + "\r\n"
                do {
                    try body.write(to: url, atomically: true, encoding: .utf8)
                    let scope = includeAll ? "result" : "issue"
                    self.statusMessage = "Exported \(reportRows.count) subtitle \(scope)(s) to \(url.path)."
                } catch {
                    self.statusMessage = "Failed to export CSV report: \(error.localizedDescription)"
                }
            }
        }
    }

    private func runScan(requireEnglish: Bool) async {
        let assertion = SystemSleepAssertion(reason: "MP4 Tool is inspecting subtitle tracks")
        defer { assertion.invalidate() }

        let selectedPath = inputPath
        let selectedIsFolder = inputIsFolder
        let files = await Task.detached(priority: .userInitiated) {
            Self.collectFiles(inputPath: selectedPath, inputIsFolder: selectedIsFolder)
        }.value
        guard !Task.isCancelled else { return }
        guard !files.isEmpty else {
            statusMessage = "No MP4 files were found."
            isScanning = false
            return
        }

        let startedAt = Date()
        resetOperationProgress(totalItems: files.count)
        for (index, filePath) in files.enumerated() {
            guard !Task.isCancelled else { return }
            updateOperationProgress(
                currentItem: index + 1,
                totalItems: files.count,
                startedAt: startedAt
            )
            statusMessage = "Scanning \(index + 1) of \(files.count): \(URL(fileURLWithPath: filePath).lastPathComponent)"
            let status = await subtitleStatus(filePath: filePath, requireEnglish: requireEnglish)
            results.append(SubtitleInspectionResult(filePath: filePath, status: status))
        }

        guard !Task.isCancelled else { return }
        let missingCount = results.filter {
            if case .missing = $0.status { return true }
            return false
        }.count
        let unreadableCount = results.filter {
            if case .unreadable = $0.status { return true }
            return false
        }.count
        let noEnglishCount = results.filter {
            if case .subtitlesPresent(_, let englishCount, true) = $0.status {
                return englishCount == 0
            }
            return false
        }.count
        statusMessage = "Checked \(results.count) MP4 file(s). \(missingCount) have no subtitles."
        if requireEnglish {
            statusMessage += " \(noEnglishCount) have subtitles but none tagged English."
        }
        if unreadableCount > 0 {
            statusMessage += " \(unreadableCount) could not be inspected."
        }
        isScanning = false
    }

    private func subtitleStatus(
        filePath: String,
        requireEnglish: Bool
    ) async -> SubtitleInspectionStatus {
        guard let result = await runProcess(path: ffprobePath, arguments: [
            "-v", "error",
            "-select_streams", "s",
            "-show_entries", "stream=index:stream_tags=language",
            "-print_format", "json",
            filePath
        ]), result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let output = try? JSONDecoder().decode(SubtitleInspectorProbeOutput.self, from: data) else {
            return .unreadable
        }
        guard !output.streams.isEmpty else { return .missing }
        let englishCount = output.streams.filter { stream in
            guard let language = stream.tags?.first(where: {
                $0.key.caseInsensitiveCompare("language") == .orderedSame
            })?.value.lowercased() else { return false }
            return ["eng", "en", "english"].contains(language)
                || language.hasPrefix("en-")
                || language.hasPrefix("en_")
        }.count
        return .subtitlesPresent(
            totalCount: output.streams.count,
            englishCount: englishCount,
            requiresEnglish: requireEnglish
        )
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

    private func runProcess(
        path: String,
        arguments: [String]
    ) async -> (exitCode: Int32, stdout: String, stderr: String)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let capture = SubtitleInspectorProcessCapture()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                outputPipe.fileHandleForReading.readabilityHandler = { capture.appendOutput($0.availableData) }
                errorPipe.fileHandleForReading.readabilityHandler = { capture.appendError($0.availableData) }
                do {
                    self.processLock.lock()
                    self.currentProcess = process
                    self.processLock.unlock()
                    try process.run()
                    process.waitUntilExit()
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    capture.appendOutput(outputPipe.fileHandleForReading.readDataToEndOfFile())
                    capture.appendError(errorPipe.fileHandleForReading.readDataToEndOfFile())
                    self.processLock.lock()
                    if self.currentProcess === process { self.currentProcess = nil }
                    self.processLock.unlock()
                    continuation.resume(returning: capture.result(exitCode: process.terminationStatus))
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    self.processLock.lock()
                    if self.currentProcess === process { self.currentProcess = nil }
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

    private func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private nonisolated static func collectFiles(
        inputPath: String,
        inputIsFolder: Bool
    ) -> [String] {
        if !inputIsFolder {
            return [inputPath]
        }
        let rootURL = URL(fileURLWithPath: inputPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [String] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "mp4" {
            if Task.isCancelled { return [] }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            files.append(url.path)
        }
        return files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private nonisolated static func findExecutable(named name: String) -> String? {
        if let bundled = Bundle.main.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "bin"
        )?.path, FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
