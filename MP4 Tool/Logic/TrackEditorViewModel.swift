import Foundation
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

enum TrackEditorTrackKind: String, Codable, CaseIterable {
    case video
    case audio
    case subtitle

    var label: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .subtitle: return "Subtitles"
        }
    }

    var systemImage: String {
        switch self {
        case .video: return "film"
        case .audio: return "waveform"
        case .subtitle: return "captions.bubble"
        }
    }
}

struct TrackEditorTrack: Identifiable, Equatable {
    let id = UUID()
    let inputOrdinal: Int
    let streamIndex: Int
    let sourcePath: String
    let kind: TrackEditorTrackKind
    let codec: String
    let channels: Int?
    let channelLayout: String?
    let width: Int?
    let height: Int?
    let isExternal: Bool
    let isMuxable: Bool
    let compatibilityNote: String?
    var isIncluded: Bool
    var language: String
    var title: String
    var isDefault: Bool
    var isForced: Bool
    var isHearingImpaired: Bool
    var isCaptions: Bool

    var technicalDescription: String {
        var parts = [codec.uppercased()]
        if let width, let height {
            parts.append("\(width)×\(height)")
        }
        if let channels {
            if let channelLayout, !channelLayout.isEmpty {
                parts.append(channelLayout)
            } else {
                parts.append("\(channels) channels")
            }
        }
        if isExternal {
            parts.append(URL(fileURLWithPath: sourcePath).lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }

    var subtitleDispositionDescription: String? {
        guard kind == .subtitle else { return nil }
        var labels: [String] = []
        if isForced { labels.append("Forced") }
        if isHearingImpaired { labels.append("Hearing Impaired") }
        if isCaptions { labels.append("Captions") }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }
}

private struct TrackEditorProbeOutput: Decodable {
    let streams: [TrackEditorProbeStream]
    let format: TrackEditorProbeFormat?
}

private struct TrackEditorProbeStream: Decodable {
    let index: Int
    let codecType: String?
    let codecName: String?
    let channels: Int?
    let channelLayout: String?
    let width: Int?
    let height: Int?
    let duration: String?
    let disposition: TrackEditorProbeDisposition?
    let tags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case channels
        case channelLayout = "channel_layout"
        case width
        case height
        case duration
        case disposition
        case tags
    }
}

private struct TrackEditorProbeDisposition: Decodable {
    let isDefault: Int?
    let isForced: Int?
    let isHearingImpaired: Int?
    let isCaptions: Int?

    enum CodingKeys: String, CodingKey {
        case isDefault = "default"
        case isForced = "forced"
        case isHearingImpaired = "hearing_impaired"
        case isCaptions = "captions"
    }
}

private struct TrackEditorProbeFormat: Decodable {
    let duration: String?
}

private struct TrackEditorValidationFailure {
    let message: String
    let details: String
}

private nonisolated final class TrackEditorProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var progressBuffer = ""

    func appendStdout(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        stdoutData.append(data)
        progressBuffer += String(decoding: data, as: UTF8.self)
        let parts = progressBuffer.components(separatedBy: .newlines)
        progressBuffer = parts.last ?? ""
        return Array(parts.dropLast())
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stderrData.append(data)
        lock.unlock()
    }

    func result(exitCode: Int32) -> (exitCode: Int32, stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        return (
            exitCode,
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
    }
}

@MainActor
final class TrackEditorViewModel: ObservableObject {
    @Published var inputPath = ""
    @Published var outputFolderPath = ""
    @Published var outputFileName = ""
    @Published var tracks: [TrackEditorTrack] = []
    @Published var isInspecting = false
    @Published var isRemuxing = false
    @Published var statusMessage = ""
    @Published private(set) var errorDetails = ""
    @Published var showOverwriteConfirmation = false
    @Published var replaceOriginal = UserDefaults.standard.bool(forKey: "trackEditorReplaceOriginal") {
        didSet {
            UserDefaults.standard.set(replaceOriginal, forKey: "trackEditorReplaceOriginal")
            updateDefaultOutputLocation()
        }
    }
    @Published private(set) var remuxProgress = 0.0
    @Published private(set) var remuxElapsed: TimeInterval = 0
    @Published private(set) var remuxETA: TimeInterval?

