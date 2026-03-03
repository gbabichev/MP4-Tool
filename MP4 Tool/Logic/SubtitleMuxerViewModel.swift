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

    private static let seasonEpisodeRegex = try! NSRegularExpression(
        pattern: #"(?i)\bS\s*(\d{1,2})\s*[\.\-_\s]*E\s*(\d{1,2})\b"#
    )
    private static let seasonXEpisodeRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(\d{1,2})x(\d{1,2})\b"#
    )
    private static let yearRegex = try! NSRegularExpression(
        pattern: #"\b(19\d{2}|20\d{2}|21\d{2})\b"#
    )
    private static let metadataTokens: Set<String> = [
        "10bit", "2160p", "1080p", "720p", "480p", "4k", "8k",
        "aac", "atmos", "bdrip", "bluray", "brip", "brrip", "cam", "ddp5", "ddp51", "dd51",
        "dvdrip", "h264", "h265", "hdr", "hdr10", "hdrip", "hevc", "proper", "repack", "remux",
        "uhd", "web", "webdl", "webrip", "x264", "x265", "yts"
    ]

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

            let baseName = url.deletingPathExtension().lastPathComponent
            outputFileName = suggestedOutputFileName(from: baseName)
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

    private func suggestedBaseName(from rawBaseName: String) -> String? {
        if let showName = suggestedTVShowBaseName(from: rawBaseName) {
            return showName
        }

        if let movieName = suggestedMovieBaseName(from: rawBaseName) {
            return movieName
        }

        return nil
    }

    private func suggestedOutputFileName(from rawBaseName: String) -> String {
        if let suggestedBase = suggestedBaseName(from: rawBaseName), !suggestedBase.isEmpty {
            return "\(suggestedBase).mp4"
        }
        return "\(rawBaseName)_remux.mp4"
    }

    private func suggestedTVShowBaseName(from rawBaseName: String) -> String? {
        let nsRaw = rawBaseName as NSString
        let fullRange = NSRange(location: 0, length: nsRaw.length)

        if let match = Self.seasonEpisodeRegex.firstMatch(in: rawBaseName, options: [], range: fullRange) {
            return formattedShowName(from: nsRaw, match: match)
        }

        if let match = Self.seasonXEpisodeRegex.firstMatch(in: rawBaseName, options: [], range: fullRange) {
            return formattedShowName(from: nsRaw, match: match)
        }

        return nil
    }

    private func formattedShowName(from rawString: NSString, match: NSTextCheckingResult) -> String? {
        guard match.numberOfRanges >= 3 else { return nil }
        let seasonRange = match.range(at: 1)
        let episodeRange = match.range(at: 2)
        guard seasonRange.location != NSNotFound, episodeRange.location != NSNotFound else { return nil }

        let seasonText = rawString.substring(with: seasonRange)
        let episodeText = rawString.substring(with: episodeRange)
        guard let season = Int(seasonText), let episode = Int(episodeText) else { return nil }

        let showPrefix = rawString.substring(to: match.range.location)
        let showTokens = cleanedTitleTokens(from: showPrefix)
        guard !showTokens.isEmpty else { return nil }

        var showYear: String?
        var titleTokens: [String] = []
        titleTokens.reserveCapacity(showTokens.count)

        for token in showTokens {
            let normalized = normalizedToken(token)
            if showYear == nil, isYearToken(normalized) {
                showYear = normalized
                continue
            }
            titleTokens.append(token)
        }

        guard !titleTokens.isEmpty else { return nil }

        let showTitle = titleTokens.map(titleCaseToken).joined(separator: " ")
        let showName = showYear.map { "\(showTitle) (\($0))" } ?? showTitle
        return "\(showName) - S\(twoDigit(season))E\(twoDigit(episode))"
    }

    private func suggestedMovieBaseName(from rawBaseName: String) -> String? {
        let tokens = cleanedTitleTokens(from: rawBaseName)
        guard !tokens.isEmpty else { return nil }

        var year: String?
        var titleTokens: [String] = []

        for token in tokens {
            let normalized = normalizedToken(token)

            if year == nil, isYearToken(normalized) {
                year = normalized
                continue
            }

            if isMetadataToken(normalized) {
                continue
            }

            if year == nil {
                titleTokens.append(token)
            }
        }

        guard let year else { return nil }
        guard !titleTokens.isEmpty else { return nil }

        let title = titleTokens.map(titleCaseToken).joined(separator: " ")
        return "\(title) (\(year))"
    }

    private func cleanedTitleTokens(from value: String) -> [String] {
        let separatorsNormalized = value
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        let rawTokens = separatorsNormalized
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'&"))
        var tokens: [String] = []
        tokens.reserveCapacity(rawTokens.count)

        for token in rawTokens {
            let trimmed = token.trimmingCharacters(in: allowed.inverted)
            if !trimmed.isEmpty {
                tokens.append(trimmed)
            }
        }

        return tokens
    }

    private func normalizedToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
    }

    private func isYearToken(_ token: String) -> Bool {
        let nsToken = token as NSString
        let range = NSRange(location: 0, length: nsToken.length)
        guard let match = Self.yearRegex.firstMatch(in: token, options: [], range: range) else {
            return false
        }
        return match.range.location == 0 && match.range.length == nsToken.length
    }

    private func isMetadataToken(_ token: String) -> Bool {
        if Self.metadataTokens.contains(token) {
            return true
        }

        if ["480", "576", "720", "1080", "1440", "2160"].contains(token) {
            return true
        }

        if token.hasPrefix("x26"), token.count == 4 {
            return true
        }

        return false
    }

    private func titleCaseToken(_ token: String) -> String {
        if token.count <= 4, token == token.uppercased() {
            return token
        }

        if token.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            return token
        }

        return token.capitalized(with: Locale.current)
    }

    private func twoDigit(_ value: Int) -> String {
        String(format: "%02d", max(0, value))
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
