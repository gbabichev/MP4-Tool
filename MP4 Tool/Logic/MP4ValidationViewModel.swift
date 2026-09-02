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

enum MP4AudioRepairKind: Equatable {
    case downmixToStereo
    case extractChannelToMono(Int)
    case restoreLayout(String)
}

struct MP4AudioRepairCandidate: Equatable {
    let streamIndex: Int
    let audioIndex: Int
    let kind: MP4AudioRepairKind
}

private struct MP4ValidationAudioAuthoringAnalysis {
    let errors: [String]
    let warnings: [String]
    let repairCandidates: [MP4AudioRepairCandidate]
    let needsMetadataRepair: Bool
}

private enum MP4AudioChannelScanDepth {
    case quick
    case confirmation
    case full
}

enum MP4ValidationSeverity {
    case warning
    case error
}

private struct MP4ValidationFinding {
    let message: String
    let assessment: String
    let severity: MP4ValidationSeverity
    let repairCandidates: [MP4AudioRepairCandidate]
    let needsAudioMetadataRepair: Bool
}

struct MP4ValidationResult: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let issue: String?
    let assessment: String
    let severity: MP4ValidationSeverity?
    let repairCandidates: [MP4AudioRepairCandidate]
    let needsAudioMetadataRepair: Bool
    var repairMessage: String? = nil

    var isFlagged: Bool {
        issue != nil
    }

    var isRepairable: Bool {
        needsAudioMetadataRepair || !repairCandidates.isEmpty
    }
}