    private var ffmpegPath = ""
    private var ffprobePath = ""
    private var operationTask: Task<Void, Never>?
    private var progressTimerTask: Task<Void, Never>?
    private var sourceDuration: TimeInterval?
    private var sourceVideoDuration: TimeInterval?
    private var remuxStartedAt: Date?
    private var nextInputOrdinal = 1
    private let processLock = NSLock()
    private nonisolated(unsafe) var currentProcess: Process?

    init() {
        ffmpegPath = Self.findExecutable(named: "ffmpeg") ?? ""
        ffprobePath = Self.findExecutable(named: "ffprobe") ?? ""
    }

    var hasTools: Bool {
        !ffmpegPath.isEmpty && !ffprobePath.isEmpty
    }

    var resolvedOutputPath: String {
        if replaceOriginal {
            return inputPath
        }
        let name = sanitizedOutputFileName
        guard !name.isEmpty, !outputFolderPath.isEmpty else { return "" }
        return URL(fileURLWithPath: outputFolderPath, isDirectory: true)
            .appendingPathComponent(name)
            .path
    }

    var canRemux: Bool {
        hasTools
            && !isInspecting
            && !isRemuxing
            && !inputPath.isEmpty
            && !resolvedOutputPath.isEmpty
            && (replaceOriginal || resolvedOutputPath != inputPath)
            && tracks.contains { $0.isIncluded && $0.kind == .video && $0.isMuxable }
    }

    var operationInProgress: Bool {
        isInspecting || isRemuxing
    }

    var hasDeterminateRemuxProgress: Bool {
        sourceDuration.map { $0 > 0 } == true
    }

    var remuxElapsedText: String {
        Self.formatDuration(remuxElapsed)
    }

    var remuxETAText: String {
        remuxETA.map(Self.formatDuration) ?? "Calculating…"
    }

