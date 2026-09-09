import Foundation
import AppKit
import AVFoundation
import Combine
import Darwin
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
    let profile: String?
    let codecTagString: String?
    let sampleFormat: String?
    let bitRate: String?
    let channels: Int?
    let channelLayout: String?
    let startTime: String?
    let duration: String?
    let disposition: MP4ValidationStreamDisposition?
    let tags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case profile
        case codecTagString = "codec_tag_string"
        case sampleFormat = "sample_fmt"
        case bitRate = "bit_rate"
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
    let isCommentary: Int?
    let isVisualImpaired: Int?
    let isDub: Int?
    let isOriginal: Int?

    enum CodingKeys: String, CodingKey {
        case isDefault = "default"
        case isCommentary = "comment"
        case isVisualImpaired = "visual_impaired"
        case isDub = "dub"
        case isOriginal = "original"
    }
}

private struct MP4ValidationProbeFormat: Decodable {
    let duration: String?
}

private struct MP4ValidationContainerProbeOutput: Decodable {
    let streams: [MP4ValidationContainerStream]
    let chapters: [MP4ValidationChapter]?
}

private struct MP4ValidationContainerStream: Decodable {
    let index: Int
    let codecType: String?
    let codecTagString: String?
    let startTime: String?
    let duration: String?
    let tags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecTagString = "codec_tag_string"
        case startTime = "start_time"
        case duration
        case tags
    }
}

private struct MP4ValidationChapter: Decodable {
    let startTime: String?
    let endTime: String?

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

private struct MP4ValidationContainerAnalysis {
    let issues: [String]
    let needsMediaOnlyRemux: Bool
}

private nonisolated struct MP4ValidationFileIdentity: Sendable {
    let size: UInt64
    let modificationDate: Date
}

private nonisolated struct MP4ValidationRepairCandidateSnapshot: Codable, Sendable {
    let streamIndex: Int
    let audioIndex: Int
    let kind: String
    let value: String?

    init(_ candidate: MP4AudioRepairCandidate) {
        streamIndex = candidate.streamIndex
        audioIndex = candidate.audioIndex
        switch candidate.kind {
        case .downmixToStereo:
            kind = "downmixToStereo"
            value = nil
        case .extractChannelToMono(let channel):
            kind = "extractChannelToMono"
            value = String(channel)
        case .restoreLayout(let layout):
            kind = "restoreLayout"
            value = layout
        }
    }

    var repairCandidate: MP4AudioRepairCandidate? {
        let repairKind: MP4AudioRepairKind
        switch kind {
        case "downmixToStereo":
            repairKind = .downmixToStereo
        case "extractChannelToMono":
            guard let value, let channel = Int(value) else { return nil }
            repairKind = .extractChannelToMono(channel)
        case "restoreLayout":
            guard let value, !value.isEmpty else { return nil }
            repairKind = .restoreLayout(value)
        default:
            return nil
        }
        return MP4AudioRepairCandidate(
            streamIndex: streamIndex,
            audioIndex: audioIndex,
            kind: repairKind
        )
    }
}

private nonisolated struct MP4ValidationResultSnapshot: Codable, Sendable {
    let fileName: String
    let filePath: String
    let issue: String?
    let assessment: String
    let severity: String?
    let repairCandidates: [MP4ValidationRepairCandidateSnapshot]
    let needsAudioMetadataRepair: Bool
    let audioStreamIndexesToRemove: Set<Int>
    let subtitleStreamIndexesToRemove: Set<Int>
    let preferredSubtitleStreamIndex: Int?
    let needsContainerRemux: Bool
    let sourceFileSize: UInt64
    let sourceModificationDate: Date
    let repairCompleted: Bool?

    init(_ result: MP4ValidationResult) {
        fileName = result.fileName
        filePath = result.filePath
        issue = result.issue
        assessment = result.assessment
        switch result.severity {
        case .warning: severity = "warning"
        case .error: severity = "error"
        case nil: severity = nil
        }
        repairCandidates = result.repairCandidates.map(MP4ValidationRepairCandidateSnapshot.init)
        needsAudioMetadataRepair = result.needsAudioMetadataRepair
        audioStreamIndexesToRemove = result.audioStreamIndexesToRemove
        subtitleStreamIndexesToRemove = result.subtitleStreamIndexesToRemove
        preferredSubtitleStreamIndex = result.preferredSubtitleStreamIndex
        needsContainerRemux = result.needsContainerRemux
        sourceFileSize = result.sourceFileSize
        sourceModificationDate = result.sourceModificationDate
        repairCompleted = result.repairCompleted
    }

    var validationResult: MP4ValidationResult {
        // Older saved scans may contain the former borderline "review" finding.
        // It is intentionally no longer considered a compatibility problem.
        let retainedFindings = issue?
            .components(separatedBy: ", ")
            .filter { !$0.localizedCaseInsensitiveContains("audio quality: review recommended") }
        let migratedIssue = retainedFindings.flatMap { findings in
            findings.isEmpty ? nil : findings.joined(separator: ", ")
        }

        return MP4ValidationResult(
            fileName: fileName,
            filePath: filePath,
            issue: migratedIssue,
            assessment: migratedIssue == nil ? "No action needed." : assessment,
            severity: migratedIssue == nil
                ? nil
                : severity == "warning" ? .warning : severity == "error" ? .error : nil,
            repairCandidates: repairCandidates.compactMap(\.repairCandidate),
            needsAudioMetadataRepair: needsAudioMetadataRepair,
            audioStreamIndexesToRemove: audioStreamIndexesToRemove,
            subtitleStreamIndexesToRemove: subtitleStreamIndexesToRemove,
            preferredSubtitleStreamIndex: preferredSubtitleStreamIndex,
            needsContainerRemux: needsContainerRemux,
            sourceFileSize: sourceFileSize,
            sourceModificationDate: sourceModificationDate,
            repairCompleted: repairCompleted ?? false,
            repairMessage: repairCompleted == true
                ? "Repair completed before this scan was saved"
                : nil
        )
    }
}

private nonisolated struct MP4ValidationScanSnapshot: Codable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let createdAt: Date
    let appVersion: String
    let inputFolderPath: String
    let droppedFilePaths: [String]
    let results: [MP4ValidationResultSnapshot]
}

