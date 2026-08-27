import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

private struct MetadataCleanerProbeOutput: Decodable {
    let streams: [MetadataCleanerProbeStream]
    let format: MetadataCleanerProbeFormat?
}

private struct MetadataCleanerProbeStream: Decodable {
    let index: Int
    let codecType: String?
    let tags: [String: String]?
    let disposition: MetadataCleanerDisposition?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case tags
        case disposition
    }
}

private struct MetadataCleanerDisposition: Decodable {
    let isForced: Int?
    let isHearingImpaired: Int?
    let isCaptions: Int?

    enum CodingKeys: String, CodingKey {
        case isForced = "forced"
        case isHearingImpaired = "hearing_impaired"
        case isCaptions = "captions"
    }
}

private struct MetadataCleanerProbeFormat: Decodable {
    let duration: String?
    let tags: [String: String]?
}

private nonisolated final class MetadataCleanerProcessCapture: @unchecked Sendable {
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

struct MetadataCleanerResult: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: String
    var issues: [String]
    var actionMessage: String?

    var needsCleaning: Bool { !issues.isEmpty }
}

@MainActor
final class MetadataCleanerViewModel: ObservableObject {
    @Published var inputPath = ""
    @Published var inputIsFolder = false
    @Published var isResolvingInput = false
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var statusMessage = ""
    @Published var results: [MetadataCleanerResult] = []
    @Published var operationProgressFraction: Double = 0
    @Published var operationCurrentItem = 0
    @Published var operationTotalItems = 0
    @Published var operationEstimatedRemaining: TimeInterval?

    private var ffmpegPath = ""
    private var ffprobePath = ""
    private var operationTask: Task<Void, Never>?
    private let processLock = NSLock()
    private nonisolated(unsafe) var currentProcess: Process?
    private var exportDialogHostWindow: NSWindow?

    var hasTools: Bool { !ffmpegPath.isEmpty && !ffprobePath.isEmpty }
    var isBusy: Bool { isResolvingInput || isScanning || isCleaning }
    var canScan: Bool { hasTools && !inputPath.isEmpty && !isBusy }
    var canExport: Bool { !results.isEmpty && !isBusy }
    var cleanableResults: [MetadataCleanerResult] { results.filter(\.needsCleaning) }

    var inputTitle: String {
        guard !inputPath.isEmpty else { return "No Item Selected" }
        return inputIsFolder ? "Input Folder" : "Input MP4 File"
    }

    var inputDetail: String {
        inputPath.isEmpty ? "Choose one MP4 file or a folder containing MP4 files" : inputPath
    }

    init() {
        ffmpegPath = Self.findExecutable(named: "ffmpeg") ?? ""
        ffprobePath = Self.findExecutable(named: "ffprobe") ?? ""
    }