    func chooseInput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.contentTypes(for: ["mp4", "m4v", "mov"])
        panel.message = "Choose an MP4 file to inspect"
        CleanFilePanelPresenter.present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.inspect(path: url.path)
        }
    }

    func inspect(path: String) {
        guard !operationInProgress else { return }
        let url = URL(fileURLWithPath: path)
        guard ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased()) else {
            statusMessage = "Choose an MP4, M4V, or MOV file."
            return
        }
        guard hasTools else {
            statusMessage = "FFmpeg and FFprobe are required."
            return
        }

        inputPath = url.path
        outputFolderPath = url.deletingLastPathComponent().path
        outputFileName = replaceOriginal
            ? url.lastPathComponent
            : url.deletingPathExtension().lastPathComponent + "_edited.mp4"
        tracks = []
        errorDetails = ""
        sourceDuration = nil
        sourceVideoDuration = nil
        nextInputOrdinal = 1
        statusMessage = "Inspecting tracks…"
        isInspecting = true

        operationTask?.cancel()
        operationTask = Task {
            guard let probe = await probe(path: url.path) else {
                statusMessage = "Could not inspect this file with FFprobe."
                isInspecting = false
                return
            }

            sourceDuration = probe.format?.duration.flatMap(TimeInterval.init)
            sourceVideoDuration = probe.streams
                .first(where: { $0.codecType == TrackEditorTrackKind.video.rawValue })?
                .duration
                .flatMap(TimeInterval.init) ?? sourceDuration
            tracks = probe.streams.compactMap {
                makeTrack(from: $0, sourcePath: url.path, inputOrdinal: 0, isExternal: false)
            }
            statusMessage = tracks.isEmpty
                ? "No editable video, audio, or subtitle tracks were found."
                : "Found \(tracks.count) editable track(s)."
            isInspecting = false
        }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose where the edited MP4 should be saved"
        CleanFilePanelPresenter.present(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.outputFolderPath = url.path
        }
    }

    func addAudioTracks() {
        addExternalTracks(kind: .audio)
    }

    func addSubtitleTracks() {
        addExternalTracks(kind: .subtitle)
    }

    func removeExternalTrack(id: UUID) {
        guard !operationInProgress else { return }
        tracks.removeAll { $0.id == id && $0.isExternal }
    }

    func setDefault(trackID: UUID, value: Bool) {
        guard let selectedIndex = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let kind = tracks[selectedIndex].kind
        if value {
            for index in tracks.indices where tracks[index].kind == kind {
                tracks[index].isDefault = tracks[index].id == trackID
            }
        } else {
            tracks[selectedIndex].isDefault = false
        }
    }

    func revealInput() {
        guard !inputPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: inputPath)])
    }

    func openOutputFolder() {
        guard !outputFolderPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: outputFolderPath, isDirectory: true))
    }

    func startRemux() {
        guard canRemux else { return }
        if replaceOriginal {
            beginRemux(overwrite: true)
            return
        }
        if FileManager.default.fileExists(atPath: resolvedOutputPath) {
            showOverwriteConfirmation = true
            return
        }
        beginRemux(overwrite: false)
    }

    func confirmOverwriteAndStart() {
        guard canRemux else { return }
        beginRemux(overwrite: true)
    }

    func cancel() {
        operationTask?.cancel()
        progressTimerTask?.cancel()
        terminateCurrentProcess()
        isInspecting = false
        isRemuxing = false
        statusMessage = "Operation canceled."
    }

    func copyErrorDetails() {
        guard !errorDetails.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(errorDetails, forType: .string)
    }

    private func addExternalTracks(kind: TrackEditorTrackKind) {
        guard !operationInProgress, !inputPath.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = kind == .audio
            ? "Choose audio files to add"
            : "Choose subtitle files to add"
        if kind == .audio {
            panel.allowedContentTypes = Self.contentTypes(
                for: ["aac", "m4a", "mp3", "ac3", "eac3", "flac", "wav", "aiff", "mka"]
            )
        } else {
            panel.allowedContentTypes = Self.contentTypes(for: ["srt", "vtt", "ass", "ssa", "mks"])
        }
        CleanFilePanelPresenter.present(panel) { [weak self] response in
            guard let self, response == .OK else { return }
            self.inspectExternalTracks(at: panel.urls, kind: kind)
        }
    }

    private func inspectExternalTracks(at urls: [URL], kind: TrackEditorTrackKind) {
        statusMessage = "Inspecting added tracks…"
        isInspecting = true
        operationTask?.cancel()
        operationTask = Task {
            var addedCount = 0
            for url in urls {
                guard !Task.isCancelled, let probe = await probe(path: url.path) else { continue }
                let inputOrdinal = nextInputOrdinal
                nextInputOrdinal += 1
                var matchingStreams = probe.streams.compactMap {
                    makeTrack(from: $0, sourcePath: url.path, inputOrdinal: inputOrdinal, isExternal: true)
                }.filter { $0.kind == kind }
                if let defaultIndex = matchingStreams.firstIndex(where: \.isMuxable) {
                    for index in tracks.indices where tracks[index].kind == kind {
                        tracks[index].isDefault = false
                    }
                    for index in matchingStreams.indices {
                        matchingStreams[index].isDefault = index == defaultIndex
                    }
                }
                tracks.append(contentsOf: matchingStreams)
                addedCount += matchingStreams.count
            }
            statusMessage = addedCount == 0
                ? "No compatible \(kind.label.lowercased()) tracks were found."
                : "Added \(addedCount) \(kind.label.lowercased()) track(s)."
            isInspecting = false
        }
    }

    private func beginRemux(overwrite: Bool) {
        isRemuxing = true
        errorDetails = ""
        statusMessage = replaceOriginal ? "Creating validated replacement…" : "Creating edited MP4…"
        remuxProgress = 0
        remuxElapsed = 0
        remuxETA = nil
        remuxStartedAt = Date()
        startProgressTimer()
        operationTask?.cancel()
        operationTask = Task {
            await runRemux(overwrite: overwrite)
        }
    }

    private func runRemux(overwrite: Bool) async {
        let sleepAssertion = SystemSleepAssertion(reason: "MP4 Tool is editing media tracks")
        defer {
            sleepAssertion.invalidate()
            progressTimerTask?.cancel()
            progressTimerTask = nil
        }

        let includedTracks = tracks.filter { $0.isIncluded && $0.isMuxable }
        let outputPath = resolvedOutputPath
        guard !outputPath.isEmpty, replaceOriginal || outputPath != inputPath else {
            statusMessage = "Choose a different output filename than the source."
            isRemuxing = false
            return
        }

        let outputURL = URL(fileURLWithPath: outputPath)
        let temporaryURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".mp4tool-track-edit-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let externalInputs = Dictionary(grouping: includedTracks.filter(\.isExternal), by: \.inputOrdinal)
            .compactMapValues { $0.first?.sourcePath }

        var arguments = ["-hide_banner", overwrite ? "-y" : "-n", "-i", inputPath]
        for ordinal in externalInputs.keys.sorted() {
            if let path = externalInputs[ordinal] {
                arguments.append(contentsOf: ["-i", path])
            }
        }
        arguments.append(contentsOf: ["-map_metadata", "0", "-map_chapters", "0"])

        var outputIndexes: [TrackEditorTrackKind: Int] = [.video: 0, .audio: 0, .subtitle: 0]
        for track in includedTracks {
            let actualInputOrdinal: Int
            if track.inputOrdinal == 0 {
                actualInputOrdinal = 0
            } else {
                let sortedOrdinals = externalInputs.keys.sorted()
                actualInputOrdinal = (sortedOrdinals.firstIndex(of: track.inputOrdinal) ?? 0) + 1
            }
            arguments.append(contentsOf: ["-map", "\(actualInputOrdinal):\(track.streamIndex)"])

            let outputIndex = outputIndexes[track.kind, default: 0]
            outputIndexes[track.kind] = outputIndex + 1

            switch track.kind {
            case .video:
                arguments.append(contentsOf: ["-c:v:\(outputIndex)", "copy"])
                if ["hevc", "h265"].contains(track.codec.lowercased()) {
                    arguments.append(contentsOf: ["-tag:v:\(outputIndex)", "hvc1"])
                }
            case .audio:
                if isMP4CompatibleAudioCodec(track.codec) {
                    arguments.append(contentsOf: ["-c:a:\(outputIndex)", "copy"])
                } else {
                    arguments.append(contentsOf: ["-c:a:\(outputIndex)", "aac"])
                    arguments.append(contentsOf: ["-b:a:\(outputIndex)", aacBitrate(channels: track.channels)])
                    if let layout = canonicalChannelLayout(channels: track.channels, fallback: track.channelLayout) {
                        arguments.append(contentsOf: ["-channel_layout:a:\(outputIndex)", layout])
                    }
                }
                appendMetadata(for: track, kindSpecifier: "a", outputIndex: outputIndex, to: &arguments)
                arguments.append(contentsOf: [
                    "-disposition:a:\(outputIndex)", track.isDefault ? "default" : "0"
                ])
            case .subtitle:
                arguments.append(contentsOf: [
                    "-c:s:\(outputIndex)", track.codec.lowercased() == "mov_text" ? "copy" : "mov_text"
                ])
                appendMetadata(for: track, kindSpecifier: "s", outputIndex: outputIndex, to: &arguments)
                arguments.append(contentsOf: [
                    "-disposition:s:\(outputIndex)", subtitleDispositionValue(for: track)
                ])
            }
        }
        arguments.append(contentsOf: ["-movflags", "+faststart"])
        if let sourceDuration, sourceDuration > 0 {
            // Some malformed MP4 sample tables expose packets beyond the track's declared
            // duration. Cap the remux to the trusted container duration so those hidden
            // packets—or an overlong external subtitle—cannot extend the edited output.
            arguments.append(contentsOf: ["-t", String(format: "%.6f", sourceDuration)])
        }
        arguments.append(contentsOf: [
            "-loglevel", "error",
            "-nostats",
            "-progress", "pipe:1",
            temporaryURL.path
        ])

        let processResult = await runFFmpegWithProgress(path: ffmpegPath, arguments: arguments)
        guard !Task.isCancelled else { return }
        guard let processResult, processResult.exitCode == 0 else {
            let stderr = processResult?.stderr ?? ""
            let message = lastMeaningfulLine(stderr) ?? "Unknown error"
            statusMessage = "FFmpeg failed: \(message)"
            errorDetails = """
            Track Editor Error
            Stage: FFmpeg remux
            Source: \(inputPath)
            Intended output: \(outputPath)
            Exit code: \(processResult.map { String($0.exitCode) } ?? "Process could not start")
            Command: \(Self.commandDescription(path: ffmpegPath, arguments: arguments))

            FFmpeg output:
            \(stderr.isEmpty ? "No error output was returned." : stderr)
            """
            isRemuxing = false
            return
        }

        remuxProgress = 1
        remuxETA = 0
        statusMessage = "Validating edited MP4…"
        let expectedCounts: [TrackEditorTrackKind: Int] = Dictionary(grouping: includedTracks, by: \.kind)
            .mapValues(\.count)
        if let validationFailure = await validationIssue(
            outputPath: temporaryURL.path,
            expectedCounts: expectedCounts
        ) {
            statusMessage = "Validation failed: \(validationFailure.message)"
            errorDetails = validationFailure.details
            isRemuxing = false
            return
        }

        do {
            if FileManager.default.fileExists(atPath: outputPath) {
                guard overwrite else {
                    statusMessage = "The output file already exists."
                    isRemuxing = false
                    return
                }
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            }
        } catch {
            statusMessage = "Could not save the edited MP4: \(error.localizedDescription)"
            errorDetails = """
            Track Editor Error
            Stage: Saving validated output
            Source: \(inputPath)
            Destination: \(outputPath)
            Error: \(error.localizedDescription)
            """
            isRemuxing = false
            return
        }

        statusMessage = "Created \(URL(fileURLWithPath: outputPath).lastPathComponent)."
        isRemuxing = false
    }

    private func updateDefaultOutputLocation() {
        guard !inputPath.isEmpty else { return }
        let inputURL = URL(fileURLWithPath: inputPath)
        outputFolderPath = inputURL.deletingLastPathComponent().path
        outputFileName = replaceOriginal
            ? inputURL.lastPathComponent
            : inputURL.deletingPathExtension().lastPathComponent + "_edited.mp4"
    }

    private func startProgressTimer() {
        progressTimerTask?.cancel()
        progressTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isRemuxing else { return }
                self.refreshProgressTiming()
            }
        }
    }

    private func updateRemuxProgress(encodedSeconds: TimeInterval) {
        guard let sourceDuration, sourceDuration > 0 else { return }
        remuxProgress = min(max(encodedSeconds / sourceDuration, 0), 0.999)
        refreshProgressTiming()
    }

    private func refreshProgressTiming() {
        guard let remuxStartedAt else { return }
        remuxElapsed = max(Date().timeIntervalSince(remuxStartedAt), 0)
        guard remuxProgress >= 0.01, remuxProgress < 1 else {
            remuxETA = remuxProgress >= 1 ? 0 : nil
            return
        }
        remuxETA = max((remuxElapsed / remuxProgress) - remuxElapsed, 0)
    }

    private func appendMetadata(
        for track: TrackEditorTrack,
        kindSpecifier: String,
        outputIndex: Int,
        to arguments: inout [String]
    ) {
        let language = track.language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !language.isEmpty {
            arguments.append(contentsOf: ["-metadata:s:\(kindSpecifier):\(outputIndex)", "language=\(language)"])
        }
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            arguments.append(contentsOf: ["-metadata:s:\(kindSpecifier):\(outputIndex)", "title=\(title)"])
            arguments.append(contentsOf: ["-metadata:s:\(kindSpecifier):\(outputIndex)", "handler_name=\(title)"])
        }
    }

    private func validationIssue(
        outputPath: String,
        expectedCounts: [TrackEditorTrackKind: Int]
    ) async -> TrackEditorValidationFailure? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath),
              let size = attributes[.size] as? NSNumber,
              size.int64Value >= 1_024 else {
            return TrackEditorValidationFailure(
                message: "output is missing or empty",
                details: validationReport(
                    message: "Output is missing or smaller than 1 KB.",
                    outputPath: outputPath,
                    outputSize: nil,
                    outputProbe: nil,
                    expectedCounts: expectedCounts
                )
            )
        }
        guard let outputProbe = await probe(path: outputPath) else {
            return TrackEditorValidationFailure(
                message: "FFprobe could not read the output",
                details: validationReport(
                    message: "FFprobe could not decode the temporary output metadata.",
                    outputPath: outputPath,
                    outputSize: size.int64Value,
                    outputProbe: nil,
                    expectedCounts: expectedCounts
                )
            )
        }
        for kind in TrackEditorTrackKind.allCases {
            let actual = outputProbe.streams.filter { $0.codecType == kind.rawValue }.count
            let expected = expectedCounts[kind, default: 0]
            guard actual == expected else {
                let message = "expected \(expected) \(kind.label.lowercased()) track(s), found \(actual)"
                return TrackEditorValidationFailure(
                    message: message,
                    details: validationReport(
                        message: message,
                        outputPath: outputPath,
                        outputSize: size.int64Value,
                        outputProbe: outputProbe,
                        expectedCounts: expectedCounts
                    )
                )
            }
        }
        if let sourceVideoDuration,
           let outputVideoDuration = outputProbe.streams
               .first(where: { $0.codecType == TrackEditorTrackKind.video.rawValue })?
               .duration
               .flatMap(TimeInterval.init) {
            let tolerance = max(5, min(30, sourceVideoDuration * 0.005))
            guard abs(sourceVideoDuration - outputVideoDuration) <= tolerance else {
                let difference = abs(sourceVideoDuration - outputVideoDuration)
                let message = "output video duration differs from the source"
                return TrackEditorValidationFailure(
                    message: message,
                    details: validationReport(
                        message: "\(message) by \(Self.preciseDuration(difference)); allowed tolerance is \(Self.preciseDuration(tolerance)).",
                        outputPath: outputPath,
                        outputSize: size.int64Value,
                        outputProbe: outputProbe,
                        expectedCounts: expectedCounts
                    )
                )
            }
        }

        let asset = AVURLAsset(url: URL(fileURLWithPath: outputPath))
        guard (try? await asset.load(.isPlayable)) == true else {
            let message = "Apple media frameworks cannot play the output"
            return TrackEditorValidationFailure(
                message: message,
                details: validationReport(
                    message: message,
                    outputPath: outputPath,
                    outputSize: size.int64Value,
                    outputProbe: outputProbe,
                    expectedCounts: expectedCounts
                )
            )
        }
        let expectedAudioCount = expectedCounts[.audio, default: 0]
        let appleAudioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard appleAudioTracks.count == expectedAudioCount else {
            let message = "Apple media frameworks can read \(appleAudioTracks.count) of \(expectedAudioCount) expected audio track(s)"
            return TrackEditorValidationFailure(
                message: message,
                details: validationReport(
                    message: message,
                    outputPath: outputPath,
                    outputSize: size.int64Value,
                    outputProbe: outputProbe,
                    expectedCounts: expectedCounts
                )
            )
        }
        return nil
    }

    private func validationReport(
        message: String,
        outputPath: String,
        outputSize: Int64?,
        outputProbe: TrackEditorProbeOutput?,
        expectedCounts: [TrackEditorTrackKind: Int]
    ) -> String {
        let outputContainerDuration = outputProbe?.format?.duration.flatMap(TimeInterval.init)
        let outputVideoDuration = outputProbe?.streams
            .first(where: { $0.codecType == TrackEditorTrackKind.video.rawValue })?
            .duration
            .flatMap(TimeInterval.init)
        let actualCounts = TrackEditorTrackKind.allCases.map { kind in
            let expected = expectedCounts[kind, default: 0]
            let actual = outputProbe?.streams.filter { $0.codecType == kind.rawValue }.count
            return "  \(kind.label): expected \(expected), found \(actual.map(String.init) ?? "unavailable")"
        }.joined(separator: "\n")
        let durationDifference: String
        let durationTolerance: String
        if let sourceVideoDuration, let outputVideoDuration {
            durationDifference = Self.preciseDuration(abs(sourceVideoDuration - outputVideoDuration))
            durationTolerance = Self.preciseDuration(max(5, min(30, sourceVideoDuration * 0.005)))
        } else {
            durationDifference = "unavailable"
            durationTolerance = "unavailable"
        }

        return """
        Track Editor Validation Error
        Date: \(ISO8601DateFormatter().string(from: Date()))
        Reason: \(message)
        Source: \(inputPath)
        Temporary output: \(outputPath)
        Output size: \(outputSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unavailable")

        Durations:
          Source container: \(Self.optionalDuration(sourceDuration))
          Source video: \(Self.optionalDuration(sourceVideoDuration))
          Output container: \(Self.optionalDuration(outputContainerDuration))
          Output video: \(Self.optionalDuration(outputVideoDuration))
          Video difference: \(durationDifference)
          Allowed tolerance: \(durationTolerance)

        Stream counts:
        \(actualCounts)

        FFmpeg: \(ffmpegPath)
        FFprobe: \(ffprobePath)
        Note: Duration validation compares the primary video streams, not container duration.
        """
    }

    private func makeTrack(
        from stream: TrackEditorProbeStream,
        sourcePath: String,
        inputOrdinal: Int,
        isExternal: Bool
    ) -> TrackEditorTrack? {
        guard let type = stream.codecType,
              let kind = TrackEditorTrackKind(rawValue: type) else {
            return nil
        }
        let codec = stream.codecName ?? "unknown"
        let muxable: Bool
        let note: String?
        if kind == .subtitle && !isTextSubtitleCodec(codec) {
            muxable = false
            note = "Image subtitles cannot be stored as MP4 text subtitles"
        } else {
            muxable = true
            note = nil
        }
        let title = meaningfulTrackTitle(from: stream.tags)
        let sourceLanguage = stream.tags?["language"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let language = isExternal && kind == .subtitle && (sourceLanguage == nil || sourceLanguage == "" || sourceLanguage == "und")
            ? "eng"
            : (sourceLanguage ?? "und")
        return TrackEditorTrack(
            inputOrdinal: inputOrdinal,
            streamIndex: stream.index,
            sourcePath: sourcePath,
            kind: kind,
            codec: codec,
            channels: stream.channels,
            channelLayout: stream.channelLayout,
            width: stream.width,
            height: stream.height,
            isExternal: isExternal,
            isMuxable: muxable,
            compatibilityNote: note,
            isIncluded: muxable,
            language: language,
            title: title,
            isDefault: isExternal ? false : stream.disposition?.isDefault == 1,
            isForced: stream.disposition?.isForced == 1,
            isHearingImpaired: stream.disposition?.isHearingImpaired == 1,
            isCaptions: stream.disposition?.isCaptions == 1
        )
    }

    private func subtitleDispositionValue(for track: TrackEditorTrack) -> String {
        var values: [String] = []
        if track.isDefault { values.append("default") }
        if track.isForced { values.append("forced") }
        if track.isHearingImpaired { values.append("hearing_impaired") }
        if track.isCaptions { values.append("captions") }
        return values.isEmpty ? "0" : values.joined(separator: "+")
    }

    private func meaningfulTrackTitle(from tags: [String: String]?) -> String {
        if let title = tags?["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        let handlerName = tags?["handler_name"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let genericHandlerNames = [
            "soundhandler",
            "videohandler",
            "subtitlehandler",
            "mediahandler"
        ]
        return genericHandlerNames.contains(handlerName.lowercased()) ? "" : handlerName
    }

    private func probe(path: String) async -> TrackEditorProbeOutput? {
        let result = await runProcess(path: ffprobePath, arguments: [
            "-v", "error",
            "-show_streams",
            "-show_format",
            "-print_format", "json",
            path
        ])
        guard let result, result.exitCode == 0,
              let data = result.stdout.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TrackEditorProbeOutput.self, from: data)
    }

    private var sanitizedOutputFileName: String {
        var name = outputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "" }
        if !name.lowercased().hasSuffix(".mp4") {
            name += ".mp4"
        }
        return name
    }

    private func isMP4CompatibleAudioCodec(_ codec: String) -> Bool {
        ["aac", "alac", "mp3", "ac3", "eac3"].contains(codec.lowercased())
    }

    private func isTextSubtitleCodec(_ codec: String) -> Bool {
        ["mov_text", "subrip", "srt", "ass", "ssa", "webvtt", "text"].contains(codec.lowercased())
    }

    private func canonicalChannelLayout(channels: Int?, fallback: String?) -> String? {
        switch channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return fallback
        }
    }

    private func aacBitrate(channels: Int?) -> String {
        switch channels {
        case 6: return "256k"
        case 8: return "512k"
        default: return "192k"
        }
    }

    private func lastMeaningfulLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
    }

    private func runFFmpegWithProgress(
        path: String,
        arguments: [String]
    ) async -> (exitCode: Int32, stdout: String, stderr: String)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                let capture = TrackEditorProcessOutput()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    for line in capture.appendStdout(data) {
                        guard let encodedSeconds = Self.encodedSeconds(fromProgressLine: line) else { continue }
                        Task { @MainActor [weak self] in
                            self?.updateRemuxProgress(encodedSeconds: encodedSeconds)
                        }
                    }
                }
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    capture.appendStderr(handle.availableData)
                }

                do {
                    self.processLock.lock()
                    self.currentProcess = process
                    self.processLock.unlock()
                    try process.run()
                    process.waitUntilExit()

                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    for line in capture.appendStdout(outputPipe.fileHandleForReading.readDataToEndOfFile()) {
                        guard let encodedSeconds = Self.encodedSeconds(fromProgressLine: line) else { continue }
                        Task { @MainActor [weak self] in
                            self?.updateRemuxProgress(encodedSeconds: encodedSeconds)
                        }
                    }
                    capture.appendStderr(errorPipe.fileHandleForReading.readDataToEndOfFile())

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

    private nonisolated static func encodedSeconds(fromProgressLine line: String) -> TimeInterval? {
        let fields = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard fields.count == 2 else { return nil }
        switch fields[0] {
        case "out_time_us":
            guard let microseconds = Double(fields[1]) else { return nil }
            return microseconds / 1_000_000
        case "out_time_ms":
            // FFmpeg historically names this field _ms even though its value is microseconds.
            guard let microseconds = Double(fields[1]) else { return nil }
            return microseconds / 1_000_000
        case "out_time":
            let components = fields[1].split(separator: ":").compactMap { Double($0) }
            guard components.count == 3 else { return nil }
            return (components[0] * 3_600) + (components[1] * 60) + components[2]
        default:
            return nil
        }
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
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                do {
                    self.processLock.lock()
                    self.currentProcess = process
                    self.processLock.unlock()
                    try process.run()
                    process.waitUntilExit()
                    let stdout = String(
                        data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    let stderr = String(
                        data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    self.processLock.lock()
                    if self.currentProcess === process { self.currentProcess = nil }
                    self.processLock.unlock()
                    continuation.resume(returning: (process.terminationStatus, stdout, stderr))
                } catch {
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

    private static func findExecutable(named name: String) -> String? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "bin")?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private static func contentTypes(for extensions: [String]) -> [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0) }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private static func preciseDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f seconds", duration)
    }

    private static func optionalDuration(_ duration: TimeInterval?) -> String {
        duration.map(preciseDuration) ?? "unavailable"
    }

    private static func commandDescription(path: String, arguments: [String]) -> String {
        ([path] + arguments).map { argument in
            guard argument.contains(where: { $0.isWhitespace || $0 == "\"" }) else {
                return argument
            }
            return "\"\(argument.replacingOccurrences(of: "\"", with: "\\\""))\""
        }.joined(separator: " ")
    }
}