private nonisolated final class MP4ValidationProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var process: Process?

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldStop = isCancelled
        lock.unlock()

        if shouldStop {
            Self.stop(process)
        }
    }

    func stopIfCancelled() {
        lock.lock()
        let shouldStop = isCancelled
        let process = process
        lock.unlock()

        if shouldStop, let process {
            Self.stop(process)
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let process = process
        lock.unlock()

        if let process {
            Self.stop(process)
        }
    }

    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let processIdentifier = process.processIdentifier
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            guard process.isRunning else { return }
            Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}

private struct MP4ValidationAudioCompatibility {
    let hasAudioStreams: Bool
    let issues: [String]
    let streams: [MP4ValidationAudioStream]
    let formatDuration: TimeInterval?
}

nonisolated enum MP4AudioRepairKind: Equatable, Sendable {
    case downmixToStereo
    case extractChannelToMono(Int)
    case restoreLayout(String)
}

nonisolated struct MP4AudioRepairCandidate: Equatable, Sendable {
    let streamIndex: Int
    let audioIndex: Int
    let kind: MP4AudioRepairKind
}

private struct MP4ValidationAudioAuthoringAnalysis {
    let errors: [String]
    let warnings: [String]
    let repairCandidates: [MP4AudioRepairCandidate]
    let needsMetadataRepair: Bool
    let audioStreamIndexesToRemove: Set<Int>
}

private struct MP4ValidationSubtitleAuthoringAnalysis {
    let warnings: [String]
    let streamIndexesToRemove: Set<Int>
    let preferredStreamIndex: Int?
    let rationale: String?
    let streams: [VideoStream]
}

private enum MP4AudioChannelScanDepth {
    case quick
    case confirmation
    case full
}

nonisolated enum MP4ValidationSeverity: Sendable {
    case warning
    case error
}

private struct MP4ValidationFinding {
    let message: String
    let assessment: String
    let severity: MP4ValidationSeverity
    let repairCandidates: [MP4AudioRepairCandidate]
    let needsAudioMetadataRepair: Bool
    let audioStreamIndexesToRemove: Set<Int>
    let subtitleStreamIndexesToRemove: Set<Int>
    let preferredSubtitleStreamIndex: Int?
    let needsContainerRemux: Bool
}

