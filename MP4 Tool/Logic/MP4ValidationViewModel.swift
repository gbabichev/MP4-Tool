import Foundation
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

let queueMP4ValidationFlaggedFilesNotification = Notification.Name("MP4Tool.QueueMP4ValidationFlaggedFiles")
let queueMP4ValidationFlaggedFilesPathsKey = "paths"

private struct MP4ValidationAudioProbeOutput: Decodable {
    let streams: [MP4ValidationAudioStream]
    let format: MP4ValidationProbeFormat?
}

private struct MP4ValidationAudioStream: Decodable {
    let index: Int
    let codecName: String?
    let codecTagString: String?
    let sampleFormat: String?
    let channels: Int?
    let channelLayout: String?
    let startTime: String?
    let duration: String?
    let disposition: MP4ValidationStreamDisposition?
    let tags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case codecTagString = "codec_tag_string"
        case sampleFormat = "sample_fmt"
        case channels
        case channelLayout = "channel_layout"
        case startTime = "start_time"
        case duration
        case disposition
        case tags
    }
}

private struct MP4ValidationStreamDisposition: Decodable {
    let isDefault: Int?

    enum CodingKeys: String, CodingKey {
        case isDefault = "default"
    }
}

private struct MP4ValidationProbeFormat: Decodable {
    let duration: String?
}

private struct MP4ValidationAudioCompatibility {
    let hasAudioStreams: Bool
    let issues: [String]
    let streams: [MP4ValidationAudioStream]
    let formatDuration: TimeInterval?
}

struct MP4AudioRepairCandidate: Equatable {
    let streamIndex: Int
    let audioIndex: Int
}

private struct MP4ValidationAudioAuthoringAnalysis {
    let warnings: [String]
    let repairCandidates: [MP4AudioRepairCandidate]
}

enum MP4ValidationSeverity {
    case warning
    case error
}

private struct MP4ValidationFinding {
    let message: String
    let severity: MP4ValidationSeverity
    let repairCandidates: [MP4AudioRepairCandidate]
}

struct MP4ValidationResult: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let issue: String?
    let severity: MP4ValidationSeverity?
    let repairCandidates: [MP4AudioRepairCandidate]
    var repairMessage: String? = nil

    var isFlagged: Bool {
        issue != nil
    }

    var isRepairable: Bool {
        !repairCandidates.isEmpty
    }
}

@MainActor
final class MP4ValidationViewModel: ObservableObject {
    @Published var inputFolderPath: String = ""
    @Published var isScanning = false
    @Published var isRepairing = false
    @Published var scanProgress = ""
    @Published var scanAlertText = ""
    @Published var results: [MP4ValidationResult] = []
    @Published private(set) var droppedFilePaths: [String] = []

    private var ffprobePath: String = ""
    private var ffprobeAvailable = false
    private var ffmpegPath: String = ""
    private var ffmpegAvailable = false
    private var scanTask: Task<Void, Never>?
    private var repairTask: Task<Void, Never>?
    private var scanToken = UUID()
    private let processLock = NSLock()
    private nonisolated(unsafe) var currentProcess: Process?
    private var exportDialogHostWindow: NSWindow?

    var canScan: Bool {
        (!inputFolderPath.isEmpty || !droppedFilePaths.isEmpty) && !isScanning && !isRepairing
    }

    var inputSelectionDescription: String {
        if !droppedFilePaths.isEmpty {
            let noun = droppedFilePaths.count == 1 ? "file" : "files"
            return "\(droppedFilePaths.count) dropped MP4 \(noun)"
        }
        return inputFolderPath.isEmpty ? "Select a folder or drop MP4 files here" : inputFolderPath
    }

    var flaggedResults: [MP4ValidationResult] {
        results.filter(\.isFlagged)
    }

    var warningResults: [MP4ValidationResult] {
        results.filter { $0.severity == .warning }
    }

    var errorResults: [MP4ValidationResult] {
        results.filter { $0.severity == .error }
    }

    var canExportFlagged: Bool {
        !isScanning && !isRepairing && !flaggedResults.isEmpty
    }

    var canSendFlaggedToMainApp: Bool {
        !isScanning && !isRepairing && !flaggedResults.isEmpty
    }

