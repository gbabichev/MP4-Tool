import Foundation
import AppKit
import Combine

struct SubtitleLanguageOption: Hashable {
    let code: String
    let name: String

    var label: String {
        "\(name) (\(code))"
    }
}

@MainActor
final class SubtitleMuxerViewModel: ObservableObject {
    @Published var inputMP4Path: String = ""
    @Published var inputSRTPath: String = ""
    @Published var outputFolderPath: String = ""
    @Published var outputFileName: String = ""
    @Published var selectedSubtitleLanguageCode: String = "eng"
    @Published var isMuxing = false
    @Published var showOverwriteConfirmation = false
    @Published var muxProgressFraction: Double = 0
    @Published var muxProgress = ""
    @Published var statusMessage = ""
    @Published var ffmpegAvailable = false
    @Published var isUsingSystemFFmpeg = false

    private var ffmpegPath: String = ""
    private var ffmpegMissingMessage = ""
    private var muxTask: Task<Void, Never>?
    private var progressMonitorTask: Task<Void, Never>?
    private var isProgressMonitoringActive = false
    private let processLock = NSLock()
    private nonisolated(unsafe) var currentProcess: Process?

    let subtitleLanguageOptions: [SubtitleLanguageOption] = [
        .init(code: "eng", name: "English"),
        .init(code: "spa", name: "Spanish"),
        .init(code: "fra", name: "French"),
        .init(code: "deu", name: "German"),
        .init(code: "ita", name: "Italian"),
        .init(code: "por", name: "Portuguese"),
        .init(code: "rus", name: "Russian"),
        .init(code: "jpn", name: "Japanese"),
        .init(code: "kor", name: "Korean"),
        .init(code: "zho", name: "Chinese"),
        .init(code: "ara", name: "Arabic"),
        .init(code: "hin", name: "Hindi"),
    ]

    init() {
        locateFFmpeg()
    }

    var canMux: Bool {
        guard !isMuxing, ffmpegAvailable else { return false }
        guard !inputMP4Path.isEmpty, !inputSRTPath.isEmpty, !outputFolderPath.isEmpty else { return false }
        return !sanitizedOutputFileName().isEmpty
    }

    var canCancelMux: Bool {
        isMuxing
    }

    var outputFileAlreadyExists: Bool {
        let path = resolvedOutputPath
        guard !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    var muxProgressPercentLabel: String {
        let clamped = max(0, min(1, muxProgressFraction))
        return "\(Int((clamped * 100).rounded()))%"
    }

    var ffmpegStatusLabel: String {
        if ffmpegAvailable {
            return isUsingSystemFFmpeg ? "FFmpeg: System" : "FFmpeg: Bundled"
        }
        return "FFmpeg: Not Available"
    }

    var resolvedOutputPath: String {
        let outputName = sanitizedOutputFileName()
        guard !outputFolderPath.isEmpty, !outputName.isEmpty else { return "" }
        return (outputFolderPath as NSString).appendingPathComponent(outputName)
    }

    func selectMP4File() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select an MP4 file"

        if panel.runModal() == .OK, let url = panel.url {
            guard url.pathExtension.lowercased() == "mp4" else {
                statusMessage = "Please select a .mp4 file."
                return
            }

            inputMP4Path = url.path
            outputFolderPath = url.deletingLastPathComponent().path

            outputFileName = AutomaticVideoFileNamer.suggestedOutputFileName(
                fromInputFileName: url.lastPathComponent,
                outputExtension: "mp4",
                fallbackSuffix: "_remux"
            )
        }
    }

    func selectSRTFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select an SRT subtitle file"