nonisolated struct MP4ValidationResult: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let issue: String?
    let assessment: String
    let severity: MP4ValidationSeverity?
    let repairCandidates: [MP4AudioRepairCandidate]
    let needsAudioMetadataRepair: Bool
    let audioStreamIndexesToRemove: Set<Int>
    let subtitleStreamIndexesToRemove: Set<Int>
    let preferredSubtitleStreamIndex: Int?
    let needsContainerRemux: Bool
    let sourceFileSize: UInt64
    let sourceModificationDate: Date
    var repairCompleted = false
    var repairMessage: String? = nil

    var isFlagged: Bool {
        issue != nil
    }

    var isRepairable: Bool {
        !repairCompleted && (
            needsAudioMetadataRepair
                || !repairCandidates.isEmpty
                || !audioStreamIndexesToRemove.isEmpty
                || !subtitleStreamIndexesToRemove.isEmpty
                || needsContainerRemux
        )
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

    var canImportSnapshot: Bool {
        !isScanning && !isRepairing
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
        panel.allowedContentTypes = [.mpeg4Movie, .folder]
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
            scanAlertText = "Select at least one repairable issue."
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
        // Keep the operation active until the worker has actually unwound. This
        // prevents a second repair from starting while a slow network write is
        // still being terminated in the background.
        scanProgress = "Stopping repair…"
    }

    func resetAll() {
        scanTask?.cancel()
        repairTask?.cancel()
        scanToken = UUID()
        terminateCurrentProcess()
        inputFolderPath = ""
        droppedFilePaths = []
        results = []
        scanProgress = ""
        scanAlertText = ""
        isScanning = false
        isRepairing = false
        resetOperationProgress()
    }

    func removeResult(id: UUID) {
        guard !isScanning && !isRepairing else { return }
        results.removeAll { $0.id == id }
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
            if result.needsContainerRemux {
                updateRepairMessage(for: result.id, message: "Preparing container repair…")
            } else if result.repairCandidates.isEmpty {
                updateRepairMessage(for: result.id, message: "Preparing audio metadata repair…")
            } else {
                updateRepairMessage(
                    for: result.id,
                    message: "Confirming channel activity across the full audio track…"
                )
            }

            if let mismatch = await Self.sourceMismatch(for: result) {
                skippedCount += 1
                updateRepairMessage(
                    for: result.id,
                    message: "Repair skipped: \(mismatch) Rescan this file first."
                )
                continue
            }

            guard let compatibility = await probeAudioCompatibility(filePath: result.filePath) else {
                skippedCount += 1
                updateRepairMessage(for: result.id, message: "Repair failed: could not inspect audio streams.")
                continue
            }

            let sourceSubtitleStreams = await probeSubtitleStreams(filePath: result.filePath) ?? []
            let availableSubtitleStreamIndexes = Set(
                sourceSubtitleStreams.map(\.index)
            )
            let subtitleStreamIndexesToRemove = result.subtitleStreamIndexesToRemove
                .intersection(availableSubtitleStreamIndexes)
            let retainedSubtitleStreams = sourceSubtitleStreams.filter {
                !subtitleStreamIndexesToRemove.contains($0.index)
            }

            let availableStreamIndexes = Set(compatibility.streams.map(\.index))
            let audioStreamIndexesToRemove = result.audioStreamIndexesToRemove
                .intersection(availableStreamIndexes)
            let retainedAudioPairs = compatibility.streams.enumerated().filter {
                !audioStreamIndexesToRemove.contains($0.element.index)
            }
            let retainedAudioIndexes = Set(retainedAudioPairs.map { $0.offset })
            let retainedRepairCandidates = result.repairCandidates.filter {
                retainedAudioIndexes.contains($0.audioIndex)
            }
            let outputAudioIndexBySourceAudioIndex = Dictionary(
                uniqueKeysWithValues: retainedAudioPairs.enumerated().map {
                    ($0.element.offset, $0.offset)
                }
            )

            var confirmedCandidates: [MP4AudioRepairCandidate] = []
            for candidate in retainedRepairCandidates {
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

            guard confirmedCandidates.count == retainedRepairCandidates.count else {
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

            let outputAlreadyExists = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: outputURL.path)
            }.value
            guard replacesOriginal || !outputAlreadyExists else {
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
            // SMB cleanup can block for a long time when a share is slow or has
            // disconnected. Never perform it on the main actor.
            defer { Self.removeFileInBackground(temporaryURL) }

            let repairStatusMessage: String
            if result.needsContainerRemux {
                repairStatusMessage = "Rebuilding the MP4 without malformed auxiliary tracks…"
            } else if !audioStreamIndexesToRemove.isEmpty && !subtitleStreamIndexesToRemove.isEmpty {
                repairStatusMessage = "Keeping the preferred English audio and subtitle tracks…"
            } else if !subtitleStreamIndexesToRemove.isEmpty {
                repairStatusMessage = "Keeping the best complete English subtitle track…"
            } else if !audioStreamIndexesToRemove.isEmpty {
                repairStatusMessage = "Keeping the preferred English audio and removing redundant tracks…"
            } else if confirmedCandidates.isEmpty {
                repairStatusMessage = "Normalizing audio defaults and track titles…"
            } else {
                repairStatusMessage = "Repairing malformed audio and normalizing its metadata…"
            }
            updateRepairMessage(for: result.id, message: repairStatusMessage)
            var arguments = [
                "-hide_banner", "-nostats", "-y",
                "-i", result.filePath
            ]
            if result.needsContainerRemux {
                arguments.append(contentsOf: [
                    "-map", "0:v:0",
                    "-map", "0:a?",
                    "-map", "0:s?"
                ])
            } else {
                arguments.append(contentsOf: ["-map", "0"])
            }
            arguments.append(contentsOf: [
                "-map_metadata", "0",
                "-map_chapters", result.needsContainerRemux ? "-1" : "0",
                "-c", "copy"
            ])

            for streamIndex in audioStreamIndexesToRemove.sorted() {
                arguments.append(contentsOf: ["-map", "-0:\(streamIndex)"])
            }
            for streamIndex in subtitleStreamIndexesToRemove.sorted() {
                arguments.append(contentsOf: ["-map", "-0:\(streamIndex)"])
            }

            let repairedTrackNames = audioStreamIndexesToRemove.isEmpty
                ? repairedAudioTrackNames(
                    compatibility: compatibility,
                    repairedCandidates: confirmedCandidates
                )
                : [:]

            let preferredRetainedSourceAudioIndex = retainedAudioPairs.first {
                AudioTrackSelectionPolicy.isEnglish(
                    audioSelectionCandidate($0.element, audioIndex: $0.offset)
                )
            }?.offset
                ?? retainedAudioPairs.first?.offset

            if !audioStreamIndexesToRemove.isEmpty,
               let preferredRetainedSourceAudioIndex {
                for (outputAudioIndex, pair) in retainedAudioPairs.enumerated() {
                    arguments.append(
                        contentsOf: [
                            "-disposition:a:\(outputAudioIndex)",
                            pair.offset == preferredRetainedSourceAudioIndex ? "+default" : "-default"
                        ]
                    )
                }
            } else {
                let defaultAudioIndexes = compatibility.streams.indices.filter {
                    compatibility.streams[$0].disposition?.isDefault == 1
                }
                if defaultAudioIndexes.count > 1, let retainedDefaultIndex = defaultAudioIndexes.first {
                    for (outputAudioIndex, pair) in retainedAudioPairs.enumerated() {
                        arguments.append(
                            contentsOf: [
                                "-disposition:a:\(outputAudioIndex)",
                                pair.offset == retainedDefaultIndex ? "+default" : "-default"
                            ]
                        )
                    }
                }
            }

            for (outputAudioIndex, pair) in retainedAudioPairs.enumerated() {
                if !audioStreamIndexesToRemove.isEmpty,
                   AudioTrackSelectionPolicy.isEnglish(
                    audioSelectionCandidate(pair.element, audioIndex: pair.offset)
                   ) {
                    arguments.append(
                        contentsOf: [
                            "-metadata:s:a:\(outputAudioIndex)", "title=",
                            "-metadata:s:a:\(outputAudioIndex)", "handler_name="
                        ]
                    )
                } else if let trackName = repairedTrackNames[pair.offset] {
                    arguments.append(
                        contentsOf: [
                            "-metadata:s:a:\(outputAudioIndex)", "title=\(trackName)",
                            "-metadata:s:a:\(outputAudioIndex)", "handler_name=\(trackName)"
                        ]
                    )
                }
            }

            if !subtitleStreamIndexesToRemove.isEmpty,
               let preferredSubtitleStreamIndex = result.preferredSubtitleStreamIndex {
                for (outputSubtitleIndex, stream) in retainedSubtitleStreams.enumerated() {
                    guard stream.index == preferredSubtitleStreamIndex else { continue }
                    let label = [stream.tags?["title"], stream.tags?["handler_name"]]
                        .compactMap { $0 }
                        .joined(separator: " ")
                        .lowercased()
                    let isForced = stream.disposition?.isForced == 1 || label.contains("forced")
                    let isSDH = stream.disposition?.isHearingImpaired == 1
                        || stream.disposition?.isCaptions == 1
                        || label.contains("sdh")
                        || label.contains("hearing impaired")
                    let title = isForced ? "English (Forced)" : isSDH ? "English (SDH)" : "English"
                    let disposition = isForced
                        ? "forced"
                        : isSDH ? "default+hearing_impaired" : "default"
                    arguments.append(contentsOf: [
                        "-metadata:s:s:\(outputSubtitleIndex)", "language=eng",
                        "-metadata:s:s:\(outputSubtitleIndex)", "title=\(title)",
                        "-metadata:s:s:\(outputSubtitleIndex)", "handler_name=\(title)",
                        "-disposition:s:\(outputSubtitleIndex)", disposition
                    ])
                }
            }

            for candidate in confirmedCandidates {
                guard let outputAudioIndex = outputAudioIndexBySourceAudioIndex[candidate.audioIndex] else {
                    continue
                }
                switch candidate.kind {
                case .downmixToStereo:
                    arguments.append(contentsOf: [
                        "-filter:a:\(outputAudioIndex)", "pan=stereo|c0=FL|c1=FR",
                        "-c:a:\(outputAudioIndex)", "aac",
                        "-b:a:\(outputAudioIndex)", "192k",
                        "-channel_layout:a:\(outputAudioIndex)", "stereo"
                    ])
                case .extractChannelToMono(let channel):
                    arguments.append(contentsOf: [
                        "-filter:a:\(outputAudioIndex)", "pan=mono|c0=c\(max(channel - 1, 0))",
                        "-c:a:\(outputAudioIndex)", "aac",
                        "-b:a:\(outputAudioIndex)", "128k",
                        "-channel_layout:a:\(outputAudioIndex)", "mono"
                    ])
                case .restoreLayout(let layout):
                    let bitrate = layout == "7.1" ? "768k" : "512k"
                    arguments.append(contentsOf: [
                        "-c:a:\(outputAudioIndex)", "aac",
                        "-b:a:\(outputAudioIndex)", bitrate,
                        "-channel_layout:a:\(outputAudioIndex)", layout
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

            let repairedSubtitleStreams = await probeSubtitleStreams(filePath: temporaryURL.path)
            guard let repairedCompatibility = await probeAudioCompatibility(filePath: temporaryURL.path),
                  repairedCompatibility.streams.count == retainedAudioPairs.count,
                  repairedSubtitleStreams?.count == retainedSubtitleStreams.count,
                  repairedCompatibility.streams.filter({ $0.disposition?.isDefault == 1 }).count <= 1,
                  audioTrackNamesAreDistinguishable(repairedCompatibility.streams),
                  confirmedCandidates.allSatisfy({ candidate in
                    guard let outputAudioIndex = outputAudioIndexBySourceAudioIndex[candidate.audioIndex],
                          repairedCompatibility.streams.indices.contains(outputAudioIndex) else {
                        return false
                    }
                    let repairedStream = repairedCompatibility.streams[outputAudioIndex]
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

            if Task.isCancelled {
                scanProgress = "Repair canceled."
                isRepairing = false
                return
            }

            let installationError = await Self.installRepairedFile(
                temporaryURL: temporaryURL,
                inputURL: inputURL,
                outputURL: outputURL,
                replacesOriginal: replacesOriginal
            )
            if Task.isCancelled {
                scanProgress = "Repair canceled."
                isRepairing = false
                return
            }
            if let installationError {
                skippedCount += 1
                updateRepairMessage(for: result.id, message: "Repair failed: \(installationError)")
            } else {
                repairedCount += 1
                markRepairCompleted(
                    for: result.id,
                    message: replacesOriginal
                        ? "Replaced original after validation"
                        : "Saved \(outputURL.lastPathComponent)"
                )
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

    private func markRepairCompleted(for resultID: UUID, message: String) {
        guard let index = results.firstIndex(where: { $0.id == resultID }) else { return }
        results[index].repairCompleted = true
        results[index].repairMessage = message
    }

    nonisolated private static func removeFileInBackground(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private static func fileIdentity(
        atPath path: String
    ) async -> MP4ValidationFileIdentity? {
        await Task.detached(priority: .utility) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modificationDate = attributes[.modificationDate] as? Date else {
                return nil
            }
            return MP4ValidationFileIdentity(size: size, modificationDate: modificationDate)
        }.value
    }

    nonisolated private static func sourceMismatch(
        for result: MP4ValidationResult
    ) async -> String? {
        guard let currentIdentity = await fileIdentity(atPath: result.filePath) else {
            return "the source file is missing or unavailable."
        }
        guard currentIdentity.size == result.sourceFileSize else {
            return "the source file size changed after the scan."
        }
        guard abs(
            currentIdentity.modificationDate.timeIntervalSince(result.sourceModificationDate)
        ) < 0.01 else {
            return "the source file was modified after the scan."
        }
        return nil
    }

    nonisolated private static func installRepairedFile(
        temporaryURL: URL,
        inputURL: URL,
        outputURL: URL,
        replacesOriginal: Bool
    ) async -> String? {
        await Task.detached(priority: .utility) {
            do {
                if replacesOriginal {
                    _ = try FileManager.default.replaceItemAt(inputURL, withItemAt: temporaryURL)
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
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

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "validate-mp4-flagged-files.txt"

        CleanFilePanelPresenter.present(panel) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
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
            let priority: String
            if result.issue?.localizedCaseInsensitiveContains(
                "audio quality: replace recommended"
            ) == true {
                priority = "Replace"
            } else {
                switch result.severity {
                case .error: priority = "Error"
                case .warning: priority = "Warning"
                case nil: priority = "OK"
                }
            }

            return (
                itemName: URL(fileURLWithPath: result.filePath).lastPathComponent,
                path: result.filePath,
                priority: priority,
                finding: result.issue ?? "",
                recommendation: result.assessment,
                automaticRepair: result.isRepairable ? "Yes" : "No",
                repairCompleted: result.repairCompleted ? "Yes" : "No"
            )
        }
        guard !reportRows.isEmpty else {
            scanAlertText = includeAll ? "No results to export." : "No issues to export."
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = includeAll
            ? "mp4-validation-all.csv" : "mp4-validation-issues.csv"

        CleanFilePanelPresenter.present(panel) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                guard response == .OK, let url = panel.url else {
                    return
                }

                let header = [
                    "Item Name",
                    "Path",
                    "Priority",
                    "Finding",
                    "Recommendation",
                    "Automatic Repair Available",
                    "Repair Completed"
                ]
                    .map(self.csvField)
                    .joined(separator: ",")
                let rows = reportRows.map { row in
                    [
                        row.itemName,
                        row.path,
                        row.priority,
                        row.finding,
                        row.recommendation,
                        row.automaticRepair,
                        row.repairCompleted
                    ]
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

    func exportScanSnapshot() {
        guard canExportAll else {
            scanAlertText = "Run or import a scan before exporting a snapshot."
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "mp4toolscan") ?? .data]
        panel.nameFieldStringValue = "MP4 Validation Scan.mp4toolscan"
        panel.message = "Save the complete scan so it can be resumed without scanning again"

        CleanFilePanelPresenter.present(panel) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                guard response == .OK, let url = panel.url else { return }

                let snapshot = MP4ValidationScanSnapshot(
                    formatVersion: MP4ValidationScanSnapshot.currentFormatVersion,
                    createdAt: Date(),
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "Unknown",
                    inputFolderPath: self.inputFolderPath,
                    droppedFilePaths: self.droppedFilePaths,
                    results: self.results.map(MP4ValidationResultSnapshot.init)
                )

                do {
                    try await Task.detached(priority: .utility) {
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .millisecondsSince1970
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(snapshot).write(to: url, options: .atomic)
                    }.value
                    self.scanAlertText = "Saved a resumable scan with \(snapshot.results.count) result(s)."
                } catch {
                    self.scanAlertText = "Failed to save scan snapshot: \(error.localizedDescription)"
                }
            }
        }
    }

    func importScanSnapshot(
        onImportedInput: @escaping @MainActor (URL?) -> Void = { _ in }
    ) {
        guard canImportSnapshot else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "mp4toolscan") ?? .data]
        panel.message = "Choose a saved MP4 Tool validation scan"

        CleanFilePanelPresenter.present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let snapshot = try await Task.detached(priority: .utility) {
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .millisecondsSince1970
                        return try decoder.decode(
                            MP4ValidationScanSnapshot.self,
                            from: Data(contentsOf: url)
                        )
                    }.value

                    guard snapshot.formatVersion == MP4ValidationScanSnapshot.currentFormatVersion else {
                        self.scanAlertText = "This scan was created by an unsupported snapshot format."
                        return
                    }
                    guard !snapshot.results.isEmpty else {
                        self.scanAlertText = "The selected scan snapshot contains no results."
                        return
                    }

                    self.scanTask?.cancel()
                    self.repairTask?.cancel()
                    self.inputFolderPath = snapshot.inputFolderPath
                    self.droppedFilePaths = snapshot.droppedFilePaths
                    self.results = snapshot.results.map(\.validationResult)
                    self.scanProgress = "Restored \(self.results.count) result(s) from saved scan."
                    self.scanAlertText = "Imported scan from \(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)). Files will be verified before repair."
                    self.resetOperationProgress()
                    let restoredInputURL: URL?
                    if !snapshot.inputFolderPath.isEmpty {
                        restoredInputURL = URL(
                            fileURLWithPath: snapshot.inputFolderPath,
                            isDirectory: true
                        )
                    } else if let firstPath = snapshot.droppedFilePaths.first {
                        restoredInputURL = URL(fileURLWithPath: firstPath)
                    } else {
                        restoredInputURL = nil
                    }
                    onImportedInput(restoredInputURL)
                } catch {
                    self.scanAlertText = "Could not import scan snapshot: \(error.localizedDescription)"
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
            guard let sourceIdentity = await Self.fileIdentity(atPath: fileInfo.fullPath) else {
                results.append(
                    MP4ValidationResult(
                        fileName: fileInfo.relativePath,
                        filePath: fileInfo.fullPath,
                        issue: "file became unavailable during validation",
                        assessment: "The file could not be read after validation completed.",
                        severity: .error,
                        repairCandidates: [],
                        needsAudioMetadataRepair: false,
                        audioStreamIndexesToRemove: [],
                        subtitleStreamIndexesToRemove: [],
                        preferredSubtitleStreamIndex: nil,
                        needsContainerRemux: false,
                        sourceFileSize: 0,
                        sourceModificationDate: .distantPast
                    )
                )
                continue
            }
            results.append(
                MP4ValidationResult(
                    fileName: fileInfo.relativePath,
                    filePath: fileInfo.fullPath,
                    issue: finding?.message,
                    assessment: finding?.assessment ?? "No action needed.",
                    severity: finding?.severity,
                    repairCandidates: finding?.repairCandidates ?? [],
                    needsAudioMetadataRepair: finding?.needsAudioMetadataRepair ?? false,
                    audioStreamIndexesToRemove: finding?.audioStreamIndexesToRemove ?? [],
                    subtitleStreamIndexesToRemove: finding?.subtitleStreamIndexesToRemove ?? [],
                    preferredSubtitleStreamIndex: finding?.preferredSubtitleStreamIndex,
                    needsContainerRemux: finding?.needsContainerRemux ?? false,
                    sourceFileSize: sourceIdentity.size,
                    sourceModificationDate: sourceIdentity.modificationDate
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
        var audioStreamIndexesToRemove = Set<Int>()
        var subtitleStreamIndexesToRemove = Set<Int>()
        var preferredSubtitleStreamIndex: Int?
        var needsContainerRemux = false
        var audioCompatibility: MP4ValidationAudioCompatibility?

        if ffprobeAvailable {
            if let unsupportedVideoCodec = await unsupportedAppleVideoCodec(filePath: filePath) {
                reasons.append("unsupported video codec \(unsupportedVideoCodec)")
            }

            if let containerAnalysis = await containerAnalysis(filePath: filePath),
               containerAnalysis.needsMediaOnlyRemux,
               await failsApplePlaybackStartup(filePath: filePath) {
                reasons.append(contentsOf: containerAnalysis.issues)
                needsContainerRemux = true
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
                audioStreamIndexesToRemove = authoringAnalysis.audioStreamIndexesToRemove
            }

            if let subtitleAnalysis = await subtitleAuthoringAnalysis(filePath: filePath) {
                warnings.append(contentsOf: subtitleAnalysis.warnings)
                subtitleStreamIndexesToRemove = subtitleAnalysis.streamIndexesToRemove
                preferredSubtitleStreamIndex = subtitleAnalysis.preferredStreamIndex
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
            needsAudioMetadataRepair: needsAudioMetadataRepair,
            audioStreamIndexesToRemove: audioStreamIndexesToRemove,
            subtitleStreamIndexesToRemove: subtitleStreamIndexesToRemove,
            needsContainerRemux: needsContainerRemux
        )

        if !reasons.isEmpty {
            let allFindings = reasons + warnings
            return MP4ValidationFinding(
                message: allFindings.joined(separator: ", "),
                assessment: assessment,
                severity: .error,
                repairCandidates: repairCandidates,
                needsAudioMetadataRepair: needsAudioMetadataRepair,
                audioStreamIndexesToRemove: audioStreamIndexesToRemove,
                subtitleStreamIndexesToRemove: subtitleStreamIndexesToRemove,
                preferredSubtitleStreamIndex: preferredSubtitleStreamIndex,
                needsContainerRemux: needsContainerRemux
            )
        }

        guard !warnings.isEmpty else { return nil }
        return MP4ValidationFinding(
            message: warnings.joined(separator: ", "),
            assessment: assessment,
            severity: .warning,
            repairCandidates: repairCandidates,
            needsAudioMetadataRepair: needsAudioMetadataRepair,
            audioStreamIndexesToRemove: audioStreamIndexesToRemove,
            subtitleStreamIndexesToRemove: subtitleStreamIndexesToRemove,
            preferredSubtitleStreamIndex: preferredSubtitleStreamIndex,
            needsContainerRemux: needsContainerRemux
        )
    }

    private func validationAssessment(
        reasons: [String],
        warnings: [String],
        repairCandidates: [MP4AudioRepairCandidate],
        needsAudioMetadataRepair: Bool,
        audioStreamIndexesToRemove: Set<Int>,
        subtitleStreamIndexesToRemove: Set<Int>,
        needsContainerRemux: Bool
    ) -> String {
        let findings = (reasons + warnings).joined(separator: " ").lowercased()
        var actions: [String] = []

        if needsContainerRemux {
            actions.append("Automatic repair available: rebuild the MP4 using only its video, audio, and subtitle tracks.")
        }

        if needsAudioMetadataRepair && audioStreamIndexesToRemove.isEmpty {
            actions.append("Automatic repair available: normalize audio defaults and assign distinct track titles.")
        }

        if !audioStreamIndexesToRemove.isEmpty {
            actions.append(
                "Automatic repair available: keep the preferred main English audio and remove \(audioStreamIndexesToRemove.count) redundant English track(s)."
            )
        }

        if !subtitleStreamIndexesToRemove.isEmpty {
            actions.append(
                "Automatic repair available: keep the best complete English subtitle track and remove \(subtitleStreamIndexesToRemove.count) redundant English variant(s)."
            )
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

        if findings.contains("audio quality: replace recommended") {
            actions.append("Replace the audio from a higher-quality source; remuxing or increasing its bitrate cannot restore discarded detail.")
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

    private func containerAnalysis(filePath: String) async -> MP4ValidationContainerAnalysis? {
        let arguments = [
            "-v", "error",
            "-show_entries",
            "stream=index,codec_type,codec_tag_string,start_time,duration:stream_tags=handler_name:chapter=start_time,end_time",
            "-print_format", "json",
            filePath
        ]

        guard let output = await runProcessCaptureStdout(path: ffprobePath, arguments: arguments),
              let data = output.data(using: .utf8),
              let probe = try? JSONDecoder().decode(MP4ValidationContainerProbeOutput.self, from: data) else {
            return nil
        }

        let auxiliaryStreams = probe.streams.filter {
            normalizedProbeValue($0.codecType) == "data"
        }
        let malformedChapters = (probe.chapters ?? []).filter { chapter in
            guard let start = chapter.startTime.flatMap(TimeInterval.init),
                  let end = chapter.endTime.flatMap(TimeInterval.init) else {
                return true
            }
            return end - start < 0.01
        }
        guard !auxiliaryStreams.isEmpty || !malformedChapters.isEmpty else {
            return MP4ValidationContainerAnalysis(issues: [], needsMediaOnlyRemux: false)
        }

        let tags = auxiliaryStreams
            .compactMap { stream -> String? in
                let tag = normalizedProbeValue(stream.codecTagString)
                return tag.isEmpty ? nil : tag
            }
            .reduce(into: [String]()) { values, tag in
                if !values.contains(tag) { values.append(tag) }
            }
        var details: [String] = []
        if !tags.isEmpty {
            details.append(tags.joined(separator: ", "))
        }
        if !malformedChapters.isEmpty {
            details.append("\(malformedChapters.count) invalid chapter ranges")
        }
        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: "; ")))"
        return MP4ValidationContainerAnalysis(
            issues: ["malformed auxiliary or chapter tracks\(suffix)"],
            needsMediaOnlyRemux: true
        )
    }

    /// `AVURLAsset.isPlayable` can be true for malformed QuickTime auxiliary
    /// tracks even though AVPlayer fails as soon as playback begins. Probe actual
    /// player-item readiness for suspicious containers to avoid both that false
    /// negative and static chapter-count false positives.
    private func failsApplePlaybackStartup(filePath: String) async -> Bool {
        let item = AVPlayerItem(url: URL(fileURLWithPath: filePath))
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }

        for _ in 0..<40 {
            if Task.isCancelled { return false }
            switch item.status {
            case .failed:
                return true
            case .readyToPlay:
                return false
            case .unknown:
                break
            @unknown default:
                return false
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        // An inconclusive timeout is not sufficient evidence to flag a file.
        return false
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
            "stream=index,codec_name,profile,codec_tag_string,sample_fmt,bit_rate,channels,channel_layout,start_time,duration:stream_disposition=default,comment,visual_impaired,dub,original:stream_tags=language,title,handler_name:format=duration",
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

    private func subtitleAuthoringAnalysis(
        filePath: String
    ) async -> MP4ValidationSubtitleAuthoringAnalysis? {
        guard let supportedStreams = await probeSubtitleStreams(filePath: filePath) else {
            return nil
        }

        var candidates: [SubtitleTrackSelectionCandidate] = []
        for (subtitleIndex, stream) in supportedStreams.enumerated() {
            let language = stream.tags?["language"]
            let title = stream.tags?["title"]
            let handlerName = stream.tags?["handler_name"]
            let normalizedLabel = [title, handlerName]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            candidates.append(
                SubtitleTrackSelectionCandidate(
                    streamIndex: stream.index,
                    subtitleIndex: subtitleIndex,
                    language: language,
                    title: title,
                    handlerName: handlerName,
                    cueCount: stream.nbFrames.flatMap(Int.init)
                        ?? stream.nbReadPackets.flatMap(Int.init),
                    accessibilityMarkerCount: 0,
                    isDefault: stream.disposition?.isDefault == 1,
                    isForced: stream.disposition?.isForced == 1
                        || normalizedLabel.contains("forced"),
                    isHearingImpaired: stream.disposition?.isHearingImpaired == 1
                        || normalizedLabel.contains("sdh")
                        || normalizedLabel.contains("hearing impaired"),
                    isCaptions: stream.disposition?.isCaptions == 1
                )
            )
        }

        var englishCandidates = candidates.filter(SubtitleTrackSelectionPolicy.isEnglish)
        guard englishCandidates.count > 1 else {
            return MP4ValidationSubtitleAuthoringAnalysis(
                warnings: [],
                streamIndexesToRemove: [],
                preferredStreamIndex: nil,
                rationale: nil,
                streams: supportedStreams
            )
        }
        guard ffmpegAvailable
                || !SubtitleTrackSelectionPolicy.needsContentInspection(englishCandidates) else {
            return MP4ValidationSubtitleAuthoringAnalysis(
                warnings: ["multiple English subtitle tracks require a deeper review"],
                streamIndexesToRemove: [],
                preferredStreamIndex: nil,
                rationale: nil,
                streams: supportedStreams
            )
        }

        if SubtitleTrackSelectionPolicy.needsContentInspection(englishCandidates) {
            for index in englishCandidates.indices {
                guard let metrics = await validationSubtitleContentMetrics(
                    filePath: filePath,
                    streamIndex: englishCandidates[index].streamIndex
                ) else { continue }
                let candidate = englishCandidates[index]
                englishCandidates[index] = SubtitleTrackSelectionCandidate(
                    streamIndex: candidate.streamIndex,
                    subtitleIndex: candidate.subtitleIndex,
                    language: candidate.language,
                    title: candidate.title,
                    handlerName: candidate.handlerName,
                    cueCount: metrics.cueCount,
                    accessibilityMarkerCount: metrics.accessibilityMarkerCount,
                    isDefault: candidate.isDefault,
                    isForced: candidate.isForced,
                    isHearingImpaired: candidate.isHearingImpaired,
                    isCaptions: candidate.isCaptions
                )
            }
        }

        guard let preferred = SubtitleTrackSelectionPolicy.preferredFullTrack(
            from: englishCandidates
        ) else {
            return MP4ValidationSubtitleAuthoringAnalysis(
                warnings: [],
                streamIndexesToRemove: [],
                preferredStreamIndex: nil,
                rationale: nil,
                streams: supportedStreams
            )
        }

        let indexesToRemove = Set(
            englishCandidates
                .filter { $0.streamIndex != preferred.streamIndex }
                .map(\.streamIndex)
        )
        let rationale = SubtitleTrackSelectionPolicy.rationale(
            for: preferred,
            among: englishCandidates
        )
        return MP4ValidationSubtitleAuthoringAnalysis(
            warnings: ["multiple English subtitle tracks; preferred track is \(rationale)"],
            streamIndexesToRemove: indexesToRemove,
            preferredStreamIndex: preferred.streamIndex,
            rationale: rationale,
            streams: supportedStreams
        )
    }

    private func probeSubtitleStreams(filePath: String) async -> [VideoStream]? {
        let arguments = [
            "-v", "error", "-select_streams", "s",
            "-show_streams", "-print_format", "json", filePath
        ]
        guard let output = await runProcessCaptureStdout(path: ffprobePath, arguments: arguments),
              let data = output.data(using: .utf8),
              let probe = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else {
            return nil
        }

        let supportedCodecs = Set(["mov_text", "subrip", "ass", "ssa"])
        let supportedStreams = probe.streams.filter {
            $0.codecName.map { supportedCodecs.contains($0.lowercased()) } == true
        }
        return supportedStreams
    }

    private func validationSubtitleContentMetrics(
        filePath: String,
        streamIndex: Int
    ) async -> (cueCount: Int, accessibilityMarkerCount: Int)? {
        let arguments = [
            "-nostdin", "-v", "error", "-i", filePath,
            "-map", "0:\(streamIndex)", "-f", "srt", "-"
        ]
        guard let text = await runProcessCaptureStdout(path: ffmpegPath, arguments: arguments) else {
            return nil
        }
        return SubtitleTrackSelectionPolicy.contentMetrics(from: text)
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
                needsMetadataRepair: false,
                audioStreamIndexesToRemove: []
            )
        }

        var errors: [String] = []
        var warnings: [String] = []
        var repairCandidates: [MP4AudioRepairCandidate] = []
        var needsMetadataRepair = false
        var audioStreamIndexesToRemove = Set<Int>()

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
            if language == "eng" || language == "en" {
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

        let selectionCandidates = streams.enumerated().map { audioIndex, stream in
            audioSelectionCandidate(stream, audioIndex: audioIndex)
        }
        let englishCandidates = selectionCandidates.filter(AudioTrackSelectionPolicy.isEnglish)
        let undefinedLanguageCandidates = selectionCandidates.filter(
            AudioTrackSelectionPolicy.isUndefinedLanguage
        )
        let qualityCandidatePool = !englishCandidates.isEmpty
            ? englishCandidates
            : !undefinedLanguageCandidates.isEmpty
                ? undefinedLanguageCandidates
                : selectionCandidates

        if let preferred = AudioTrackSelectionPolicy.preferredMainTrack(from: qualityCandidatePool),
           let preferredStream = streams.first(where: { $0.index == preferred.streamIndex }),
           let qualityFinding = lowBitRateAudioFinding(for: preferredStream) {
            errors.append(qualityFinding)
        }

        if englishCandidates.count > 1,
           let preferred = AudioTrackSelectionPolicy.preferredMainTrack(from: englishCandidates) {
            audioStreamIndexesToRemove = Set(
                englishCandidates
                    .filter { $0.streamIndex != preferred.streamIndex }
                    .map(\.streamIndex)
            )
            let preferredSummary = AudioTrackSelectionPolicy.summary(for: preferred)
            warnings.append(
                "multiple English audio tracks; preferred main track is \(preferredSummary)"
            )
            needsMetadataRepair = true
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
            needsMetadataRepair: needsMetadataRepair,
            audioStreamIndexesToRemove: audioStreamIndexesToRemove
        )
    }

    private func audioSelectionCandidate(
        _ stream: MP4ValidationAudioStream,
        audioIndex: Int
    ) -> AudioTrackSelectionCandidate {
        AudioTrackSelectionCandidate(
            streamIndex: stream.index,
            audioIndex: audioIndex,
            language: stream.tags?["language"],
            title: stream.tags?["title"],
            handlerName: stream.tags?["handler_name"],
            codec: stream.codecName,
            profile: stream.profile,
            channels: stream.channels,
            channelLayout: stream.channelLayout,
            bitRate: stream.bitRate.flatMap(Int.init),
            duration: stream.duration.flatMap(TimeInterval.init),
            isDefault: stream.disposition?.isDefault == 1,
            isCommentary: stream.disposition?.isCommentary == 1,
            isVisualImpaired: stream.disposition?.isVisualImpaired == 1,
            isDub: stream.disposition?.isDub == 1
        )
    }

    private func audioTrackName(_ stream: MP4ValidationAudioStream) -> String {
        let title = normalizedProbeValue(stream.tags?["title"])
        if !title.isEmpty {
            return title
        }
        return normalizedProbeValue(stream.tags?["handler_name"])
    }

    private func lowBitRateAudioFinding(
        for stream: MP4ValidationAudioStream
    ) -> String? {
        let codec = normalizedProbeValue(stream.codecName)
        guard ["aac", "mp3", "ac3", "eac3"].contains(codec),
              let bitRate = stream.bitRate.flatMap(Int.init),
              bitRate > 0 else {
            return nil
        }

        let profile = stream.profile?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let codecDescription = profile.isEmpty
            ? displayProbeValue(stream.codecName).uppercased()
            : profile
        let normalizedProfile = profile.lowercased()
        let channelCount = max(stream.channels ?? 2, 1)
        let replacementThreshold = audioReplacementBitRateThreshold(
            codec: codec,
            profile: normalizedProfile,
            channelCount: channelCount
        )

        // FFprobe reports the measured average. Allow 5% below a nominal target
        // so a 63.9 kb/s or 190.6 kb/s stream is treated as 64 or 192 kb/s.
        let replacementBoundary = Int(Double(replacementThreshold) * 0.95)
        guard bitRate < replacementBoundary else { return nil }

        let layoutDescription: String
        switch channelCount {
        case 1: layoutDescription = "mono"
        case 2: layoutDescription = "stereo"
        default: layoutDescription = "\(channelCount) channels"
        }

        return String(
            format: "audio quality: replace recommended (preferred %@ %@ track is %.1f kb/s; replacement threshold is %.0f kb/s)",
            codecDescription,
            layoutDescription,
            Double(bitRate) / 1_000,
            Double(replacementThreshold) / 1_000
        )
    }

    private func audioReplacementBitRateThreshold(
        codec: String,
        profile: String,
        channelCount: Int
    ) -> Int {
        if codec == "aac", profile.contains("he-aac") {
            switch channelCount {
            case 1: return 24_000
            case 2: return 48_000
            case 3...4: return 96_000
            case 5...6: return 144_000
            default: return 192_000
            }
        }

        if codec == "eac3" {
            switch channelCount {
            case 1: return 64_000
            case 2: return 96_000
            case 3...4: return 144_000
            case 5...6: return 192_000
            default: return 256_000
            }
        }

        if codec == "ac3" {
            switch channelCount {
            case 1: return 96_000
            case 2: return 160_000
            case 3...4: return 256_000
            case 5...6: return 320_000
            default: return 384_000
            }
        }

        // AAC-LC and MP3 need more bitrate than HE-AAC for comparable quality.
        switch channelCount {
        case 1: return 48_000
        case 2: return 96_000
        case 3...4: return 144_000
        case 5...6: return 192_000
        default: return 256_000
        }
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
        guard !Task.isCancelled else { return nil }
        let cancellation = MP4ValidationProcessCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = arguments

                    let outputPipe = Pipe()
                    process.standardOutput = outputPipe
                    process.standardError = FileHandle.nullDevice

                    do {
                        cancellation.register(process)
                        self.processLock.lock()
                        self.currentProcess = process
                        self.processLock.unlock()

                        try process.run()
                        cancellation.stopIfCancelled()
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
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func runProcessCaptureStderr(path: String, arguments: [String]) async -> String? {
        guard !Task.isCancelled else { return nil }
        let cancellation = MP4ValidationProcessCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = arguments

                    let errorPipe = Pipe()
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = errorPipe

                    do {
                        cancellation.register(process)
                        self.processLock.lock()
                        self.currentProcess = process
                        self.processLock.unlock()

                        try process.run()
                        cancellation.stopIfCancelled()
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
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func terminateCurrentProcess() {
        processLock.lock()
        let process = currentProcess
        processLock.unlock()

        guard let process else { return }
        MP4ValidationProcessCancellation.stop(process)
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

}