@MainActor
final class MP4ValidationViewModel: ObservableObject {
    @Published var inputFolderPath: String = ""
    @Published var isScanning = false
    @Published var isRepairing = false
    @Published var scanProgress = ""
    @Published var scanAlertText = ""
    @Published var operationProgressFraction: Double = 0
    @Published var operationCurrentItem = 0
    @Published var operationTotalItems = 0
    @Published var operationEstimatedRemaining: TimeInterval?
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
            if droppedFilePaths.count == 1 {
                return droppedFilePaths[0]
            }
            return "\(droppedFilePaths.count) selected MP4 files"
        }
        return inputFolderPath.isEmpty
            ? "Select an MP4 file or folder, or drop MP4 files here"
            : inputFolderPath
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

    var canExportAll: Bool {
        !isScanning && !isRepairing && !results.isEmpty
    }

    var canSendFlaggedToMainApp: Bool {
        !isScanning && !isRepairing && !flaggedResults.isEmpty
    }

    init() {
        locateMediaTools()
    }

    func selectInput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.message = "Choose one MP4 file or a folder containing MP4 files"

        CleanFilePanelPresenter.present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                return
            }
            if isDirectory.boolValue {
                _ = self.setInputFolder(url: url)
            } else {
                self.droppedFilePaths = []
                if self.setDroppedFiles(urls: [url]) {
                    self.scanAlertText = "Ready to validate the selected MP4 file."
                }
            }
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
        results = []
        scanProgress = ""
        scanAlertText = "Ready to validate MP4 files in the selected folder."
        return true
    }

    func setInput(url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        if isDirectory.boolValue {
            return setInputFolder(url: url)
        }

        droppedFilePaths = []
        return setDroppedFiles(urls: [url])
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
        scanProgress = "Validation canceled."
        isScanning = false
    }

    func repairSelected(
        resultIDs: Set<UUID>,
        useOriginalFilename: Bool,
        customOutputFolderPath: String?
    ) {
        guard !isScanning, !isRepairing else { return }
        guard ffmpegAvailable else {
            scanAlertText = "FFmpeg is required to repair selected files."
            return
        }
        let selectedResults = results.filter {
            resultIDs.contains($0.id) && $0.isRepairable
        }
        guard !selectedResults.isEmpty else {
            scanAlertText = "Select at least one repairable audio warning."
            return
        }

        let resolvedCustomOutputFolderPath: String?
        if let customOutputFolderPath, !customOutputFolderPath.isEmpty {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: customOutputFolderPath,
                isDirectory: &isDirectory
            ), isDirectory.boolValue,
            FileManager.default.isWritableFile(atPath: customOutputFolderPath) else {
                scanAlertText = "Choose a writable folder for repaired files."
                return
            }
            resolvedCustomOutputFolderPath = customOutputFolderPath
        } else {
            resolvedCustomOutputFolderPath = nil
        }

        isRepairing = true
        scanAlertText = ""
        resetOperationProgress(totalItems: selectedResults.count)
        repairTask?.cancel()
        repairTask = Task {
            await runRepairs(
                selectedResults,
                useOriginalFilename: useOriginalFilename,
                customOutputFolderPath: resolvedCustomOutputFolderPath
            )
        }
    }

    func cancelRepair() {
        guard isRepairing else { return }
        repairTask?.cancel()
        terminateCurrentProcess()
        scanProgress = "Repair canceled."
        isRepairing = false
    }

    private func runRepairs(
        _ selectedResults: [MP4ValidationResult],
        useOriginalFilename: Bool,
        customOutputFolderPath: String?
    ) async {
        let sleepAssertion = SystemSleepAssertion(reason: "MP4 Tool is repairing MP4 files")
        defer { sleepAssertion.invalidate() }

        var repairedCount = 0
        var skippedCount = 0
        let operationStartedAt = Date()

        for (index, result) in selectedResults.enumerated() {
            if Task.isCancelled {
                scanProgress = "Repair canceled."
                isRepairing = false
                return
            }

            updateOperationProgress(
                currentItem: index + 1,
                totalItems: selectedResults.count,
                startedAt: operationStartedAt
            )
            scanProgress = "Repairing \(index + 1)/\(selectedResults.count): \(result.fileName)"
            if result.repairCandidates.isEmpty {
                updateRepairMessage(for: result.id, message: "Preparing audio metadata repair…")
            } else {
                updateRepairMessage(
                    for: result.id,
                    message: "Confirming channel activity across the full audio track…"
                )
            }

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
                        scanDepth: .full
                      ) else {
                    continue
                }
                switch candidate.kind {
                case .downmixToStereo where activeChannels == Set([1, 2]):
                    confirmedCandidates.append(candidate)
                case .extractChannelToMono(let channel) where activeChannels == Set([channel]):
                    confirmedCandidates.append(candidate)
                case .restoreLayout where activeChannels.count > 2:
                    confirmedCandidates.append(candidate)
                default:
                    break
                }
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
                    message: "Repair skipped: the full-track channel scan did not confirm the expected audio layout."
                )
                continue
            }

            let inputURL = URL(fileURLWithPath: result.filePath)
            let destinationDirectoryURL = customOutputFolderPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? inputURL.deletingLastPathComponent()
            let replacesOriginal = useOriginalFilename && customOutputFolderPath == nil
            let outputFileName = useOriginalFilename
                ? inputURL.lastPathComponent
                : inputURL.deletingPathExtension().lastPathComponent + "_fixed.mp4"
            let outputURL = destinationDirectoryURL.appendingPathComponent(outputFileName)

            guard replacesOriginal || !FileManager.default.fileExists(atPath: outputURL.path) else {
                skippedCount += 1
                updateRepairMessage(
                    for: result.id,
                    message: "Repair skipped: \(outputURL.lastPathComponent) already exists."
                )
                continue
            }

            let temporaryURL = destinationDirectoryURL.appendingPathComponent(
                ".mp4tool-audio-repair-\(UUID().uuidString).mp4"
            )
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            updateRepairMessage(
                for: result.id,
                message: confirmedCandidates.isEmpty
                    ? "Normalizing audio defaults and track titles…"
                    : "Repairing malformed audio and normalizing its metadata…"
            )
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

            let defaultAudioIndexes = compatibility.streams.indices.filter {
                compatibility.streams[$0].disposition?.isDefault == 1
            }
            if defaultAudioIndexes.count > 1, let retainedDefaultIndex = defaultAudioIndexes.first {
                for audioIndex in compatibility.streams.indices {
                    arguments.append(
                        contentsOf: [
                            "-disposition:a:\(audioIndex)",
                            audioIndex == retainedDefaultIndex ? "+default" : "-default"
                        ]
                    )
                }
            }

            for audioIndex in compatibility.streams.indices {
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
                switch candidate.kind {
                case .downmixToStereo:
                    arguments.append(contentsOf: [
                        "-filter:a:\(candidate.audioIndex)", "pan=stereo|c0=FL|c1=FR",
                        "-c:a:\(candidate.audioIndex)", "aac",
                        "-b:a:\(candidate.audioIndex)", "192k",
                        "-channel_layout:a:\(candidate.audioIndex)", "stereo"
                    ])
                case .extractChannelToMono(let channel):
                    arguments.append(contentsOf: [
                        "-filter:a:\(candidate.audioIndex)", "pan=mono|c0=c\(max(channel - 1, 0))",
                        "-c:a:\(candidate.audioIndex)", "aac",
                        "-b:a:\(candidate.audioIndex)", "128k",
                        "-channel_layout:a:\(candidate.audioIndex)", "mono"
                    ])
                case .restoreLayout(let layout):
                    let bitrate = layout == "7.1" ? "512k" : "256k"
                    arguments.append(contentsOf: [
                        "-c:a:\(candidate.audioIndex)", "aac",
                        "-b:a:\(candidate.audioIndex)", bitrate,
                        "-channel_layout:a:\(candidate.audioIndex)", layout
                    ])
                }
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
                    guard repairedCompatibility.streams.indices.contains(candidate.audioIndex) else {
                        return false
                    }
                    let repairedStream = repairedCompatibility.streams[candidate.audioIndex]
                    switch candidate.kind {
                    case .downmixToStereo:
                        return repairedStream.channels == 2
                            && normalizedProbeValue(repairedStream.channelLayout) == "stereo"
                    case .extractChannelToMono:
                        return repairedStream.channels == 1
                            && normalizedProbeValue(repairedStream.channelLayout) == "mono"
                    case .restoreLayout(let layout):
                        return normalizedProbeValue(repairedStream.channelLayout)
                            == normalizedProbeValue(layout)
                    }
                  }) else {
                skippedCount += 1
                updateRepairMessage(for: result.id, message: "Repair failed validation; the original was untouched.")
                continue
            }

            let repairedAsset = AVURLAsset(url: temporaryURL)
            let appleAudioTracks = (try? await repairedAsset.loadTracks(withMediaType: .audio)) ?? []
            guard !appleAudioTracks.isEmpty,
                  (try? await repairedAsset.load(.isPlayable)) == true else {
                skippedCount += 1
                updateRepairMessage(
                    for: result.id,
                    message: "Repair failed Apple playback validation; the original was untouched."
                )
                continue
            }

            do {
                if replacesOriginal {
                    _ = try FileManager.default.replaceItemAt(inputURL, withItemAt: temporaryURL)
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
                }
                repairedCount += 1
                updateRepairMessage(
                    for: result.id,
                    message: replacesOriginal
                        ? "Replaced original after validation"
                        : "Saved \(outputURL.lastPathComponent)"
                )
            } catch {
                skippedCount += 1
                updateRepairMessage(for: result.id, message: "Repair failed: \(error.localizedDescription)")
            }
        }

        isRepairing = false
        scanProgress = "Repair complete: \(repairedCount) saved, \(skippedCount) skipped or failed."
        if repairedCount == 0 {
            scanAlertText = "No repaired files were created."
        } else if useOriginalFilename && customOutputFolderPath == nil {
            scanAlertText = "Repaired originals were replaced only after validation succeeded."
        } else if let customOutputFolderPath {
            scanAlertText = useOriginalFilename
                ? "Repaired files were saved to \(customOutputFolderPath) with their original filenames."
                : "Repaired files were saved to \(customOutputFolderPath) with _fixed filenames."
        } else {
            scanAlertText = "Repaired files were saved beside their originals with _fixed filenames."
        }
    }

    private func updateRepairMessage(for resultID: UUID, message: String) {
        guard let index = results.firstIndex(where: { $0.id == resultID }) else { return }
        results[index].repairMessage = message
    }

    private func repairedAudioTrackNames(
        compatibility: MP4ValidationAudioCompatibility,
        repairedCandidates: [MP4AudioRepairCandidate]
    ) -> [Int: String] {
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

                let technicalName: String
                if let repairedCandidate = repairedCandidates.first(where: { $0.audioIndex == audioIndex }) {
                    switch repairedCandidate.kind {
                    case .downmixToStereo:
                        technicalName = "Stereo (Repaired AAC)"
                    case .extractChannelToMono:
                        technicalName = "Mono (Repaired AAC)"
                    case .restoreLayout(let layout):
                        technicalName = "\(displayAudioLayout(layout)) (Repaired AAC)"
                    }
                } else if let layout = stream.channelLayout, !layout.isEmpty {
                    let layoutName = displayAudioLayout(layout)
                    let codecName = displayAudioCodec(stream.codecName)
                    technicalName = codecName.isEmpty
                        ? layoutName
                        : "\(layoutName) (\(codecName))"
                } else if let channels = stream.channels {
                    let codecName = displayAudioCodec(stream.codecName)
                    let channelName = "\(channels) Channel"
                    technicalName = codecName.isEmpty
                        ? channelName
                        : "\(channelName) (\(codecName))"
                } else {
                    technicalName = displayAudioCodec(stream.codecName).isEmpty
                        ? "Track"
                        : displayAudioCodec(stream.codecName)
                }

                let baseName = "\(languageName) — \(technicalName)"
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

    private func displayAudioLayout(_ layout: String) -> String {
        switch normalizedProbeValue(layout) {
        case "mono": return "Mono"
        case "stereo": return "Stereo"
        case "5.1(side)": return "5.1"
        default: return layout.uppercased()
        }
    }

    private func displayAudioCodec(_ codec: String?) -> String {
        switch normalizedProbeValue(codec) {
        case "aac": return "AAC"
        case "ac3": return "AC-3"
        case "eac3": return "E-AC-3"
        case "alac": return "ALAC"
        case "mp3": return "MP3"
        default: return codec?.uppercased() ?? ""
        }
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

    func exportCSVReport(includeAll: Bool) {
        let sourceResults = includeAll ? results : flaggedResults
        let reportRows = sourceResults.map { result in
            (
                itemName: URL(fileURLWithPath: result.filePath).lastPathComponent,
                path: result.filePath,
                error: result.issue ?? "",
                assessment: result.assessment
            )
        }
        guard !reportRows.isEmpty else {
            scanAlertText = includeAll ? "No results to export." : "No issues to export."
            return
        }

        let hostWindow = makeHiddenChromeHostWindow()
        exportDialogHostWindow = hostWindow
        hostWindow.makeKeyAndOrderFront(nil)

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = includeAll
            ? "mp4-validation-all.csv" : "mp4-validation-issues.csv"

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

                let header = ["Item Name", "Path", "Error", "Assessment"]
                    .map(self.csvField)
                    .joined(separator: ",")
                let rows = reportRows.map { row in
                    [row.itemName, row.path, row.error, row.assessment]
                        .map(self.csvField)
                        .joined(separator: ",")
                }
                let body = "\u{FEFF}" + ([header] + rows).joined(separator: "\r\n") + "\r\n"

                do {
                    try body.write(to: url, atomically: true, encoding: .utf8)
                    let scope = includeAll ? "result" : "issue"
                    self.scanAlertText = "Exported \(reportRows.count) validation \(scope)(s) to \(url.path)."
                } catch {
                    self.scanAlertText = "Failed to export CSV report: \(error.localizedDescription)"
                }
            }
        }
    }

    private func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
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
            scanProgress = "Preparing selected MP4 files..."
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
        resetOperationProgress(totalItems: files.count)
        for (index, fileInfo) in files.enumerated() {
            if Task.isCancelled || token != scanToken {
                scanProgress = "Validation canceled."
                isScanning = false
                return
            }

            updateOperationProgress(
                currentItem: index + 1,
                totalItems: files.count,
                startedAt: scanStartDate
            )
            scanProgress = "Validating \(index + 1)/\(files.count): \(fileInfo.relativePath)"

            let finding = await validationFinding(filePath: fileInfo.fullPath)
            results.append(
                MP4ValidationResult(
                    fileName: fileInfo.relativePath,
                    filePath: fileInfo.fullPath,
                    issue: finding?.message,
                    assessment: finding?.assessment ?? "No action needed.",
                    severity: finding?.severity,
                    repairCandidates: finding?.repairCandidates ?? [],
                    needsAudioMetadataRepair: finding?.needsAudioMetadataRepair ?? false
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

    private func validationFinding(filePath: String) async -> MP4ValidationFinding? {
        var reasons: [String] = []
        var warnings: [String] = []
        var repairCandidates: [MP4AudioRepairCandidate] = []
        var needsAudioMetadataRepair = false
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
                reasons.append(contentsOf: authoringAnalysis.errors)
                warnings.append(contentsOf: authoringAnalysis.warnings)
                repairCandidates = authoringAnalysis.repairCandidates
                needsAudioMetadataRepair = authoringAnalysis.needsMetadataRepair
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

        let assessment = validationAssessment(
            reasons: reasons,
            warnings: warnings,
            repairCandidates: repairCandidates,
            needsAudioMetadataRepair: needsAudioMetadataRepair
        )

        if !reasons.isEmpty {
            let allFindings = reasons + warnings
            return MP4ValidationFinding(
                message: allFindings.joined(separator: ", "),
                assessment: assessment,
                severity: .error,
                repairCandidates: repairCandidates,
                needsAudioMetadataRepair: needsAudioMetadataRepair
            )
        }

        guard !warnings.isEmpty else { return nil }
        return MP4ValidationFinding(
            message: warnings.joined(separator: ", "),
            assessment: assessment,
            severity: .warning,
            repairCandidates: repairCandidates,
            needsAudioMetadataRepair: needsAudioMetadataRepair
        )
    }

    private func validationAssessment(
        reasons: [String],
        warnings: [String],
        repairCandidates: [MP4AudioRepairCandidate],
        needsAudioMetadataRepair: Bool
    ) -> String {
        let findings = (reasons + warnings).joined(separator: " ").lowercased()
        var actions: [String] = []

        if needsAudioMetadataRepair {
            actions.append("Automatic repair available: normalize audio defaults and assign distinct track titles.")
        }

        for candidate in repairCandidates {
            let action: String
            switch candidate.kind {
            case .downmixToStereo:
                action = "Automatic repair available: convert the malformed multichannel track to stereo AAC."
            case .extractChannelToMono:
                action = "Automatic repair available: preserve the only active channel as a proper mono AAC track."
            case .restoreLayout:
                action = "Automatic repair available: restore the missing channel layout."
            }
            if !actions.contains(action) {
                actions.append(action)
            }
        }

        if findings.contains("appears truncated") {
            actions.append("Use a complete source or re-encode from the source; missing audio cannot be reconstructed.")
        } else if findings.contains("unsupported video codec") {
            actions.append("Send the file to the main queue and re-encode its video to H.264 or H.265.")
        }

        if findings.contains("dts audio")
            || findings.contains("pcm float audio")
            || findings.contains("unsupported audio codec")
            || findings.contains("audio not readable by apple") {
            actions.append("Send the file to the main queue and re-encode its audio to AAC.")
        } else if findings.contains("missing audio") {
            actions.append("Return to the source or use Track Editor to add a valid audio track.")
        }

        if findings.contains("not playable") || findings.contains("could not be opened") {
            actions.append("Remux or re-encode from a known-good source, then validate the new output.")
        }

        if findings.contains("starts at") || findings.contains("after the file ends") {
            actions.append("Review synchronization in a player; remux or re-encode from the source if playback is affected.")
        }

        if findings.contains("contain signal") && repairCandidates.isEmpty {
            actions.append("Review the suspect track in Track Editor; remove it if redundant, otherwise re-encode from the source.")
        }

        if actions.isEmpty {
            actions.append("Review the flagged tracks in Track Editor before deciding whether to keep or remove them.")
        }

        return actions.joined(separator: " ")
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
            return MP4ValidationAudioAuthoringAnalysis(
                errors: [],
                warnings: [],
                repairCandidates: [],
                needsMetadataRepair: false
            )
        }

        var errors: [String] = []
        var warnings: [String] = []
        var repairCandidates: [MP4AudioRepairCandidate] = []
        var needsMetadataRepair = false

        let defaultStreams = streams.filter { $0.disposition?.isDefault == 1 }
        if defaultStreams.count > 1 {
            warnings.append("multiple default audio tracks")
            needsMetadataRepair = true
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
                needsMetadataRepair = true
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
               formatDuration > 0 {
                let audioStartTime = stream.startTime.flatMap(TimeInterval.init) ?? 0
                let audioEndTime = audioStartTime + audioDuration
                let durationDifference = formatDuration - audioEndTime
                if durationDifference > 0 {
                    // Short gaps commonly represent silent lead-outs or credits. Scale the
                    // tolerance for shorter media while capping it at five minutes for films.
                    let earlyEndTolerance = min(max(formatDuration * 0.10, 60), 300)
                    if durationDifference > earlyEndTolerance {
                        let differenceDescription = String(format: "%.1f", durationDifference)
                        let percentageDescription = String(
                            format: "%.1f%%",
                            (durationDifference / formatDuration) * 100
                        )
                        errors.append(
                            "audio stream \(stream.index) appears truncated, ending \(differenceDescription) seconds (\(percentageDescription)) early"
                        )
                    }
                } else {
                    let overrun = abs(durationDifference)
                    let endOverrunTolerance = max(10, formatDuration * 0.01)
                    if overrun > endOverrunTolerance {
                        let differenceDescription = String(format: "%.1f", overrun)
                        warnings.append(
                            "audio stream \(stream.index) ends \(differenceDescription) seconds after the file ends"
                        )
                    }
                }
            }

            if let startTime = stream.startTime.flatMap(TimeInterval.init) {
                // Brief delayed starts are common around studio cards and silent openings.
                let startTolerance = compatibility.formatDuration.map {
                    min(max($0 * 0.01, 5), 30)
                } ?? 30
                if startTime > startTolerance {
                    warnings.append(
                        "audio stream \(stream.index) starts at \(String(format: "%.2f", startTime)) seconds"
                    )
                }
            }

            guard ffmpegAvailable, channelCount >= 4 else { continue }
            if var activeChannels = await activeAudioChannels(
                filePath: filePath,
                stream: stream,
                formatDuration: compatibility.formatDuration,
                scanDepth: .quick
            ), !activeChannels.isEmpty {
                if activeChannels.count <= 2,
                   let confirmedChannels = await activeAudioChannels(
                    filePath: filePath,
                    stream: stream,
                    formatDuration: compatibility.formatDuration,
                    scanDepth: .confirmation
                   ), !confirmedChannels.isEmpty {
                    activeChannels = confirmedChannels
                }

                if activeChannels.count <= 2 {
                    let activityDescription = activeChannels.count == 1
                        ? "only 1 channel contains signal"
                        : "only \(activeChannels.count) channels contain signal"
                    warnings.append(
                        "audio stream \(stream.index) claims \(channelCount) channels but \(activityDescription)"
                    )
                    if activeChannels == Set([1, 2]) {
                        repairCandidates.append(
                            MP4AudioRepairCandidate(
                                streamIndex: stream.index,
                                audioIndex: audioIndex,
                                kind: .downmixToStereo
                            )
                        )
                    } else if activeChannels.count == 1, let channel = activeChannels.first {
                        repairCandidates.append(
                            MP4AudioRepairCandidate(
                                streamIndex: stream.index,
                                audioIndex: audioIndex,
                                kind: .extractChannelToMono(channel)
                            )
                        )
                    }
                } else if normalizedProbeValue(stream.channelLayout).isEmpty,
                          let inferredLayout = inferredChannelLayout(channelCount: channelCount) {
                    repairCandidates.append(
                        MP4AudioRepairCandidate(
                            streamIndex: stream.index,
                            audioIndex: audioIndex,
                            kind: .restoreLayout(inferredLayout)
                        )
                    )
                }
            }
        }

        var uniqueErrors: [String] = []
        for error in errors where !uniqueErrors.contains(error) {
            uniqueErrors.append(error)
        }
        var uniqueWarnings: [String] = []
        for warning in warnings where !uniqueWarnings.contains(warning) {
            uniqueWarnings.append(warning)
        }
        return MP4ValidationAudioAuthoringAnalysis(
            errors: uniqueErrors,
            warnings: uniqueWarnings,
            repairCandidates: repairCandidates,
            needsMetadataRepair: needsMetadataRepair
        )
    }

    private func audioTrackName(_ stream: MP4ValidationAudioStream) -> String {
        let title = normalizedProbeValue(stream.tags?["title"])
        if !title.isEmpty {
            return title
        }
        return normalizedProbeValue(stream.tags?["handler_name"])
    }

    private func inferredChannelLayout(channelCount: Int) -> String? {
        switch channelCount {
        case 6: return "5.1"
        case 8: return "7.1"
        default: return nil
        }
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
        scanDepth: MP4AudioChannelScanDepth
    ) async -> Set<Int>? {
        let duration = formatDuration ?? stream.duration.flatMap(TimeInterval.init)
        let sampleWindows: [(start: TimeInterval, duration: TimeInterval)]

        switch scanDepth {
        case .full:
            sampleWindows = [(0, max(duration ?? 86_400, 1))]
        case .confirmation:
            if let duration, duration > 90 {
                sampleWindows = [0.2, 0.5, 0.8].map { position in
                    (max((duration * position) - 15, 0), 30)
                }
            } else {
                sampleWindows = [(0, max(min(duration ?? 90, 90), 1))]
            }
        case .quick:
            if let duration, duration > 30 {
                sampleWindows = [
                    (0, 5),
                    (max((duration / 2) - 2.5, 0), 5),
                    (max(duration - 5, 0), 5)
                ]
            } else {
                sampleWindows = [(0, max(min(duration ?? 30, 30), 1))]
            }
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