    init() {
        locateMediaTools()
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
            droppedFilePaths = []
        }
    }

    func openInputFolderInFinder() {
        if let firstDroppedPath = droppedFilePaths.first {
            NSWorkspace.shared.selectFile(
                firstDroppedPath,
                inFileViewerRootedAtPath: URL(fileURLWithPath: firstDroppedPath)
                    .deletingLastPathComponent().path
            )
        } else if !inputFolderPath.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: inputFolderPath, isDirectory: true))
        }
    }

    func setInputFolder(url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        inputFolderPath = url.path
        droppedFilePaths = []
        scanAlertText = ""
        return true
    }

    func setDroppedFiles(urls: [URL]) -> Bool {
        let paths = urls.compactMap { url -> String? in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  url.pathExtension.lowercased() == "mp4" else {
                return nil
            }
            return url.path
        }

        let uniquePaths = Array(Set(droppedFilePaths).union(paths)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        guard !uniquePaths.isEmpty else {
            scanAlertText = "Drop one or more MP4 files, or a folder containing MP4 files."
            return false
        }

        droppedFilePaths = uniquePaths
        inputFolderPath = ""
        results = []
        scanProgress = ""
        scanAlertText = "Ready to validate \(uniquePaths.count) dropped MP4 file(s)."
        return true
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

    func repairSelected(resultIDs: Set<UUID>) {
        guard !isScanning, !isRepairing else { return }
        let selectedResults = results.filter {
            resultIDs.contains($0.id) && $0.isRepairable
        }
        guard !selectedResults.isEmpty else {
            scanAlertText = "Select at least one repairable audio warning."
            return
        }

        isRepairing = true
        scanAlertText = ""
        repairTask?.cancel()
        repairTask = Task {
            await runRepairs(selectedResults)
        }
    }

    func cancelRepair() {
        guard isRepairing else { return }
        repairTask?.cancel()
        terminateCurrentProcess()
        scanProgress = "Repair canceled."
        isRepairing = false
    }

    private func runRepairs(_ selectedResults: [MP4ValidationResult]) async {
        let sleepAssertion = SystemSleepAssertion(reason: "MP4 Tool is repairing MP4 files")
        defer { sleepAssertion.invalidate() }

        var repairedCount = 0
        var skippedCount = 0

        for (index, result) in selectedResults.enumerated() {
            if Task.isCancelled {
                scanProgress = "Repair canceled."
                isRepairing = false
                return
            }

            scanProgress = "Repairing \(index + 1)/\(selectedResults.count): \(result.fileName)"
            updateRepairMessage(for: result.id, message: "Confirming channel activity across the full audio track…")

            guard let compatibility = await probeAudioCompatibility(filePath: result.filePath) else {
                skippedCount += 1
                updateRepairMessage(for: result.id, message: "Repair failed: could not inspect audio streams.")
                continue
            }

            var confirmedCandidates: [MP4AudioRepairCandidate] = []
            for candidate in result.repairCandidates {
                guard let stream = compatibility.streams.first(where: { $0.index == candidate.streamIndex }),
                      let activeChannels = await activeAudioChannels(
                        filePath: result.filePath,
                        stream: stream,
                        formatDuration: compatibility.formatDuration,
                        fullScan: true
                      ),
                      activeChannels == Set([1, 2]) else {
                    continue
                }
                confirmedCandidates.append(candidate)
            }

            if Task.isCancelled {
                scanProgress = "Repair canceled."
                isRepairing = false
                return
            }

            guard confirmedCandidates.count == result.repairCandidates.count else {
                skippedCount += 1
                updateRepairMessage(
                    for: result.id,
                    message: "Repair skipped: the full-track scan did not confirm stereo-only signal."
                )
                continue
            }

            let inputURL = URL(fileURLWithPath: result.filePath)
            let outputURL = inputURL.deletingLastPathComponent().appendingPathComponent(
                inputURL.deletingPathExtension().lastPathComponent + "_repaired.mp4"
            )

            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                skippedCount += 1
                updateRepairMessage(
                    for: result.id,
                    message: "Repair skipped: \(outputURL.lastPathComponent) already exists."
                )
                continue
            }

            let temporaryURL = inputURL.deletingLastPathComponent().appendingPathComponent(
                ".mp4tool-audio-repair-\(UUID().uuidString).mp4"
            )
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            updateRepairMessage(for: result.id, message: "Re-encoding the malformed audio track as stereo…")
            var arguments = [
                "-hide_banner", "-nostats", "-y",
                "-i", result.filePath,
                "-map", "0",
                "-map_metadata", "0",
                "-map_chapters", "0",
                "-c", "copy"
            ]

            let repairedTrackNames = repairedAudioTrackNames(
                compatibility: compatibility,
                repairedCandidates: confirmedCandidates
            )

            for audioIndex in compatibility.streams.indices {
                arguments.append(
                    contentsOf: [
                        "-disposition:a:\(audioIndex)", audioIndex == 0 ? "default" : "0"
                    ]
                )
                if let trackName = repairedTrackNames[audioIndex] {
                    arguments.append(
                        contentsOf: [
                            "-metadata:s:a:\(audioIndex)", "title=\(trackName)",
                            "-metadata:s:a:\(audioIndex)", "handler_name=\(trackName)"
                        ]
                    )
                }
            }

            for candidate in confirmedCandidates {
                arguments.append(
                    contentsOf: [
                        "-filter:a:\(candidate.audioIndex)", "pan=stereo|c0=FL|c1=FR",
                        "-c:a:\(candidate.audioIndex)", "aac",
                        "-b:a:\(candidate.audioIndex)", "192k",
                        "-channel_layout:a:\(candidate.audioIndex)", "stereo"
                    ]
                )
            }
            arguments.append(contentsOf: ["-movflags", "+faststart", temporaryURL.path])

            let repairOutput = await runProcessCaptureStderr(path: ffmpegPath, arguments: arguments)
            if Task.isCancelled {
                scanProgress = "Repair canceled."
                isRepairing = false
                return
            }
            guard repairOutput != nil else {
                skippedCount += 1
                updateRepairMessage(for: result.id, message: "Repair failed while processing the audio track.")
                continue
            }

            guard let repairedCompatibility = await probeAudioCompatibility(filePath: temporaryURL.path),
                  repairedCompatibility.streams.filter({ $0.disposition?.isDefault == 1 }).count <= 1,
                  audioTrackNamesAreDistinguishable(repairedCompatibility.streams),
                  confirmedCandidates.allSatisfy({ candidate in
                    repairedCompatibility.streams.indices.contains(candidate.audioIndex)
                        && repairedCompatibility.streams[candidate.audioIndex].channels == 2
                        && normalizedProbeValue(
                            repairedCompatibility.streams[candidate.audioIndex].channelLayout
                        ) == "stereo"
                  }) else {
                skippedCount += 1
                updateRepairMessage(for: result.id, message: "Repair failed validation; the original was untouched.")
                continue
            }

            do {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
                repairedCount += 1
                updateRepairMessage(for: result.id, message: "Saved \(outputURL.lastPathComponent)")
            } catch {
                skippedCount += 1
                updateRepairMessage(for: result.id, message: "Repair failed: \(error.localizedDescription)")
            }
        }

        isRepairing = false
        scanProgress = "Repair complete: \(repairedCount) saved, \(skippedCount) skipped or failed."
        scanAlertText = repairedCount > 0
            ? "Repaired files were saved beside their originals with _repaired filenames."
            : "No repaired files were created."
    }

    private func updateRepairMessage(for resultID: UUID, message: String) {
        guard let index = results.firstIndex(where: { $0.id == resultID }) else { return }
        results[index].repairMessage = message
    }

    private func repairedAudioTrackNames(
        compatibility: MP4ValidationAudioCompatibility,
        repairedCandidates: [MP4AudioRepairCandidate]
    ) -> [Int: String] {
        let repairedAudioIndexes = Set(repairedCandidates.map(\.audioIndex))
        let indexedStreams = Array(compatibility.streams.enumerated())
        let languageGroups = Dictionary(grouping: indexedStreams) { indexedStream in
            normalizedProbeValue(indexedStream.element.tags?["language"])
        }
        var names: [Int: String] = [:]

        for (language, group) in languageGroups where group.count > 1 {
            let existingNames = group.map { audioTrackName($0.element) }
            let existingNameCounts = Dictionary(grouping: existingNames, by: { $0 }).mapValues(\.count)
            var generatedNameCounts: [String: Int] = [:]

            for (audioIndex, stream) in group {
                let existingName = audioTrackName(stream)
                let hasMeaningfulUniqueName = !existingName.isEmpty
                    && existingName != "soundhandler"
                    && existingNameCounts[existingName] == 1
                guard !hasMeaningfulUniqueName else { continue }

                let languageName: String
                if language.isEmpty || language == "und" {
                    languageName = "Audio"
                } else {
                    languageName = Locale(identifier: "en").localizedString(forLanguageCode: language)
                        ?? language.uppercased()
                }

                let layoutName: String
                if repairedAudioIndexes.contains(audioIndex) {
                    layoutName = "Stereo (Repaired)"
                } else if let layout = stream.channelLayout, !layout.isEmpty {
                    layoutName = layout.uppercased()
                } else if let channels = stream.channels {
                    layoutName = "\(channels) Channel"
                } else {
                    layoutName = "Track"
                }

                let baseName = "\(languageName) \(layoutName)"
                let occurrence = (generatedNameCounts[baseName] ?? 0) + 1
                generatedNameCounts[baseName] = occurrence
                names[audioIndex] = occurrence == 1 ? baseName : "\(baseName) \(occurrence)"
            }
        }

        return names
    }

    private func audioTrackNamesAreDistinguishable(
        _ streams: [MP4ValidationAudioStream]
    ) -> Bool {
        let languageGroups = Dictionary(grouping: streams) { stream in
            normalizedProbeValue(stream.tags?["language"])
        }

        for group in languageGroups.values where group.count > 1 {
            let names = group.map(audioTrackName)
            let meaningfulNames = names.filter { !$0.isEmpty && $0 != "soundhandler" }
            if meaningfulNames.count != group.count || Set(meaningfulNames).count != group.count {
                return false
            }
        }
        return true
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
        let sleepAssertion = SystemSleepAssertion(reason: "MP4 Tool is validating MP4 files")
        defer { sleepAssertion.invalidate() }

        let rootPath = inputFolderPath
        let selectedDroppedPaths = droppedFilePaths
        let files: [(relativePath: String, fullPath: String)]

        if selectedDroppedPaths.isEmpty {
            scanProgress = "Collecting MP4 files in folder and subfolders..."
            files = await Task.detached(priority: .userInitiated) {
                Self.collectMP4FilesRecursively(in: rootPath)
            }.value
        } else {
            scanProgress = "Preparing dropped MP4 files..."
            files = selectedDroppedPaths.map { path in
                (
                    relativePath: URL(fileURLWithPath: path).lastPathComponent,
                    fullPath: path
                )
            }
        }

        if Task.isCancelled || token != scanToken {
            scanProgress = "Validation canceled."
            isScanning = false
            return
        }

        if files.isEmpty {
            scanProgress = "No MP4 files found in folder or subfolders."
            scanAlertText = ""
            isScanning = false
            return
        }

        let scanStartDate = Date()
        for (index, fileInfo) in files.enumerated() {
            if Task.isCancelled || token != scanToken {
                scanProgress = "Validation canceled."
                isScanning = false
                return
            }

            scanProgress = "Validating \(index + 1)/\(files.count): \(fileInfo.relativePath) \(validationETA(elapsed: Date().timeIntervalSince(scanStartDate), completedCount: index, totalCount: files.count))"

            let finding = await validationFinding(filePath: fileInfo.fullPath)
            results.append(
                MP4ValidationResult(
                    fileName: fileInfo.relativePath,
                    filePath: fileInfo.fullPath,
                    issue: finding?.message,
                    severity: finding?.severity,
                    repairCandidates: finding?.repairCandidates ?? []
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
        if flaggedCount > 0 {
            parts.append("\(errorResults.count) error(s), \(warningResults.count) warning(s)")
        }
        if !ffprobeAvailable {
            parts.append("ffprobe not found; codec checks were skipped")
        } else if !ffmpegAvailable {
            parts.append("ffmpeg not found; channel activity checks were skipped")
        }
        scanAlertText = parts.joined(separator: ". ") + "."

        isScanning = false
    }

    private func validationFinding(filePath: String) async -> MP4ValidationFinding? {
        var reasons: [String] = []
        var warnings: [String] = []
        var repairCandidates: [MP4AudioRepairCandidate] = []
        var audioCompatibility: MP4ValidationAudioCompatibility?

        if ffprobeAvailable {
            if let unsupportedVideoCodec = await unsupportedAppleVideoCodec(filePath: filePath) {
                reasons.append("unsupported video codec \(unsupportedVideoCodec)")
            }

            audioCompatibility = await probeAudioCompatibility(filePath: filePath)
            if let audioCompatibility {
                reasons.append(contentsOf: audioCompatibility.issues)
                let authoringAnalysis = await audioAuthoringAnalysis(
                    filePath: filePath,
                    compatibility: audioCompatibility
                )
                warnings.append(contentsOf: authoringAnalysis.warnings)
                repairCandidates = authoringAnalysis.repairCandidates
            }
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
        let appleAudioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []

        if audioCompatibility?.hasAudioStreams == true && appleAudioTracks.isEmpty {
            reasons.append("audio not readable by Apple media frameworks")
        }

        do {
            let isPlayable = try await asset.load(.isPlayable)
            if !isPlayable {
                reasons.append("not playable")
            }
        } catch {
            reasons.append("could not be opened")
        }

        if !reasons.isEmpty {
            let allFindings = reasons + warnings
            return MP4ValidationFinding(
                message: allFindings.joined(separator: ", "),
                severity: .error,
                repairCandidates: []
            )
        }

        guard !warnings.isEmpty else { return nil }
        return MP4ValidationFinding(
            message: warnings.joined(separator: ", "),
            severity: .warning,
            repairCandidates: repairCandidates
        )
    }

    private func unsupportedAppleVideoCodec(filePath: String) async -> String? {
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

        guard let codec, !codec.isEmpty else {
            return nil
        }

        return isAppleCompatibleVideoCodec(codec) ? nil : codec
    }

    private func isAppleCompatibleVideoCodec(_ codec: String) -> Bool {
        [
            "h264",
            "hevc",
            "h265",
            "mpeg4"
        ].contains(codec)
    }

    private func probeAudioCompatibility(filePath: String) async -> MP4ValidationAudioCompatibility? {
        let arguments = [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries",
            "stream=index,codec_name,codec_tag_string,sample_fmt,channels,channel_layout,start_time,duration:stream_disposition=default:stream_tags=language,title,handler_name:format=duration",
            "-print_format", "json",
            filePath
        ]

        guard let output = await runProcessCaptureStdout(path: ffprobePath, arguments: arguments) else {
            return nil
        }

        guard let data = output.data(using: .utf8),
              let probeOutput = try? JSONDecoder().decode(MP4ValidationAudioProbeOutput.self, from: data) else {
            return nil
        }

        guard !probeOutput.streams.isEmpty else {
            return MP4ValidationAudioCompatibility(
                hasAudioStreams: false,
                issues: ["missing audio"],
                streams: [],
                formatDuration: probeOutput.format?.duration.flatMap(TimeInterval.init)
            )
        }

        var issues: [String] = []
        for stream in probeOutput.streams {
            let codec = normalizedProbeValue(stream.codecName)

            if isDTSAudioCodec(codec) {
                issues.append("DTS audio")
                continue
            }

            if isFloatingPointPCMAudio(stream) {
                issues.append("PCM float audio")
                continue
            }

            if !isAppleCompatibleAudioCodec(codec) {
                issues.append("unsupported audio codec \(displayProbeValue(stream.codecName))")
            }
        }

        var uniqueIssues: [String] = []
        for issue in issues where !uniqueIssues.contains(issue) {
            uniqueIssues.append(issue)
        }
        return MP4ValidationAudioCompatibility(
            hasAudioStreams: true,
            issues: uniqueIssues,
            streams: probeOutput.streams,
            formatDuration: probeOutput.format?.duration.flatMap(TimeInterval.init)
        )
    }

    private func audioAuthoringAnalysis(
        filePath: String,
        compatibility: MP4ValidationAudioCompatibility
    ) async -> MP4ValidationAudioAuthoringAnalysis {
        let streams = compatibility.streams
        guard !streams.isEmpty else {
            return MP4ValidationAudioAuthoringAnalysis(warnings: [], repairCandidates: [])
        }

        var warnings: [String] = []
        var repairCandidates: [MP4AudioRepairCandidate] = []

        let defaultStreams = streams.filter { $0.disposition?.isDefault == 1 }
        if defaultStreams.count > 1 {
            warnings.append("multiple default audio tracks")
        }

        let languageGroups = Dictionary(grouping: streams) { stream in
            normalizedProbeValue(stream.tags?["language"])
        }
        for language in languageGroups.keys.sorted()
            where !language.isEmpty {
            guard let matchingStreams = languageGroups[language], matchingStreams.count > 1 else {
                continue
            }
            let trackNames = matchingStreams.map(audioTrackName)
            let meaningfulNames = trackNames.filter { !$0.isEmpty && $0 != "soundhandler" }
            if meaningfulNames.count != matchingStreams.count
                || Set(meaningfulNames).count != matchingStreams.count {
                warnings.append("multiple \(language) audio tracks lack distinguishing titles")
            }
        }

        for (audioIndex, stream) in streams.enumerated() {
            guard let channelCount = stream.channels else { continue }

            if let expectedCount = expectedChannelCount(for: stream.channelLayout),
               expectedCount != channelCount {
                warnings.append(
                    "audio stream \(stream.index) declares \(stream.channelLayout ?? "unknown") but contains \(channelCount) channels"
                )
            } else if channelCount > 2,
                      normalizedProbeValue(stream.channelLayout).isEmpty {
                warnings.append("audio stream \(stream.index) has \(channelCount) channels with no channel layout")
            }

            if let formatDuration = compatibility.formatDuration,
               let audioDuration = stream.duration.flatMap(TimeInterval.init),
               abs(formatDuration - audioDuration) > 2 {
                warnings.append("audio stream \(stream.index) duration differs from the file by more than 2 seconds")
            }

            if let startTime = stream.startTime.flatMap(TimeInterval.init), abs(startTime) > 0.5 {
                warnings.append("audio stream \(stream.index) starts at \(String(format: "%.2f", startTime)) seconds")
            }

            guard ffmpegAvailable, channelCount >= 4 else { continue }
            if let activeChannels = await activeAudioChannels(
                filePath: filePath,
                stream: stream,
                formatDuration: compatibility.formatDuration,
                fullScan: false
            ), !activeChannels.isEmpty, activeChannels.count <= 2 {
                warnings.append(
                    "audio stream \(stream.index) claims \(channelCount) channels but only \(activeChannels.count) contain signal"
                )
                if activeChannels == Set([1, 2]) {
                    repairCandidates.append(
                        MP4AudioRepairCandidate(streamIndex: stream.index, audioIndex: audioIndex)
                    )
                }
            }
        }

        var uniqueWarnings: [String] = []
        for warning in warnings where !uniqueWarnings.contains(warning) {
            uniqueWarnings.append(warning)
        }
        return MP4ValidationAudioAuthoringAnalysis(
            warnings: uniqueWarnings,
            repairCandidates: repairCandidates
        )
    }

    private func audioTrackName(_ stream: MP4ValidationAudioStream) -> String {
        let title = normalizedProbeValue(stream.tags?["title"])
        if !title.isEmpty {
            return title
        }
        return normalizedProbeValue(stream.tags?["handler_name"])
    }

    private func expectedChannelCount(for layout: String?) -> Int? {
        switch normalizedProbeValue(layout) {
        case "mono": return 1
        case "stereo": return 2
        case "2.1", "3.0": return 3
        case "quad", "4.0": return 4
        case "5.0": return 5
        case "5.1", "5.1(side)": return 6
        case "6.1": return 7
        case "7.1", "7.1(wide)": return 8
        default: return nil
        }
    }

    private func activeAudioChannels(
        filePath: String,
        stream: MP4ValidationAudioStream,
        formatDuration: TimeInterval?,
        fullScan: Bool
    ) async -> Set<Int>? {
        let duration = formatDuration ?? stream.duration.flatMap(TimeInterval.init)
        let sampleWindows: [(start: TimeInterval, duration: TimeInterval)]

        if fullScan {
            sampleWindows = [(0, max(duration ?? 86_400, 1))]
        } else if let duration, duration > 30 {
            sampleWindows = [
                (0, 5),
                (max((duration / 2) - 2.5, 0), 5),
                (max(duration - 5, 0), 5)
            ]
        } else {
            sampleWindows = [(0, max(min(duration ?? 30, 30), 1))]
        }

        var activeChannels = Set<Int>()
        var completedSample = false

        for window in sampleWindows {
            if Task.isCancelled { return nil }

            let arguments = [
                "-hide_banner", "-nostats",
                "-ss", String(format: "%.3f", window.start),
                "-t", String(format: "%.3f", window.duration),
                "-i", filePath,
                "-map", "0:\(stream.index)",
                "-vn",
                "-af", "astats=metadata=0:reset=0",
                "-f", "null", "-"
            ]

            guard let output = await runProcessCaptureStderr(path: ffmpegPath, arguments: arguments) else {
                continue
            }
            completedSample = true
            activeChannels.formUnion(Self.activeChannels(inAstatsOutput: output))
        }

        return completedSample ? activeChannels : nil
    }

    nonisolated private static func activeChannels(inAstatsOutput output: String) -> Set<Int> {
        var activeChannels = Set<Int>()
        var currentChannel: Int?

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if let markerRange = line.range(of: "Channel: "),
               let channel = Int(line[markerRange.upperBound...].trimmingCharacters(in: .whitespaces)) {
                currentChannel = channel
                continue
            }

            guard let channel = currentChannel,
                  let markerRange = line.range(of: "RMS level dB: ") else {
                continue
            }

            let valueText = line[markerRange.upperBound...].trimmingCharacters(in: .whitespaces)
            if let rms = Double(valueText), rms > -90 {
                activeChannels.insert(channel)
            }
            currentChannel = nil
        }

        return activeChannels
    }

    private func isAppleCompatibleAudioCodec(_ codec: String) -> Bool {
        [
            "aac",
            "alac",
            "mp3",
            "ac3",
            "eac3"
        ].contains(codec)
    }

    private func isDTSAudioCodec(_ codec: String) -> Bool {
        codec.contains("dts") || codec.contains("dca")
    }

    private func isFloatingPointPCMAudio(_ stream: MP4ValidationAudioStream) -> Bool {
        let codec = normalizedProbeValue(stream.codecName)
        let codecTag = normalizedProbeValue(stream.codecTagString)
        let sampleFormat = normalizedProbeValue(stream.sampleFormat)

        let hasFloatCodec = codec.contains("float") || codec.hasPrefix("pcm_f")
        let hasFloatTag = codecTag.contains("float")
            || codecTag.contains("fl32")
            || codecTag.contains("fl64")
            || codecTag.contains("f32")
            || codecTag.contains("f64")
        let hasFloatSampleFormat = sampleFormat.contains("float")
            || sampleFormat.contains("flt")
            || sampleFormat.contains("dbl")

        return (codec.hasPrefix("pcm_") || hasFloatCodec || hasFloatTag) && hasFloatSampleFormat
    }

    private func normalizedProbeValue(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private func displayProbeValue(_ value: String?) -> String {
        let normalizedValue = normalizedProbeValue(value)
        return normalizedValue.isEmpty ? "unknown" : normalizedValue
    }

    private func validationETA(elapsed: TimeInterval, completedCount: Int, totalCount: Int) -> String {
        guard completedCount > 0, totalCount > completedCount else {
            return "(ETA calculating...)"
        }

        let averageSecondsPerFile = elapsed / Double(completedCount)
        let remainingSeconds = averageSecondsPerFile * Double(totalCount - completedCount)
        return "(ETA \(Self.formatDuration(remainingSeconds)))"
    }

    nonisolated private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }

        return "\(seconds)s"
    }

    nonisolated private static func collectMP4FilesRecursively(in rootPath: String) -> [(relativePath: String, fullPath: String)] {
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

    private func runProcessCaptureStderr(path: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                let errorPipe = Pipe()
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errorPipe

                do {
                    self.processLock.lock()
                    self.currentProcess = process
                    self.processLock.unlock()

                    try process.run()
                    let outputData = errorPipe.fileHandleForReading.readDataToEndOfFile()
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

                    continuation.resume(returning: String(data: outputData, encoding: .utf8))
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

    private func locateMediaTools() {
        ffprobePath = Self.findBundledBinary(named: "ffprobe")
            ?? Self.findInPath(command: "ffprobe")
            ?? ""
        ffprobeAvailable = !ffprobePath.isEmpty

        ffmpegPath = Self.findBundledBinary(named: "ffmpeg")
            ?? Self.findInPath(command: "ffmpeg")
            ?? ""
        ffmpegAvailable = !ffmpegPath.isEmpty
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