        if panel.runModal() == .OK, let url = panel.url {
            guard url.pathExtension.lowercased() == "srt" else {
                statusMessage = "Please select a .srt file."
                return
            }

            inputSRTPath = url.path
        }
    }

    func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select output folder for muxed file"

        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
        }
    }

    func openMP4InFinder() {
        guard !inputMP4Path.isEmpty else { return }
        let folderURL = URL(fileURLWithPath: inputMP4Path).deletingLastPathComponent()
        NSWorkspace.shared.open(folderURL)
    }

    func openSRTInFinder() {
        guard !inputSRTPath.isEmpty else { return }
        let folderURL = URL(fileURLWithPath: inputSRTPath).deletingLastPathComponent()
        NSWorkspace.shared.open(folderURL)
    }

    func openOutputFolderInFinder() {
        guard !outputFolderPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: outputFolderPath, isDirectory: true))
    }

    func startMux() {
        guard canMux else {
            return
        }
        if outputFileAlreadyExists {
            showOverwriteConfirmation = true
            return
        }
        startMux(overwriteExisting: false)
    }

    func confirmOverwriteAndStart() {
        guard canMux else { return }
        startMux(overwriteExisting: true)
    }

    private func startMux(overwriteExisting: Bool) {
        statusMessage = ""
        muxProgress = "Muxing..."
        muxProgressFraction = 0
        isMuxing = true

        muxTask?.cancel()
        muxTask = Task {
            await runMux(overwriteExisting: overwriteExisting)
        }
    }

    func cancelMux() {
        guard isMuxing else { return }
        muxTask?.cancel()
        stopProgressMonitoring()
        terminateCurrentProcess()
        muxProgress = "Mux canceled."
        isMuxing = false
    }

    private func runMux(overwriteExisting: Bool) async {
        guard ffmpegAvailable else {
            muxProgress = ""
            statusMessage = ffmpegMissingMessage
            isMuxing = false
            return
        }

        let outputPath = resolvedOutputPath
        guard !outputPath.isEmpty else {
            muxProgress = ""
            statusMessage = "Output file name is required."
            isMuxing = false
            return
        }

        guard overwriteExisting || !outputFileAlreadyExists else {
            muxProgress = ""
            statusMessage = "Output file already exists. Choose a different output file name or folder."
            isMuxing = false
            return
        }

        let expectedBytes = expectedOutputBytes()
        startProgressMonitoring(outputPath: outputPath, expectedBytes: expectedBytes)

        let arguments = [
            "-hide_banner",
            overwriteExisting ? "-y" : "-n",
            "-i", inputMP4Path,
            "-i", inputSRTPath,
            "-map", "0:v",
            "-map", "0:a?",
            "-map", "1:0",
            "-c:v", "copy",
            "-c:a", "copy",
            "-c:s", "mov_text",
            "-metadata:s:s:0", "language=\(selectedSubtitleLanguageCode)",
            outputPath
        ]

        let result = await runProcessCaptureStderr(path: ffmpegPath, arguments: arguments)
        stopProgressMonitoring()

        if Task.isCancelled {
            return
        }

        guard let result else {
            muxProgress = "Mux failed."
            statusMessage = "Unable to start ffmpeg."
            isMuxing = false
            return
        }

        if result.exitCode == 0 {
            muxProgress = "Mux complete."
            muxProgressFraction = 1
            statusMessage = "Created \(outputPath)."
        } else {
            muxProgress = "Mux failed."
            statusMessage = "FFmpeg failed: \(lastMeaningfulLine(in: result.stderr) ?? "Unknown error")"
        }

        isMuxing = false
    }

    private func sanitizedOutputFileName() -> String {
        var name = outputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return ""
        }
        if !name.lowercased().hasSuffix(".mp4") {
            name += ".mp4"
        }
        return name
    }

    private func lastMeaningfulLine(in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first(where: { !$0.isEmpty })
    }

    private func expectedOutputBytes() -> Int64 {
        max(1, fileSize(at: inputMP4Path) + fileSize(at: inputSRTPath))
    }

    private func fileSize(at path: String) -> Int64 {
        guard !path.isEmpty else { return 0 }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private func startProgressMonitoring(outputPath: String, expectedBytes: Int64) {
        progressMonitorTask?.cancel()
        isProgressMonitoringActive = true
        let monitorStart = Date()
        progressMonitorTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled && self.isMuxing && self.isProgressMonitoringActive {
                let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath)
                let currentSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let modifiedAt = attributes?[.modificationDate] as? Date

                // Ignore stale pre-existing output file metadata during overwrite startup.
                if modifiedAt == nil || (modifiedAt != nil && modifiedAt! >= monitorStart) {
                    let rawFraction = Double(currentSize) / Double(max(1, expectedBytes))
                    let boundedFraction = max(0, min(0.99, rawFraction))
                    if boundedFraction > self.muxProgressFraction {
                        self.muxProgressFraction = boundedFraction
                    }
                }

                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    private func stopProgressMonitoring() {
        isProgressMonitoringActive = false
        progressMonitorTask?.cancel()
        progressMonitorTask = nil
    }

    private func runProcessCaptureStderr(path: String, arguments: [String]) async -> (exitCode: Int32, stderr: String)? {
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

                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: errorData, encoding: .utf8) ?? ""

                    self.processLock.lock()
                    if self.currentProcess === process {
                        self.currentProcess = nil
                    }
                    self.processLock.unlock()

                    continuation.resume(returning: (process.terminationStatus, stderr))
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

    private func locateFFmpeg() {
        if let bundledPath = Self.findBundledBinary(named: "ffmpeg") {
            ffmpegPath = bundledPath
            ffmpegAvailable = true
            isUsingSystemFFmpeg = false
            return
        }

        if let systemPath = Self.findInPath(command: "ffmpeg") {
            ffmpegPath = systemPath
            ffmpegAvailable = true
            isUsingSystemFFmpeg = true
            return
        }

        ffmpegPath = ""
        ffmpegAvailable = false
        ffmpegMissingMessage = "Missing required tool: ffmpeg. Please install ffmpeg or bundle it with the app."
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

            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {
            return nil
        }

        return nil
    }
}