    func selectInput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.message = "Choose one MP4 file or a folder to scan recursively"
        CleanFilePanelPresenter.present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.acceptInput(url: url)
        }
    }

    func acceptInput(url: URL) {
        guard !isScanning, !isCleaning else { return }
        operationTask?.cancel()
        isResolvingInput = true
        statusMessage = "Checking selected item…"
        let path = url.path
        operationTask = Task {
            let item = await Task.detached(priority: .userInitiated) {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(
                    atPath: path,
                    isDirectory: &isDirectory
                )
                return (exists: exists, isDirectory: isDirectory.boolValue)
            }.value
            guard !Task.isCancelled else { return }
            isResolvingInput = false
            guard item.exists,
                  item.isDirectory || url.pathExtension.lowercased() == "mp4" else {
                statusMessage = "Choose an MP4 file or a folder containing MP4 files."
                return
            }

            inputPath = path
            inputIsFolder = item.isDirectory
            results = []
            statusMessage = inputIsFolder
                ? "Ready to scan this folder and its subfolders."
                : "Ready to inspect this MP4 file."
        }
    }

    func revealInput() {
        guard !inputPath.isEmpty else { return }
        if inputIsFolder {
            NSWorkspace.shared.open(URL(fileURLWithPath: inputPath, isDirectory: true))
        } else {
            NSWorkspace.shared.selectFile(
                inputPath,
                inFileViewerRootedAtPath: URL(fileURLWithPath: inputPath).deletingLastPathComponent().path
            )
        }
    }

    func scan() {
        guard canScan else { return }
        operationTask?.cancel()
        results = []
        statusMessage = "Preparing scan…"
        isScanning = true
        operationTask = Task { await runScan() }
    }

    func clean(resultIDs: Set<UUID>) {
        guard hasTools, !isBusy else { return }
        let selected = results.filter { resultIDs.contains($0.id) && $0.needsCleaning }
        guard !selected.isEmpty else { return }
        operationTask?.cancel()
        isCleaning = true
        statusMessage = "Preparing metadata cleanup…"
        operationTask = Task { await runCleanup(selected) }
    }

    func cancel() {
        guard isBusy else { return }
        operationTask?.cancel()
        terminateCurrentProcess()
        isResolvingInput = false
        isScanning = false
        isCleaning = false
        statusMessage = "Operation canceled."
    }

    func exportCSV() {
        guard canExport else { return }
        let reportRows = results.map {
            (
                itemName: URL(fileURLWithPath: $0.filePath).lastPathComponent,
                path: $0.filePath,
                metadata: $0.issues.joined(separator: "; ")
            )
        }

        let hostWindow = makeHiddenChromeHostWindow()
        exportDialogHostWindow = hostWindow
        hostWindow.makeKeyAndOrderFront(nil)

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "mp4-metadata-report.csv"
        panel.beginSheetModal(for: hostWindow) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                defer {
                    self.exportDialogHostWindow?.orderOut(nil)
                    self.exportDialogHostWindow = nil
                }
                guard response == .OK, let url = panel.url else { return }
                let header = ["Item Name", "Path", "Detected Metadata"]
                    .map(self.csvField).joined(separator: ",")
                let rows = reportRows.map { row in
                    [row.itemName, row.path, row.metadata]
                        .map(self.csvField).joined(separator: ",")
                }
                let body = "\u{FEFF}" + ([header] + rows).joined(separator: "\r\n") + "\r\n"
                do {
                    try body.write(to: url, atomically: true, encoding: .utf8)
                    self.statusMessage = "Exported \(reportRows.count) result(s) to \(url.path)."
                } catch {
                    self.statusMessage = "CSV export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func runScan() async {
        let assertion = SystemSleepAssertion(reason: "MP4 Tool is scanning MP4 metadata")
        defer { assertion.invalidate() }

        let selectedPath = inputPath
        let selectedIsFolder = inputIsFolder
        statusMessage = selectedIsFolder ? "Discovering MP4 files…" : "Preparing MP4 file…"
        let discoveryTask = Task.detached(priority: .userInitiated) {
            Self.collectFiles(inputPath: selectedPath, inputIsFolder: selectedIsFolder)
        }
        let files = await withTaskCancellationHandler {
            await discoveryTask.value
        } onCancel: {
            discoveryTask.cancel()
        }
        guard !Task.isCancelled else { return }
        guard !files.isEmpty else {
            statusMessage = "No MP4 files were found."
            isScanning = false
            return
        }

        var flagged: [MetadataCleanerResult] = []
        var unreadableCount = 0
        let operationStartedAt = Date()
        resetOperationProgress(totalItems: files.count)
        for (offset, file) in files.enumerated() {
            guard !Task.isCancelled else { return }
            updateOperationProgress(
                currentItem: offset + 1,
                totalItems: files.count,
                startedAt: operationStartedAt
            )
            statusMessage = "Scanning \(offset + 1) of \(files.count): \(file.relativePath)"
            guard let probe = await probe(path: file.fullPath) else {
                unreadableCount += 1
                continue
            }
            let issues = metadataIssues(in: probe, filePath: file.fullPath)
            if !issues.isEmpty {
                flagged.append(
                    MetadataCleanerResult(
                        fileName: file.relativePath,
                        filePath: file.fullPath,
                        issues: issues,
                        actionMessage: nil
                    )
                )
            }
        }

        guard !Task.isCancelled else { return }
        results = flagged
        if flagged.isEmpty {
            statusMessage = "Checked \(files.count) MP4 file(s). No junk metadata found."
        } else {
            statusMessage = "Checked \(files.count) MP4 file(s). Found \(flagged.count) needing cleanup."
        }
        if unreadableCount > 0 {
            statusMessage += " \(unreadableCount) could not be inspected."
        }
        isScanning = false
    }

    private func runCleanup(_ selected: [MetadataCleanerResult]) async {
        let assertion = SystemSleepAssertion(reason: "MP4 Tool is cleaning MP4 metadata")
        defer { assertion.invalidate() }
        var cleaned = 0
        var failed = 0
        let operationStartedAt = Date()
        resetOperationProgress(totalItems: selected.count)

        for (offset, result) in selected.enumerated() {
            guard !Task.isCancelled else { return }
            updateOperationProgress(
                currentItem: offset + 1,
                totalItems: selected.count,
                startedAt: operationStartedAt
            )
            statusMessage = "Cleaning \(offset + 1) of \(selected.count): \(result.fileName)"
            updateResult(result.id, message: "Creating validated replacement…")
            if await cleanFile(result) {
                cleaned += 1
                updateResult(result.id, issues: [], message: "Cleaned")
            } else {
                failed += 1
            }
        }

        guard !Task.isCancelled else { return }
        isCleaning = false
        statusMessage = "Metadata cleanup finished: \(cleaned) cleaned"
        if failed > 0 { statusMessage += ", \(failed) failed" }
        statusMessage += "."
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

    private func cleanFile(_ result: MetadataCleanerResult) async -> Bool {
        guard let sourceProbe = await probe(path: result.filePath) else {
            updateResult(result.id, message: "Failed: source could not be inspected")
            return false
        }

        let sourceURL = URL(fileURLWithPath: result.filePath)
        let temporaryURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(".mp4tool-metadata-clean-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        var arguments = [
            "-hide_banner", "-nostdin", "-y", "-i", result.filePath,
            "-map", "0", "-map_metadata", "0", "-map_chapters", "0", "-c", "copy"
        ]

        for (key, value) in sourceProbe.format?.tags ?? [:]
        where shouldFlagContainerTag(key: key, value: value, filePath: result.filePath) {
            arguments.append(contentsOf: ["-metadata", "\(key)="])
        }

        var typeIndexes: [String: Int] = [:]
        for (outputIndex, stream) in sourceProbe.streams.enumerated() {
            let codecType = stream.codecType?.lowercased() ?? ""
            let typeIndex = typeIndexes[codecType, default: 0]
            typeIndexes[codecType] = typeIndex + 1
            let streamSpecifier: String
            switch codecType {
            case "video": streamSpecifier = "v:\(typeIndex)"
            case "audio": streamSpecifier = "a:\(typeIndex)"
            case "subtitle": streamSpecifier = "s:\(typeIndex)"
            case "data": streamSpecifier = "d:\(typeIndex)"
            case "attachment": streamSpecifier = "t:\(typeIndex)"
            default: streamSpecifier = "\(outputIndex)"
            }
            let title = tag("title", in: stream.tags)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let handler = tag("handler_name", in: stream.tags)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let replacement = codecType == "subtitle" ? standardizedSubtitleTitle(for: stream) : ""
            if isJunkTrackLabel(title, stream: stream, filePath: result.filePath) {
                arguments.append(contentsOf: ["-metadata:s:\(streamSpecifier)", "title=\(replacement)"])
            }
            if isJunkTrackLabel(handler, stream: stream, filePath: result.filePath) {
                arguments.append(contentsOf: ["-metadata:s:\(streamSpecifier)", "handler_name=\(replacement)"])
            }
        }

        arguments.append(contentsOf: [
            "-movflags", "+faststart", "-loglevel", "error", temporaryURL.path
        ])

        guard let processResult = await runProcess(path: ffmpegPath, arguments: arguments) else {
            updateResult(result.id, message: "Failed: FFmpeg could not start")
            return false
        }
        guard processResult.exitCode == 0 else {
            let error = processResult.stderr
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last(where: { !$0.isEmpty })
            updateResult(result.id, message: "Failed: \(error ?? "FFmpeg remux failed")")
            return false
        }
        guard !Task.isCancelled else { return false }

        guard let outputProbe = await probe(path: temporaryURL.path) else {
            updateResult(result.id, message: "Failed: temporary output is unreadable")
            return false
        }
        let preservedTypes = Set(["video", "audio", "subtitle"])
        let sourceCounts = Dictionary(grouping: sourceProbe.streams.filter {
            preservedTypes.contains($0.codecType?.lowercased() ?? "")
        }, by: { $0.codecType?.lowercased() ?? "unknown" }).mapValues(\.count)
        let outputCounts = Dictionary(grouping: outputProbe.streams.filter {
            preservedTypes.contains($0.codecType?.lowercased() ?? "")
        }, by: { $0.codecType?.lowercased() ?? "unknown" }).mapValues(\.count)
        guard outputCounts == sourceCounts else {
            updateResult(result.id, message: "Failed validation: media track count changed")
            return false
        }
        if let sourceDuration = Double(sourceProbe.format?.duration ?? ""),
           let outputDuration = Double(outputProbe.format?.duration ?? ""),
           abs(sourceDuration - outputDuration) > max(2, sourceDuration * 0.001) {
            updateResult(result.id, message: "Failed validation: duration changed")
            return false
        }
        guard metadataIssues(in: outputProbe, filePath: result.filePath).isEmpty else {
            updateResult(result.id, message: "Failed validation: metadata remains")
            return false
        }

        do {
            _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: temporaryURL)
            return true
        } catch {
            updateResult(result.id, message: "Failed to replace original: \(error.localizedDescription)")
            return false
        }
    }

    private func metadataIssues(in probe: MetadataCleanerProbeOutput, filePath: String) -> [String] {
        var issues: [String] = []
        for (key, value) in probe.format?.tags ?? [:] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if shouldFlagContainerTag(key: key, value: trimmed, filePath: filePath) {
                issues.append("Container \(key): \(trimmed)")
            }
        }

        for stream in probe.streams {
            let kind = stream.codecType?.capitalized ?? "Stream"
            let title = tag("title", in: stream.tags)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let handler = tag("handler_name", in: stream.tags)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isJunkTrackLabel(title, stream: stream, filePath: filePath) {
                issues.append("\(kind) stream \(stream.index) title: \(title)")
            }
            if isJunkTrackLabel(handler, stream: stream, filePath: filePath) {
                issues.append("\(kind) stream \(stream.index) handler: \(handler)")
            }
        }
        return issues
    }

    private func shouldFlagContainerTag(key: String, value: String, filePath: String) -> Bool {
        let normalizedKey = key.lowercased()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let benignKeys: Set<String> = [
            "major_brand", "minor_version", "compatible_brands", "creation_time", "date",
            "description", "synopsis", "genre", "artist", "album", "copyright",
            "compilation", "gapless_playback", "hd_video", "media_type"
        ]
        if benignKeys.contains(normalizedKey) { return false }

        if normalizedKey == "encoder" {
            let knownTools = ["lavf", "ffmpeg", "handbrake", "dvdfab", "yamb", "gpac", "l-smash"]
            return !knownTools.contains { trimmed.lowercased().contains($0) }
        }

        if normalizedKey == "title" {
            return isSuspiciousAttribution(trimmed)
                || !labelMatchesFileTitle(trimmed, filePath: filePath)
        }

        if normalizedKey == "comment" {
            return isSuspiciousAttribution(trimmed)
        }

        return true
    }

    private func isJunkTrackLabel(
        _ value: String,
        stream: MetadataCleanerProbeStream,
        filePath: String
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let normalized = trimmed.lowercased()
        let genericHandlers: Set<String> = [
            "videohandler", "soundhandler", "subtitlehandler", "mediahandler",
            "video media handler", "sound media handler", "video"
        ]
        if genericHandlers.contains(normalized)
            || normalized.contains("core media")
            || normalized == "l-smash video media handler"
            || normalized == "gpac iso audio handler"
            || normalized == "gpac iso video handler"
            || normalized == "gpac streaming text handler"
            || normalized == "gopro met" {
            return false
        }

        if isGenericGPACImport(normalized) { return false }
        if stream.codecType?.lowercased() == "subtitle",
           trimmed.caseInsensitiveCompare(standardizedSubtitleTitle(for: stream)) == .orderedSame {
            return false
        }
        if labelMatchesFileTitle(trimmed, filePath: filePath), !isSuspiciousAttribution(trimmed) {
            return false
        }
        if stream.codecType?.lowercased() == "audio" && isBenignAudioDescription(trimmed) {
            return false
        }
        return true
    }

    private func isGenericGPACImport(_ normalized: String) -> Bool {
        if normalized.hasPrefix("imported with gpac") { return true }
        if normalized.contains("imported with gpac") {
            let prefix = normalized.components(separatedBy: " - imported with gpac").first ?? normalized
            let components = prefix.split(separator: ".", omittingEmptySubsequences: true)
            let genericCodecs: Set<String> = [
                "h264", "h265", "hevc", "avc", "aac", "ac3", "eac3", "mp3", "srt", "mov_text"
            ]
            if components.count == 2,
               Int(components[0]) != nil,
               genericCodecs.contains(String(components[1])) {
                return true
            }
        }

        if normalized.contains("@gpac") {
            let prefix = normalized.components(separatedBy: "@gpac").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "* ")) ?? ""
            let genericSubtitleNames: Set<String> = [
                "srt", "eng.srt", "english.srt", "sub.srt", "subtitle.srt"
            ]
            if genericSubtitleNames.contains(prefix) { return true }
        }

        guard normalized.contains("trackid=") else { return false }
        let prefix = normalized.components(separatedBy: "#trackid=").first ?? normalized
        let genericPrefixes = ["video.264", "mkv.264", "264", "aac", "audio"]
        return genericPrefixes.contains(prefix)
    }

    private func isBenignAudioDescription(_ value: String) -> Bool {
        if isSuspiciousAttribution(value) { return false }
        let normalized = value.lowercased()
        if normalized.hasPrefix("commentary ") || normalized.hasPrefix("t2_audio") {
            return true
        }

        let allowedWords: Set<String> = [
            "english", "spanish", "french", "german", "italian", "portuguese", "dutch",
            "polish", "russian", "japanese", "korean", "chinese", "undefined",
            "stereo", "surround", "sound", "mono", "main", "movie", "feature",
            "audio", "repaired", "new", "aac", "ac", "eac", "dts", "hd", "master",
            "digital", "dolby", "plus", "atmos", "truehd", "pro", "logic",
            "channel", "channels", "chan", "kbps", "khz", "bit", "bits", "with",
            "w", "e", "ac3", "ii"
        ]
        let words = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.rangeOfCharacter(from: .letters) != nil }
        if words.isEmpty {
            return normalized.rangeOfCharacter(from: .decimalDigits) != nil
        }
        return words.allSatisfy { allowedWords.contains($0) }
    }

    private func isSuspiciousAttribution(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let knownMarkers = [
            "rarbg", "yify", "framestor", "etrg", "silverrg", "ozlem", "surendra",
            "kingdom rg", "nimitmak", "yawntic", "flicksick", "alliance", "amiable",
            "bokutox", "lonewolf", "sampa", "matrix", "skn @", "-fgt", "-vice"
        ]
        if knownMarkers.contains(where: normalized.contains) { return true }
        if normalized.contains("http://") || normalized.contains("https://") { return true }
        if normalized.contains("@") && !isGenericGPACImport(normalized) { return true }

        let releaseTokens = ["720p", "1080p", "2160p", "webrip", "web-dl", "bluray", "brrip", "x264", "x265"]
        let releaseTokenCount = releaseTokens.filter(normalized.contains).count
        return releaseTokenCount >= 2 || (releaseTokenCount >= 1 && normalized.contains(".mkv"))
    }

    private func labelMatchesFileTitle(_ value: String, filePath: String) -> Bool {
        let fileTitle = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        let normalizedValue = normalizedComparableTitle(value)
        let normalizedFile = normalizedComparableTitle(fileTitle)
        guard normalizedValue.count >= 4 else { return false }
        return normalizedFile == normalizedValue
            || normalizedFile.hasPrefix(normalizedValue + " ")
            || normalizedValue.hasPrefix(normalizedFile + " ")
    }

    private func normalizedComparableTitle(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func standardizedSubtitleTitle(for stream: MetadataCleanerProbeStream) -> String {
        let language = tag("language", in: stream.tags)?.lowercased() ?? "und"
        let baseName = Self.languageDisplayName(language)
        let sourceDescription = [tag("title", in: stream.tags), tag("handler_name", in: stream.tags)]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let forced = stream.disposition?.isForced == 1 || sourceDescription.contains("forced")
        let sdh = stream.disposition?.isHearingImpaired == 1
            || stream.disposition?.isCaptions == 1
            || sourceDescription.contains("sdh")
            || sourceDescription.contains("hearing impaired")
        var roles: [String] = []
        if forced { roles.append("Forced") }
        if sdh { roles.append("SDH") }
        return roles.isEmpty ? baseName : "\(baseName) (\(roles.joined(separator: ", ")))"
    }

    private func tag(_ name: String, in tags: [String: String]?) -> String? {
        tags?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func updateResult(_ id: UUID, issues: [String]? = nil, message: String) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        if let issues { results[index].issues = issues }
        results[index].actionMessage = message
    }

    private func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private nonisolated static func collectFiles(
        inputPath: String,
        inputIsFolder: Bool
    ) -> [(relativePath: String, fullPath: String)] {
        if !inputIsFolder {
            let url = URL(fileURLWithPath: inputPath)
            return [(url.lastPathComponent, url.path)]
        }
        let rootURL = URL(fileURLWithPath: inputPath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "mp4" {
            if Task.isCancelled { return [] }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = url.path.replacingOccurrences(of: inputPath + "/", with: "")
            files.append((relative, url.path))
        }
        return files.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    private func probe(path: String) async -> MetadataCleanerProbeOutput? {
        guard let result = await runProcess(path: ffprobePath, arguments: [
            "-v", "error", "-show_streams", "-show_format", "-print_format", "json", path
        ]), result.exitCode == 0, let data = result.stdout.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MetadataCleanerProbeOutput.self, from: data)
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
                let capture = MetadataCleanerProcessCapture()
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

    private func makeHiddenChromeHostWindow() -> NSWindow {
        let size = NSSize(width: 640, height: 480)
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
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

    private nonisolated static func languageDisplayName(_ code: String) -> String {
        let known = [
            "und": "Subtitles", "eng": "English", "spa": "Spanish", "fra": "French",
            "fre": "French", "deu": "German", "ger": "German", "ita": "Italian",
            "por": "Portuguese", "nld": "Dutch", "dut": "Dutch", "pol": "Polish",
            "rus": "Russian", "jpn": "Japanese", "kor": "Korean", "zho": "Chinese"
        ]
        return known[code] ?? Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    private nonisolated static func findExecutable(named name: String) -> String? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "bin")?.path,
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        for path in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }
}
