//
//  VideoProcessor.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import Foundation
import Combine
import UserNotifications
import AppKit
import AVFoundation
import SwiftUI
import Darwin

struct VideoStream: Codable {
    let index: Int
    let codecType: String?
    let codecName: String?
    let profile: String?
    let codecTagString: String?
    let sampleFormat: String?
    let bitRate: String?
    let channels: Int?
    let channelLayout: String?
    let startTime: String?
    let duration: String?
    let tags: [String: String]?
    let width: Int?
    let height: Int?
    let averageFrameRate: String?
    let realFrameRate: String?
    let nbFrames: String?
    let nbReadPackets: String?
    let disposition: VideoStreamDisposition?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case profile
        case codecTagString = "codec_tag_string"
        case sampleFormat = "sample_fmt"
        case bitRate = "bit_rate"
        case channels
        case channelLayout = "channel_layout"
        case startTime = "start_time"
        case duration
        case tags
        case width
        case height
        case averageFrameRate = "avg_frame_rate"
        case realFrameRate = "r_frame_rate"
        case nbFrames = "nb_frames"
        case nbReadPackets = "nb_read_packets"
        case disposition
    }
}

struct VideoStreamDisposition: Codable {
    let isDefault: Int?
    let isForced: Int?
    let isHearingImpaired: Int?
    let isCaptions: Int?
    let isCommentary: Int?
    let isVisualImpaired: Int?
    let isDub: Int?
    let isOriginal: Int?

    enum CodingKeys: String, CodingKey {
        case isDefault = "default"
        case isForced = "forced"
        case isHearingImpaired = "hearing_impaired"
        case isCaptions = "captions"
        case isCommentary = "comment"
        case isVisualImpaired = "visual_impaired"
        case isDub = "dub"
        case isOriginal = "original"
    }
}

struct FFProbeOutput: Codable {
    let streams: [VideoStream]
}

private struct AudioMapping {
    let index: Int
    let codecName: String?
    let language: String?
    let channels: Int?
    let sourceChannelLayout: String?
    let channelLayout: String?
    let duration: TimeInterval?
}

private struct SubtitleMapping {
    let index: Int
    let language: String?
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isCaptions: Bool
    let selectionRationale: String?
}

private struct SubtitleSelectionPlan {
    let sourceFile: String
    let mappings: [SubtitleMapping]
    let isExternal: Bool
}

private struct SmartPreflightItem {
    let mode: ProcessingMode
    let duration: TimeInterval?
    let inputBytes: Int64
}

enum ProcessingMode: String, CaseIterable {
    case smart = "smart"
    case encodeH264 = "encode_h264"
    case encodeH265 = "encode_h265"
    case remux = "remux"

    static let defaultSmartRemuxMegabytesPerMinute = 25.0

    var description: String {
        switch self {
        case .smart: return "Smart (Automatic)"
        case .encodeH264: return "Encode (H.264)"
        case .encodeH265: return "Encode (H.265)"
        case .remux: return "Remux (Copy to MP4)"
        }
    }
}

enum ResolutionOption: String, CaseIterable {
    case `default` = "default"
    case p1080 = "1080p"
    case p720 = "720p"

    var description: String {
        switch self {
        case .default: return "Original Resolution"
        case .p1080: return "1080p"
        case .p720: return "720p"
        }
    }

    func scaleFilter(width: Int, height: Int) -> String? {
        switch self {
        case .default:
            return nil
        case .p1080:
            let targetSize = 1080
            // Smart scaling: if portrait (height > width), scale by width; otherwise by height
            // Never upscale - only downscale or maintain original resolution
            if height > width {
                // Portrait: check width
                if width > targetSize {
                    return "scale=w=\(targetSize):h=-2:out_range=tv,format=yuv420p"
                }
            } else {
                // Landscape: check height
                if height > targetSize {
                    return "scale=w=-2:h=\(targetSize):out_range=tv,format=yuv420p"
                }
            }
            // Don't upscale - return nil to keep original resolution
            return nil
        case .p720:
            let targetSize = 720
            // Smart scaling: if portrait (height > width), scale by width; otherwise by height
            // Never upscale - only downscale or maintain original resolution
            if height > width {
                // Portrait: check width
                if width > targetSize {
                    return "scale=w=\(targetSize):h=-2:out_range=tv,format=yuv420p"
                }
            } else {
                // Landscape: check height
                if height > targetSize {
                    return "scale=w=-2:h=\(targetSize):out_range=tv,format=yuv420p"
                }
            }
            // Don't upscale - return nil to keep original resolution
            return nil
        }
    }
}

enum PresetOption: String, CaseIterable {
    case ultrafast
    case superfast
    case veryfast
    case faster
    case fast
    case medium
    case slow
    case slower
    case veryslow
    case placebo

    var description: String {
        self.rawValue.capitalized
    }
}

enum PostProcessScriptRunTiming: String, CaseIterable {
    case afterEachItem = "after_each_item"
    case atEnd = "at_end"

    var description: String {
        switch self {
        case .afterEachItem: return "Run after each item"
        case .atEnd: return "Run at the end"
        }
    }
}

enum ProcessingStatus {
    case pending
    case processing
    case completed
    case skipped
    case failed
}

private enum ConversionOutcome {
    case success(mode: ProcessingMode)
    case skipped(reason: String)
    case failed(reason: String)
}

struct VideoFileInfo: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let fileExtension: String
    let fileSizeMB: Int
    var status: ProcessingStatus = .pending
    var processingStartTime: Date? = nil
    var processingEndTime: Date? = nil
    var processingTimeSeconds: Int = 0
    var newSizeMB: Int = 0
    var hasConflict: Bool = false
    var conflictReason: String = ""
}

struct ProcessingCompletionSummary: Equatable {
    let mode: ProcessingMode
    let completedFileCount: Int
    let skippedFileCount: Int
    let failedFileCount: Int
    let originalBytes: Int64
    let outputBytes: Int64
    let startedAt: Date
    let endedAt: Date

    var savedBytes: Int64 {
        originalBytes - outputBytes
    }

    var runTime: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }
}

private struct CompletedPostProcessFile {
    let inputPath: String
    let outputPath: String
    let fileName: String
}

private struct PostProcessScriptResult {
    let terminationStatus: Int32?
    let outputText: String
    let errorText: String
    let startErrorMessage: String?
}

private final class ThreadSafeDataBuffer: @unchecked Sendable {
    private nonisolated(unsafe) var data = Data()
    private let lock = NSLock()
    private let maxBytes: Int?

    nonisolated init(maxBytes: Int? = 131_072) {
        self.maxBytes = maxBytes
    }

    nonisolated func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        if let maxBytes, data.count > maxBytes {
            data.removeFirst(data.count - maxBytes)
        }
        lock.unlock()
    }

    nonisolated func snapshot() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}

class VideoProcessor: ObservableObject {
    @AppStorage("useSystemFFmpeg") private var useSystemFFmpeg = false

    @Published var isProcessing = false
    @Published var currentFile = ""
    @Published var totalFiles = 0
    @Published var currentFileIndex = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var originalSize: Int64 = 0
    @Published var newSize: Int64 = 0
    @Published var currentFileProgressFraction: Double = 0
    @Published var logText: String = ""
    @Published var scanProgress: String = ""
    @Published var encodingProgress: String = ""
    @Published var videoFiles: [VideoFileInfo] = []
    @Published var ffmpegAvailable = false
    @Published var ffmpegMissingMessage = ""
    @Published var processingHadError = false
    @Published var completionSummary: ProcessingCompletionSummary?
    @Published private(set) var processingStartedAt: Date?
    @Published private(set) var activeMode: ProcessingMode?
    @Published private(set) var activeItemMode: ProcessingMode?
    @Published private(set) var stopAfterCurrentFileRequested = false
    @Published private(set) var currentFramePreview: NSImage?
    @Published private(set) var notificationsEnabled =
        UserDefaults.standard.object(forKey: "processingNotificationsEnabled") as? Bool ?? true
    @Published private(set) var framePreviewsEnabled =
        UserDefaults.standard.object(forKey: "framePreviewsEnabled") as? Bool ?? true

    private var startTime: Date?
    private var currentInputDurationSeconds: TimeInterval?
    private var currentInputFrameRate: Double?
    private var currentEncodedTimeSeconds: TimeInterval = 0
    private var latestFFmpegTimestampSeconds: TimeInterval?
    private var lastFFmpegTimestampAdvanceAt: Date?
    private var estimatedBatchCompletionDate: Date?
    private var ffmpegProgressTail: String = ""
    private var timer: Timer?
    private nonisolated(unsafe) var shouldCancelScan = false
    private nonisolated(unsafe) var shouldCancelProcessing = false
    private var encodingTimer: Timer?
    private var currentProcess: Process?
    private var forcedStopTask: Task<Void, Never>?
    private var framePreviewTask: Task<Void, Never>?
    private var framePreviewProcess: Process?
    private var framePreviewToken = UUID()
    private var activeFramePreviewInputFile: String?
    private var activeHistoryFFmpegCommands: [String] = []
    private var activeProcessingFilePath: String?
    private var smartPreflightItems: [String: SmartPreflightItem] = [:]

    // Batch processing tracking
    private var pendingBatchFiles: [VideoFileInfo] = []

    private var ffmpegPath: String = ""
    private var ffprobePath: String = ""
    var bundledFfmpegPath: String = ""
    var bundledFfprobePath: String = ""
    @Published var hasBundledFFmpeg: Bool = false
    @Published var hasSystemFFmpeg: Bool = false
    @Published var isUsingSystemFFmpeg: Bool = false

    private nonisolated static let ffmpegTimeRegex: NSRegularExpression = {
        let pattern = #"(?:time|out_time)=\s*([0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?)"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private nonisolated static let ffmpegFrameRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(?:^|[\r\n])frame=\s*([0-9]+)"#)
    }()

    init() {
        var foundBundledFfmpeg = false
        var foundBundledFfprobe = false
        var bundledFfmpeg = ""
        var bundledFfprobe = ""

        // 1. Try to find bundled binaries in Resources
        if let ffmpegURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "bin"),
           let ffprobeURL = Bundle.main.url(forResource: "ffprobe", withExtension: nil, subdirectory: "bin") {
            bundledFfmpeg = ffmpegURL.path
            bundledFfprobe = ffprobeURL.path
            foundBundledFfmpeg = FileManager.default.fileExists(atPath: bundledFfmpeg)
            foundBundledFfprobe = FileManager.default.fileExists(atPath: bundledFfprobe)
        } else if let ffmpegURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
                  let ffprobeURL = Bundle.main.url(forResource: "ffprobe", withExtension: nil) {
            // If bin folder was flattened
            bundledFfmpeg = ffmpegURL.path
            bundledFfprobe = ffprobeURL.path
            foundBundledFfmpeg = FileManager.default.fileExists(atPath: bundledFfmpeg)
            foundBundledFfprobe = FileManager.default.fileExists(atPath: bundledFfprobe)
        } else {
            // Fallback to resource path
            let resourcePath = Bundle.main.resourcePath ?? ""
            bundledFfmpeg = resourcePath + "/bin/ffmpeg"
            bundledFfprobe = resourcePath + "/bin/ffprobe"
            foundBundledFfmpeg = FileManager.default.fileExists(atPath: bundledFfmpeg)
            foundBundledFfprobe = FileManager.default.fileExists(atPath: bundledFfprobe)
        }

        // Store bundled paths for later toggling
        self.bundledFfmpegPath = foundBundledFfmpeg ? bundledFfmpeg : ""
        self.bundledFfprobePath = foundBundledFfprobe ? bundledFfprobe : ""
        self.hasBundledFFmpeg = foundBundledFfmpeg && foundBundledFfprobe

        // Check for system FFmpeg availability
        let systemFfmpeg = Self.findInPath(command: "ffmpeg")
        let systemFfprobe = Self.findInPath(command: "ffprobe")
        let hasSystemFfmpeg = systemFfmpeg != nil && systemFfprobe != nil
        self.hasSystemFFmpeg = hasSystemFfmpeg

        // Log FFmpeg availability enumeration
        addLog("═══ FFmpeg Enumeration ═══")
        addLog("Bundled FFmpeg: \(self.hasBundledFFmpeg ? "✓ Available" : "✗ Not Available")")
        addLog("System FFmpeg: \(hasSystemFfmpeg ? "✓ Available" : "✗ Not Available")")

        // If multiple FFmpeg options are available, show where to choose one.
        let availableCount = (self.hasBundledFFmpeg ? 1 : 0) + (hasSystemFfmpeg ? 1 : 0)
        if availableCount > 1 {
            addLog("Multiple FFmpeg versions available - choose a source in Processing Setup")
        }

        // Restore the preferred source when available, otherwise use the available fallback.
        var tempFfmpegPath = ""
        var tempFfprobePath = ""
        var foundFfmpeg = false
        var foundFfprobe = false

        if useSystemFFmpeg, hasSystemFfmpeg {
            tempFfmpegPath = systemFfmpeg ?? ""
            tempFfprobePath = systemFfprobe ?? ""
            foundFfmpeg = !tempFfmpegPath.isEmpty
            foundFfprobe = !tempFfprobePath.isEmpty
            self.isUsingSystemFFmpeg = true
        } else if self.hasBundledFFmpeg {
            tempFfmpegPath = bundledFfmpeg
            tempFfprobePath = bundledFfprobe
            foundFfmpeg = true
            foundFfprobe = true
            self.isUsingSystemFFmpeg = false
        } else if hasSystemFfmpeg {
            // Try system PATH
            tempFfmpegPath = systemFfmpeg ?? ""
            tempFfprobePath = systemFfprobe ?? ""
            foundFfmpeg = !tempFfmpegPath.isEmpty
            foundFfprobe = !tempFfprobePath.isEmpty
            self.isUsingSystemFFmpeg = true
        }

        self.ffmpegPath = tempFfmpegPath
        self.ffprobePath = tempFfprobePath

        // Set availability status
        if foundFfmpeg && foundFfprobe {
            self.ffmpegAvailable = true
            addLog("Active FFmpeg: \(tempFfmpegPath)")
            addLog("Active FFprobe: \(tempFfprobePath)")
        } else {
            self.ffmpegAvailable = false
            var missing: [String] = []
            if !foundFfmpeg { missing.append("ffmpeg") }
            if !foundFfprobe { missing.append("ffprobe") }
            self.ffmpegMissingMessage = "Missing required tools: \(missing.joined(separator: ", ")).\nPlease install ffmpeg & ffprobe. Or compile this app with binaries bundled into the Resource folder."
            addLog("􀇾 WARNING: \(self.ffmpegMissingMessage)")
        }

        let abandonedFileCount = ProcessingStagingStorage.cleanupAbandonedFiles()
        if abandonedFileCount > 0 {
            addLog("Cleaned \(abandonedFileCount) abandoned staging file(s) from an earlier run.")
        }
    }

    private static func findInPath(command: String) -> String? {
        // Check common system paths first
        let commonPaths = [
            "/usr/local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "/usr/bin/\(command)",
            "/bin/\(command)"
        ]

        for path in commonPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Fallback to using 'which' command
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
            print("Error finding \(command) in PATH: \(error)")
        }

        return nil
    }

    private func appendLogEntry(_ message: String) {
        if !self.logText.isEmpty {
            self.logText += "\n"
        }
        self.logText += message
        PersistentProcessingLog.shared.append(message)
        print(message)
    }

    func addLog(_ message: String) {
        if Thread.isMainThread {
            appendLogEntry(message)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.appendLogEntry(message)
        }
    }

    func toggleFFmpegSource(useSystem: Bool) {
        guard hasBundledFFmpeg else {
            addLog("􀇾 Cannot toggle: no bundled FFmpeg available")
            return
        }

        if useSystem {
            // Switch to system FFmpeg
            let systemFfmpeg = Self.findInPath(command: "ffmpeg")
            let systemFfprobe = Self.findInPath(command: "ffprobe")

            if let systemFfmpeg = systemFfmpeg, let systemFfprobe = systemFfprobe {
                self.ffmpegPath = systemFfmpeg
                self.ffprobePath = systemFfprobe
                self.ffmpegAvailable = true
                self.isUsingSystemFFmpeg = true
                self.useSystemFFmpeg = true
                addLog("✓ Switched to system FFmpeg at: \(systemFfmpeg)")
            } else {
                self.ffmpegAvailable = false
                self.ffmpegMissingMessage = "System FFmpeg not found. Please install ffmpeg and ffprobe."
                addLog("􀇾 WARNING: System FFmpeg not found")
            }
        } else {
            // Switch back to bundled FFmpeg
            self.ffmpegPath = bundledFfmpegPath
            self.ffprobePath = bundledFfprobePath
            self.ffmpegAvailable = true
            self.isUsingSystemFFmpeg = false
            self.useSystemFFmpeg = false
            addLog("✓ Switched to bundled FFmpeg")
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "processingNotificationsEnabled")
        if !enabled {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: ["processingComplete"]
            )
        }
    }

    func setFramePreviewsEnabled(_ enabled: Bool) {
        framePreviewsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "framePreviewsEnabled")

        if enabled,
           isProcessing,
           activeItemMode != .remux,
           let activeFramePreviewInputFile {
            startFramePreviewUpdates(inputFile: activeFramePreviewInputFile)
        } else if !enabled {
            stopFramePreviewUpdates(clearPreview: true)
        }
    }

    private func getTimestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private func formatDuration(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m \(secs)s"
        } else {
            return "\(minutes)m \(secs)s"
        }
    }

    private func formattedByteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }

    private func shellEscaped(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:=@+,%"))
        if argument.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return argument
        }
        return "'\(argument.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func shellCommand(executable: String, arguments: [String]) -> String {
        ([executable] + arguments).map(shellEscaped).joined(separator: " ")
    }

    private nonisolated static func isFFmpegProgressLine(_ line: String) -> Bool {
        let key = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "=", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        return [
            "frame", "fps", "bitrate", "total_size", "out_time_us", "out_time_ms",
            "out_time", "dup_frames", "drop_frames", "speed", "progress"
        ].contains(key) || key.hasPrefix("stream_")
    }

    private nonisolated static func diagnosticLines(from output: String, limit: Int = 50) -> [String] {
        let meaningful = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !isFFmpegProgressLine($0) }
        return Array(meaningful.suffix(limit))
    }

    private nonisolated static func mostMeaningfulError(in lines: [String], exitCode: Int32) -> String {
        let indicators = ["error", "invalid", "not found", "unknown", "failed", "incompatible", "denied"]
        if let match = lines.reversed().first(where: { line in
            let normalized = line.lowercased()
            return indicators.contains(where: normalized.contains)
        }) {
            return match
        }
        return lines.last ?? "FFmpeg exited with code \(exitCode)"
    }

    private nonisolated static func latestFFmpegProgressValue(
        _ key: String,
        in output: String
    ) -> String? {
        let prefix = "\(key)="
        return output
            .split(whereSeparator: \.isNewline)
            .reversed()
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
    }

    private nonisolated static func terminationReasonDescription(
        _ reason: Process.TerminationReason
    ) -> String {
        switch reason {
        case .exit:
            return "exit"
        case .uncaughtSignal:
            return "uncaught signal"
        @unknown default:
            return "unknown"
        }
    }

    private func toolVersion(path: String) async -> String {
        guard !path.isEmpty,
              let output = await runCommandWithOutput(path: path, arguments: ["-version"]),
              let firstLine = output.split(whereSeparator: \.isNewline).first else {
            return "Unavailable"
        }
        return String(firstLine)
    }

    private func logBatchSummary(_ summary: ProcessingCompletionSummary, cancelled: Bool) {
        let savedBytes = summary.savedBytes
        let savedPercentage = summary.originalBytes > 0
            ? Double(savedBytes) / Double(summary.originalBytes) * 100
            : 0

        addLog("\n═══ Batch Summary ═══")
        addLog("Status: \(cancelled ? "Cancelled" : "Completed")")
        addLog("Files: \(summary.completedFileCount) completed, \(summary.skippedFileCount) skipped, \(summary.failedFileCount) failed")
        addLog("Original Size: \(formattedByteCount(summary.originalBytes))")
        addLog("Output Size: \(formattedByteCount(summary.outputBytes))")
        addLog("Space Saved: \(formattedByteCount(savedBytes)) (\(String(format: "%.1f", savedPercentage))%)")
        addLog("Total Runtime: \(formatDuration(seconds: Int(summary.runTime)))")
        addLog("Finished: \(formattedDate(summary.endedAt))")
        addLog("═════════════════════")
    }

    private nonisolated static func latestFFmpegMediaTimeSeconds(in text: String) -> TimeInterval? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = ffmpegTimeRegex.matches(in: text, range: range)
        guard let match = matches.last,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let value = String(text[captureRange])
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return TimeInterval(hours * 3600) + TimeInterval(minutes * 60) + seconds
    }

    private nonisolated static func latestFFmpegFrame(in text: String) -> Int? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = ffmpegFrameRegex.matches(in: text, range: range)
        guard let match = matches.last,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[captureRange])
    }

    private static func frameRate(from value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        let frameRate: Double?
        if components.count == 2,
           let numerator = Double(components[0]),
           let denominator = Double(components[1]),
           denominator != 0 {
            frameRate = numerator / denominator
        } else {
            frameRate = Double(value)
        }

        guard let frameRate, frameRate.isFinite, frameRate > 0 else { return nil }
        return frameRate
    }

    private func estimateCurrentFileETASeconds(elapsedWallSeconds: TimeInterval) -> TimeInterval? {
        guard let duration = currentInputDurationSeconds,
              duration > 0,
              currentEncodedTimeSeconds > 0 else {
            return nil
        }

        let progress = min(max(currentEncodedTimeSeconds / duration, 0), 0.999)
        guard progress >= 0.01 else {
            return nil
        }

        let estimatedTotal = elapsedWallSeconds / progress
        return max(estimatedTotal - elapsedWallSeconds, 0)
    }

    private func estimateAllFilesETASeconds(
        currentFileETA: TimeInterval?,
        currentFileEstimatedTotalWallSeconds: TimeInterval?
    ) -> TimeInterval? {
        guard let currentFileETA else {
            return nil
        }

        if activeMode == .smart {
            return currentFileETA + estimatePendingSmartWorkSeconds(
                currentFileEstimatedTotalWallSeconds: currentFileEstimatedTotalWallSeconds
            )
        }

        let remainingAfterCurrent = max(totalFiles - currentFileIndex, 0)
        let completedDurations = videoFiles.compactMap { file -> TimeInterval? in
            guard file.status == .completed else {
                return nil
            }
            guard let start = file.processingStartTime,
                  let end = file.processingEndTime else {
                return nil
            }
            return max(end.timeIntervalSince(start), 0)
        }

        let perFileEstimate: TimeInterval
        if !completedDurations.isEmpty {
            perFileEstimate = completedDurations.reduce(0, +) / Double(completedDurations.count)
        } else if let currentFileEstimatedTotalWallSeconds, currentFileEstimatedTotalWallSeconds > 0 {
            perFileEstimate = currentFileEstimatedTotalWallSeconds
        } else {
            perFileEstimate = currentFileETA
        }

        return currentFileETA + (Double(remainingAfterCurrent) * perFileEstimate)
    }

    private func estimatePendingSmartWorkSeconds(
        currentFileEstimatedTotalWallSeconds: TimeInterval?
    ) -> TimeInterval {
        let completed = videoFiles.filter { $0.status == .completed }
        var encodeWallSecondsPerMediaSecond: [Double] = []
        var remuxBytesPerSecond: [Double] = []

        for file in completed {
            guard let plan = smartPreflightItems[file.filePath],
                  let startedAt = file.processingStartTime,
                  let endedAt = file.processingEndTime else {
                continue
            }
            let wallSeconds = max(endedAt.timeIntervalSince(startedAt), 0.1)
            switch plan.mode {
            case .remux:
                if plan.inputBytes > 0 {
                    remuxBytesPerSecond.append(Double(plan.inputBytes) / wallSeconds)
                }
            case .encodeH264, .encodeH265, .smart:
                if let duration = plan.duration, duration > 0 {
                    encodeWallSecondsPerMediaSecond.append(wallSeconds / duration)
                }
            }
        }

        if activeItemMode == .encodeH264 || activeItemMode == .encodeH265,
           let activeProcessingFilePath,
           let activePlan = smartPreflightItems[activeProcessingFilePath],
           let duration = activePlan.duration,
           duration > 0,
           let currentFileEstimatedTotalWallSeconds,
           currentFileEstimatedTotalWallSeconds > 0 {
            encodeWallSecondsPerMediaSecond.append(currentFileEstimatedTotalWallSeconds / duration)
        }

        if activeItemMode == .remux,
           let activeProcessingFilePath,
           let activePlan = smartPreflightItems[activeProcessingFilePath],
           activePlan.inputBytes > 0,
           let currentFileEstimatedTotalWallSeconds,
           currentFileEstimatedTotalWallSeconds > 0 {
            remuxBytesPerSecond.append(
                Double(activePlan.inputBytes) / currentFileEstimatedTotalWallSeconds
            )
        }

        let encodeRate = encodeWallSecondsPerMediaSecond.isEmpty
            ? nil
            : encodeWallSecondsPerMediaSecond.reduce(0, +) / Double(encodeWallSecondsPerMediaSecond.count)
        // Until this run observes a remux, use a conservative local/network copy
        // rate. Once a remux finishes, its measured end-to-end wall time replaces
        // this fallback and naturally accounts for a slow destination share.
        let remuxThroughput = remuxBytesPerSecond.isEmpty
            ? 50_000_000
            : remuxBytesPerSecond.reduce(0, +) / Double(remuxBytesPerSecond.count)

        return videoFiles
            .filter { $0.status == .pending && $0.filePath != activeProcessingFilePath }
            .reduce(0) { total, file in
                guard let plan = smartPreflightItems[file.filePath] else {
                    // A file added during an active batch has not been preflighted.
                    // Retain the previous per-file behavior until it is analyzed.
                    return total + (currentFileEstimatedTotalWallSeconds ?? 0)
                }

                switch plan.mode {
                case .remux:
                    let estimate = plan.inputBytes > 0
                        ? Double(plan.inputBytes) / max(remuxThroughput, 1)
                        : 2
                    return total + max(estimate, 2)
                case .encodeH264, .encodeH265, .smart:
                    if let encodeRate, let duration = plan.duration, duration > 0 {
                        return total + (duration * encodeRate)
                    }
                    return total + (currentFileEstimatedTotalWallSeconds ?? 0)
                }
            }
    }

    private func continuousBatchETASeconds(
        freshEstimate: TimeInterval?,
        now: Date
    ) -> TimeInterval? {
        if let freshEstimate, freshEstimate.isFinite, freshEstimate >= 0 {
            estimatedBatchCompletionDate = now.addingTimeInterval(freshEstimate)
            return freshEstimate
        }

        guard let estimatedBatchCompletionDate else {
            return nil
        }
        return max(estimatedBatchCompletionDate.timeIntervalSince(now), 0)
    }

    func processingETASnapshot() -> (currentFileSeconds: Int?, totalSeconds: Int?) {
        guard isProcessing, let startTime else {
            return (nil, nil)
        }

        let now = Date()
        let elapsedWallSeconds = now.timeIntervalSince(startTime)
        let currentETA = estimateCurrentFileETASeconds(elapsedWallSeconds: elapsedWallSeconds)
        let currentFileEstimatedTotal = currentETA.map { elapsedWallSeconds + $0 }
        let freshTotalETA = estimateAllFilesETASeconds(
            currentFileETA: currentETA,
            currentFileEstimatedTotalWallSeconds: currentFileEstimatedTotal
        )
        let totalETA = continuousBatchETASeconds(freshEstimate: freshTotalETA, now: now)

        return (
            currentETA.map { max(Int($0.rounded(.up)), 0) },
            totalETA.map { max(Int($0.rounded(.up)), 0) }
        )
    }

    private func updateEncodingProgressDisplay(elapsedWallSeconds: TimeInterval) {
        if let duration = currentInputDurationSeconds, duration > 0 {
            currentFileProgressFraction = min(max(currentEncodedTimeSeconds / duration, 0), 1)
        } else {
            currentFileProgressFraction = 0
        }

        let elapsedText = formatDuration(seconds: max(Int(elapsedWallSeconds), 0))
        var parts: [String] = ["Encoding... Elapsed: \(elapsedText)"]

        let currentETA = estimateCurrentFileETASeconds(elapsedWallSeconds: elapsedWallSeconds)
        if let currentETA {
            parts.append("ETA current: \(formatDuration(seconds: max(Int(currentETA), 0)))")
        }

        let currentFileEstimatedTotal = currentETA.map { elapsedWallSeconds + $0 }
        let freshAllETA = estimateAllFilesETASeconds(
            currentFileETA: currentETA,
            currentFileEstimatedTotalWallSeconds: currentFileEstimatedTotal
        )
        if let allETA = continuousBatchETASeconds(freshEstimate: freshAllETA, now: Date()) {
            parts.append("ETA all: \(formatDuration(seconds: max(Int(allETA), 0)))")
        }

        encodingProgress = parts.joined(separator: " • ")
    }

    @MainActor
    private func ingestFFmpegProgressChunk(_ chunk: String) {
        let combined = ffmpegProgressTail + chunk
        if let latestTime = Self.latestFFmpegMediaTimeSeconds(in: combined) {
            if latestFFmpegTimestampSeconds == nil || latestTime > (latestFFmpegTimestampSeconds ?? 0) + 0.001 {
                latestFFmpegTimestampSeconds = latestTime
                lastFFmpegTimestampAdvanceAt = Date()
            }
            currentEncodedTimeSeconds = max(currentEncodedTimeSeconds, latestTime)
        }

        let timestampIsUnavailableOrStale = lastFFmpegTimestampAdvanceAt.map {
            Date().timeIntervalSince($0) >= 5
        } ?? true

        if timestampIsUnavailableOrStale,
           let frame = Self.latestFFmpegFrame(in: combined),
           let frameRate = currentInputFrameRate {
            let frameBasedTime = TimeInterval(frame) / frameRate
            currentEncodedTimeSeconds = max(currentEncodedTimeSeconds, frameBasedTime)
        }
        ffmpegProgressTail = String(combined.suffix(256))
    }

    private func updateDockBadge(filesRemaining: Int) {
        DispatchQueue.main.async {
            let dockTile = NSApplication.shared.dockTile
            dockTile.contentView = nil
            dockTile.badgeLabel = String(filesRemaining)
            dockTile.display()
        }
    }

    private func setDockBadgeCheckmark() {
        DispatchQueue.main.async {
            let dockTile = NSApplication.shared.dockTile
            dockTile.contentView = nil
            dockTile.badgeLabel = "✓"
            dockTile.display()
        }
    }

    func clearDockBadge() {
        DispatchQueue.main.async {
            let dockTile = NSApplication.shared.dockTile
            dockTile.contentView = nil
            dockTile.badgeLabel = nil
            dockTile.display()
        }
    }

    func addToPendingBatch(_ fileInfo: VideoFileInfo) {
        pendingBatchFiles.append(fileInfo)

        // Update dock badge to reflect new total remaining files
        // currentFileIndex is 1-indexed (e.g., File 1/2), so subtract 1 to get processed count
        let filesRemaining = videoFiles.count - (currentFileIndex - 1)
        if filesRemaining > 0 {
            updateDockBadge(filesRemaining: filesRemaining)
        }
    }

    func movePendingFile(_ sourceID: UUID, relativeTo targetID: UUID) {
        let pendingSlots = videoFiles.indices.filter { videoFiles[$0].status == .pending }
        var pendingFiles = pendingSlots.map { videoFiles[$0] }

        guard let sourceIndex = pendingFiles.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = pendingFiles.firstIndex(where: { $0.id == targetID }),
              sourceIndex != targetIndex else {
            return
        }

        pendingFiles.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
        )

        for (slot, file) in zip(pendingSlots, pendingFiles) {
            videoFiles[slot] = file
        }
    }

    func processFolder(
        inputPath: String,
        outputPath: String,
        mode: ProcessingMode,
        smartRemuxMegabytesPerMinute: Double = ProcessingMode.defaultSmartRemuxMegabytesPerMinute,
        crfValue: Int = 23,
        resolution: ResolutionOption = .default,
        preset: PresetOption = .fast,
        encodeVideo: Bool = true,
        encodeAudio: Bool = true,
        createSubfolders: Bool,
        automaticRename: Bool = false,
        deleteOriginal: Bool = false,
        keepEnglishAudioOnly: Bool,
        keepAllEnglishAudioTracks: Bool = false,
        keepEnglishSubtitlesOnly: Bool,
        keepAllEnglishSubtitleTracks: Bool = false,
        postProcessScriptPath: String = "",
        postProcessScriptRunTiming: PostProcessScriptRunTiming = .afterEachItem,
        postProcessScriptPassFileNameAsFirstArgument: Bool = false,
        stageTemporaryFilesOnDestinationVolume: Bool = false
    ) async {
        let sleepAssertion = SystemSleepAssertion(reason: "MP4 Tool is processing video files")
        defer { sleepAssertion.invalidate() }

        let runStartedAt = Date()
        var totalOriginalBytes: Int64 = 0
        var totalOutputBytes: Int64 = 0
        var failedFileCount = 0
        var skippedFileCount = 0
        stopFramePreviewUpdates(clearPreview: true)
        activeProcessingFilePath = nil
        smartPreflightItems = [:]

        // Gather the diagnostic header before replacing the launch-time log so the
        // inspector never passes through an empty state at the start of a run.
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let runIdentifier = String(UUID().uuidString.prefix(8)).uppercased()
        let ffmpegVersion = await toolVersion(path: ffmpegPath)
        let ffprobeVersion = await toolVersion(path: ffprobePath)

        await MainActor.run {
            self.isProcessing = true
            self.processingStartedAt = runStartedAt
            self.activeMode = mode
            self.activeItemMode = mode
            self.logText = ""
            self.currentFileIndex = 0
            self.encodingProgress = ""
            self.currentInputDurationSeconds = nil
            self.currentInputFrameRate = nil
            self.currentEncodedTimeSeconds = 0
            self.latestFFmpegTimestampSeconds = nil
            self.lastFFmpegTimestampAdvanceAt = nil
            self.estimatedBatchCompletionDate = nil
            self.ffmpegProgressTail = ""
            self.currentFileProgressFraction = 0
            self.shouldCancelProcessing = false
            self.stopAfterCurrentFileRequested = false
            self.processingHadError = false
            self.completionSummary = nil
            self.pendingBatchFiles = []

            // Reset all video file statuses to pending when starting a new batch
            for index in 0..<self.videoFiles.count {
                self.videoFiles[index].status = .pending
                self.videoFiles[index].processingStartTime = nil
                self.videoFiles[index].processingEndTime = nil
                self.videoFiles[index].processingTimeSeconds = 0
                self.videoFiles[index].newSizeMB = 0
            }
        }

        addLog("═══ MP4 Tool Processing Run ═══")
        addLog("Run ID: \(runIdentifier)")
        addLog("Started: \(formattedDate(runStartedAt))")
        addLog("App: MP4 Tool \(appVersion) (\(appBuild))")
        addLog("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        addLog("FFmpeg Source: \(isUsingSystemFFmpeg ? "System" : "Bundled")")
        addLog("FFmpeg: \(ffmpegVersion)")
        addLog("FFprobe: \(ffprobeVersion)")
        addLog("FFmpeg Path: \(ffmpegPath)")
        addLog("FFprobe Path: \(ffprobePath)")
        addLog("═══════════════════════════════")
        addLog("Starting processing...")
        if !inputPath.isEmpty {
            addLog("􀈖 Input Directory: \(inputPath)")
        }
        addLog("􀈖 Output Directory: \(outputPath)")
        addLog("􀣋 Mode: \(mode.rawValue)")
        if mode == .smart {
            addLog("Smart Target: \(String(format: "%.0f", smartRemuxMegabytesPerMinute)) MB/min")
            addLog("Smart Fallback: Encode H.265 · CRF \(crfValue) · \(resolution.description) · \(preset.description)")
            addLog("Smart Audio: Copy compatible audio · High-quality AAC fallback")
        } else if mode == .encodeH265 || mode == .encodeH264 {
            addLog("􀈄 Encode Video: \(encodeVideo)")
            addLog("􀀁 Encode Audio: \(encodeAudio)")
            addLog("􀏃 CRF: \(crfValue)")
            addLog("􀠅 Resolution: \(resolution.description)")
            addLog("⚙️ Preset: \(preset.description)")
        }
        addLog("􀈕 Create Subfolders: \(createSubfolders)")
        addLog("􀈕 Automatic Rename: \(automaticRename)")
        addLog("􀈑 Delete Original: \(deleteOriginal)")
        addLog("􀀁 Keep English Audio Only: \(keepEnglishAudioOnly)")
        addLog("􀀁 Keep All English Audio Tracks: \(keepAllEnglishAudioTracks)")
        addLog("􀀃 Keep English Subtitles Only: \(keepEnglishSubtitlesOnly)")
        addLog("􀀃 Keep All English Subtitle Tracks: \(keepAllEnglishSubtitleTracks)")
        addLog("Enable Notifications: \(notificationsEnabled)")
        addLog("Enable Previews: \(framePreviewsEnabled)")

        let activePostProcessScriptPath = validatedPostProcessScriptPath(postProcessScriptPath)
        if let activePostProcessScriptPath {
            addLog("Post-Process Script: \(activePostProcessScriptPath)")
            addLog("Post-Process Script Timing: \(postProcessScriptRunTiming.description)")
            if postProcessScriptRunTiming == .afterEachItem {
                addLog("Post-Process Script Pass File Name First: \(postProcessScriptPassFileNameAsFirstArgument)")
            }
        }

        // Verify output directory exists, recreating it if a previously selected folder was deleted.
        var isOutputDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputPath, isDirectory: &isOutputDirectory) {
            guard isOutputDirectory.boolValue else {
                addLog("Output path exists but is not a folder: \(outputPath)")
                DispatchQueue.main.async { self.isProcessing = false }
                return
            }
        } else {
            do {
                try FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true)
                addLog("Created output directory: \(outputPath)")
            } catch {
                addLog("Failed to create output directory: \(error.localizedDescription)")
                DispatchQueue.main.async { self.isProcessing = false }
                return
            }
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            addLog("Output directory does not exist!")
            DispatchQueue.main.async { self.isProcessing = false }
            return
        }

        let stagingLocation = ProcessingStagingStorage.location(
            outputPath: outputPath,
            preferDestinationVolume: stageTemporaryFilesOnDestinationVolume
        )
        do {
            try ProcessingStagingStorage.prepareDirectory(for: stagingLocation)
        } catch {
            addLog("Failed to prepare staging directory: \(error.localizedDescription)")
            DispatchQueue.main.async { self.isProcessing = false }
            return
        }
        defer {
            ProcessingStagingStorage.removeDirectoryIfEmpty(stagingLocation.directoryURL)
        }

        addLog("Staging Location: \(stagingLocation.directoryURL.path)")
        if let availableBytes = stagingLocation.availableBytes {
            addLog("Scratch Space Available: \(formattedByteCount(availableBytes))")
        }
        if stageTemporaryFilesOnDestinationVolume && !stagingLocation.usesDestinationVolume {
            addLog("Destination-volume staging is unavailable; using system scratch storage.")
        }

        // Use files from queue if available, otherwise scan input directory
        var filesToProcess: [(path: String, name: String)] = []

        if !videoFiles.isEmpty {
            // Process files from the queue
            filesToProcess = videoFiles.map { (path: $0.filePath, name: $0.fileName) }
            addLog("􀐱 Processing \(filesToProcess.count) files from queue")
        } else if !inputPath.isEmpty {
            // Scan input directory
            guard FileManager.default.fileExists(atPath: inputPath) else {
                addLog("􀁡 Input directory does not exist!")
                DispatchQueue.main.async { self.isProcessing = false }
                return
            }

            let videoFormats = ["mkv", "mp4", "avi"]
            let wordsToIgnore = ["sample", "SAMPLE", "Sample", ".DS_Store"]

            do {
                let allFiles = try FileManager.default.contentsOfDirectory(atPath: inputPath)
                let files = allFiles
                    .filter { file in
                        let ext = (file as NSString).pathExtension.lowercased()
                        return videoFormats.contains(ext) && !wordsToIgnore.contains { file.contains($0) }
                    }
                    .sorted()

                filesToProcess = files.map {
                    (path: (inputPath as NSString).appendingPathComponent($0), name: $0)
                }
                addLog("􀐱 Found \(filesToProcess.count) files to process")
            } catch {
                addLog("􀁡 Error scanning directory: \(error.localizedDescription)")
                DispatchQueue.main.async { self.isProcessing = false }
                return
            }
        } else {
            addLog("􀁡 No files to process!")
            DispatchQueue.main.async { self.isProcessing = false }
            return
        }

        DispatchQueue.main.async {
            self.totalFiles = filesToProcess.count
        }

        if mode == .smart {
            addLog("Analyzing Smart queue…")
            smartPreflightItems = await buildSmartPreflight(
                files: filesToProcess,
                targetMegabytesPerMinute: smartRemuxMegabytesPerMinute,
                keepEnglishAudioOnly: keepEnglishAudioOnly,
                keepAllEnglishAudioTracks: keepAllEnglishAudioTracks
            )
            let remuxCount = smartPreflightItems.values.filter { $0.mode == .remux }.count
            let encodeCount = smartPreflightItems.count - remuxCount
            addLog("Smart Queue: \(encodeCount) encode · \(remuxCount) remux")
        } else {
            smartPreflightItems = [:]
        }

        // Set initial dock badge with total files
        updateDockBadge(filesRemaining: filesToProcess.count)

        var completedPostProcessFiles: [CompletedPostProcessFile] = []
        var index = 0
        while index < filesToProcess.count {
            reorderPendingProcessingFiles(&filesToProcess, startingAt: index)
            let fileInfo = filesToProcess[index]

            // Check for cancellation
            if shouldCancelProcessing {
                addLog("􀛶 Processing cancelled by user")
                clearDockBadge()
                break
            }

            // Check if file has been deleted from the queue
            if !videoFiles.contains(where: { $0.filePath == fileInfo.path }) {
                addLog("􀛷 Skipped: \(fileInfo.name) (removed from queue)")
                index += 1
                continue
            }

            // Mark file as processing
            let filePathForProcessing = fileInfo.path
            let currentIndex = index
            let fileStartTime = Date()
            activeHistoryFFmpegCommands = []
            activeFramePreviewInputFile = nil
            stopFramePreviewUpdates(clearPreview: true)
            DispatchQueue.main.async {
                self.currentFileIndex = currentIndex + 1
                self.currentFile = fileInfo.name
                self.activeItemMode = mode
                if let fileIndex = self.videoFiles.firstIndex(where: { $0.filePath == filePathForProcessing }) {
                    var updatedFile = self.videoFiles[fileIndex]
                    updatedFile.status = .processing
                    updatedFile.hasConflict = false
                    updatedFile.conflictReason = ""
                    updatedFile.processingStartTime = fileStartTime
                    updatedFile.processingEndTime = nil
                    self.videoFiles[fileIndex] = updatedFile
                }
            }

            addLog("\n􀎶 File \(index + 1)/\(filesToProcess.count)")
            addLog("⏱ Start time: \(getTimestampString())")
            addLog("􀅴 Processing: \(fileInfo.name)")

            let inputFilePath = fileInfo.path
            activeProcessingFilePath = inputFilePath
            let outputFileName = makeOutputFileName(fromInputFileName: fileInfo.name, automaticRename: automaticRename)

            let sourceDuration: TimeInterval?
            if let preflightItem = smartPreflightItems[inputFilePath] {
                sourceDuration = preflightItem.duration
            } else {
                sourceDuration = await probeDurationSeconds(inputFile: inputFilePath)
            }
            DispatchQueue.main.async {
                self.currentInputDurationSeconds = sourceDuration
                self.currentInputFrameRate = nil
                self.currentEncodedTimeSeconds = 0
                self.latestFFmpegTimestampSeconds = nil
                self.lastFFmpegTimestampAdvanceAt = nil
                self.ffmpegProgressTail = ""
                self.currentFileProgressFraction = 0
            }

            let outputFilePath: String
            if createSubfolders {
                // Keep the directory and output file in sync. When automatic
                // rename resolves a clean title, use that same resolved name for
                // the containing folder instead of the raw source filename.
                let folderName = (outputFileName as NSString).deletingPathExtension
                let outputDir = (outputPath as NSString).appendingPathComponent(folderName)
                outputFilePath = (outputDir as NSString).appendingPathComponent(outputFileName)

                try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
            } else {
                outputFilePath = (outputPath as NSString).appendingPathComponent(outputFileName)
            }

            addLog("Input: \(inputFilePath)")
            addLog("Output: \(outputFilePath)")
            if let sourceDuration {
                addLog("Source Duration: \(formatDuration(seconds: Int(sourceDuration)))")
            }

            let tempOutputFile = ProcessingStagingStorage
                .temporaryOutputURL(in: stagingLocation)
                .path
            let estimatedInputBytes = (try? FileManager.default.attributesOfItem(
                atPath: inputFilePath
            ))?[.size] as? Int64 ?? 0

            // Process the video
            let conversionStartTime = Date()
            let conversionOutcome: ConversionOutcome
            if let storageIssue = ProcessingStagingStorage.capacityIssue(
                estimatedOutputBytes: estimatedInputBytes,
                location: stagingLocation,
                outputPath: outputPath
            ) {
                addLog("Storage check failed before encoding: \(storageIssue)")
                conversionOutcome = .failed(reason: storageIssue)
            } else {
                conversionOutcome = await convertToMP4(
                    inputFile: inputFilePath,
                    tempFile: tempOutputFile,
                    mode: mode,
                    smartRemuxMegabytesPerMinute: smartRemuxMegabytesPerMinute,
                    crfValue: crfValue,
                    resolution: resolution,
                    preset: preset,
                    encodeVideo: encodeVideo,
                    encodeAudio: encodeAudio,
                    keepEnglishAudioOnly: keepEnglishAudioOnly,
                    keepAllEnglishAudioTracks: keepAllEnglishAudioTracks,
                    keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly,
                    keepAllEnglishSubtitleTracks: keepAllEnglishSubtitleTracks,
                    sourceDuration: sourceDuration,
                    smartPreflightMode: smartPreflightItems[inputFilePath]?.mode
                )
            }
            let conversionEndTime = Date()

            if shouldCancelProcessing {
                try? FileManager.default.removeItem(atPath: tempOutputFile)

                let cancelledFilePath = fileInfo.path
                DispatchQueue.main.async {
                    if let fileIndex = self.videoFiles.firstIndex(where: { $0.filePath == cancelledFilePath }) {
                        var updatedFile = self.videoFiles[fileIndex]
                        updatedFile.status = .pending
                        updatedFile.processingStartTime = nil
                        updatedFile.processingEndTime = nil
                        updatedFile.processingTimeSeconds = 0
                        self.videoFiles[fileIndex] = updatedFile
                    }
                }
                break
            }

            if case .success(let effectiveMode) = conversionOutcome {
                // Get file sizes
                let inputSize = (try? FileManager.default.attributesOfItem(atPath: inputFilePath))?[.size] as? Int64 ?? 0
                let outputSize = (try? FileManager.default.attributesOfItem(atPath: tempOutputFile))?[.size] as? Int64 ?? 0

                let outputSizeMB = outputSize / (1024 * 1024)

                // Move to final location (run in background to avoid blocking on network shares)
                addLog("􀐱 Moving file to output location...")
                let moveSuccess = await moveFileAsync(from: tempOutputFile, to: outputFilePath)

                if !moveSuccess {
                    let fileEndTime = Date()
                    failedFileCount += 1
                    addLog("⏱ End time: \(getTimestampString())")
                    addLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    addLog("􀁡 FAILED: Could not move file to output location")
                    addLog("File: \(fileInfo.name)")
                    addLog("Destination: \(outputFilePath)")
                    addLog("Output path may not be writable or disk may be full")
                    addLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    try? FileManager.default.removeItem(atPath: tempOutputFile)

                    // Mark file as failed
                    let failedFilePath = fileInfo.path
                    DispatchQueue.main.async {
                        if let fileIndex = self.videoFiles.firstIndex(where: { $0.filePath == failedFilePath }) {
                            var updatedFile = self.videoFiles[fileIndex]
                            updatedFile.status = .failed
                            updatedFile.processingEndTime = fileEndTime
                            self.videoFiles[fileIndex] = updatedFile
                        }
                        self.processingHadError = true
                    }

                    if stopAfterCurrentFileRequested {
                        addLog("\n􀛶 Current file finished. Stopping before the next queue item.")
                        clearDockBadge()
                        break
                    }

                    index += 1
                    continue
                }

                totalOriginalBytes += inputSize
                totalOutputBytes += outputSize

                // Delete original file if requested (run in background to avoid blocking on network shares)
                if deleteOriginal {
                    let deleteSuccess = await deleteFileAsync(at: inputFilePath)
                    if deleteSuccess {
                        addLog("􀈑 Deleted original file")
                    } else {
                        addLog("􀇾 Warning: Could not delete original file")
                    }
                } else {
                    addLog("􀅴 Kept original file")
                }

                let filesRemaining = filesToProcess.count - (index + 1)
                let completedPostProcessFile = CompletedPostProcessFile(
                    inputPath: inputFilePath,
                    outputPath: outputFilePath,
                    fileName: URL(fileURLWithPath: outputFilePath).lastPathComponent
                )
                completedPostProcessFiles.append(completedPostProcessFile)

                if let activePostProcessScriptPath,
                   postProcessScriptRunTiming == .afterEachItem,
                   !shouldCancelProcessing {
                    let scriptSucceeded = await runPostProcessScriptForItem(
                        scriptPath: activePostProcessScriptPath,
                        completedFile: completedPostProcessFile,
                        mode: effectiveMode,
                        passFileNameAsFirstArgument: postProcessScriptPassFileNameAsFirstArgument
                    )
                    if !scriptSucceeded {
                        DispatchQueue.main.async {
                            self.processingHadError = true
                        }
                    }
                }

                let fileEndTime = Date()
                let duration = fileEndTime.timeIntervalSince(fileStartTime)
                let savedBytes = inputSize - outputSize
                let savedPercentage = inputSize > 0 ? Double(savedBytes) / Double(inputSize) * 100 : 0
                let encodingRuntime = conversionEndTime.timeIntervalSince(conversionStartTime)
                addLog("⏱ End time: \(getTimestampString())")
                addLog("􀁢 Done processing")
                addLog("Final Output: \(outputFilePath)")
                addLog("Size: \(formattedByteCount(inputSize)) → \(formattedByteCount(outputSize))")
                addLog("Space Saved: \(formattedByteCount(savedBytes)) (\(String(format: "%.1f", savedPercentage))%)")
                addLog("Completed in \(formatDuration(seconds: Int(duration)))")
                if effectiveMode != .remux,
                   let sourceDuration,
                   encodingRuntime > 0 {
                    addLog(
                        "Encode Speed: \(String(format: "%.2f", sourceDuration / encodingRuntime))× realtime"
                    )
                }

                let historyWasSaved = ProcessingHistoryStore.shared.record(
                    fileName: URL(fileURLWithPath: outputFilePath).lastPathComponent,
                    originalBytes: inputSize,
                    outputBytes: outputSize,
                    startedAt: fileStartTime,
                    processedAt: fileEndTime,
                    runtimeSeconds: duration,
                    details: ProcessingHistoryDetails(
                        runID: runIdentifier,
                        inputPath: inputFilePath,
                        outputPath: outputFilePath,
                        mode: mode == .smart
                            ? "Smart → \(effectiveMode.description)"
                            : effectiveMode.description,
                        sourceDurationSeconds: sourceDuration,
                        encodingRuntimeSeconds: effectiveMode == .remux ? nil : encodingRuntime,
                        encodeVideo: effectiveMode == .remux ? false : (mode == .smart ? true : encodeVideo),
                        encodeAudio: effectiveMode == .remux ? false : (mode == .smart ? true : encodeAudio),
                        crfValue: effectiveMode == .remux ? nil : crfValue,
                        resolution: effectiveMode == .remux ? nil : resolution.description,
                        encoderPreset: effectiveMode == .remux ? nil : preset.description,
                        createSubfolders: createSubfolders,
                        automaticRename: automaticRename,
                        deleteOriginal: deleteOriginal,
                        keepEnglishAudioOnly: keepEnglishAudioOnly,
                        keepAllEnglishAudioTracks: keepAllEnglishAudioTracks,
                        keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly,
                        keepAllEnglishSubtitleTracks: keepAllEnglishSubtitleTracks,
                        ffmpegSource: isUsingSystemFFmpeg ? "System" : "Bundled",
                        ffmpegVersion: ffmpegVersion,
                        appVersion: appVersion,
                        appBuild: appBuild,
                        ffmpegCommands: activeHistoryFFmpegCommands
                    )
                )
                if !historyWasSaved {
                    addLog("􀇾 Warning: Could not save this file to processing history")
                }

                // Mark the item complete only after the move and any per-file script finish.
                let completedFilePath = fileInfo.path
                DispatchQueue.main.async {
                    if let fileIndex = self.videoFiles.firstIndex(where: { $0.filePath == completedFilePath }) {
                        var updatedFile = self.videoFiles[fileIndex]
                        updatedFile.status = .completed
                        updatedFile.processingEndTime = fileEndTime
                        updatedFile.processingTimeSeconds = Int(duration)
                        updatedFile.newSizeMB = Int(outputSizeMB)
                        self.videoFiles[fileIndex] = updatedFile
                    }
                }

                // Update dock badge with remaining files
                if filesRemaining > 0 {
                    updateDockBadge(filesRemaining: filesRemaining)
                }
            } else if case .skipped(let reason) = conversionOutcome {
                let fileEndTime = conversionEndTime
                skippedFileCount += 1
                addLog("⏱ End time: \(getTimestampString())")
                addLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                addLog("􀇾 SKIPPED: \(fileInfo.name)")
                addLog("Reason: \(reason)")
                addLog("No FFmpeg encode was started.")
                addLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                try? FileManager.default.removeItem(atPath: tempOutputFile)

                let skippedFilePath = fileInfo.path
                DispatchQueue.main.async {
                    if let fileIndex = self.videoFiles.firstIndex(where: { $0.filePath == skippedFilePath }) {
                        var updatedFile = self.videoFiles[fileIndex]
                        updatedFile.status = .skipped
                        updatedFile.processingEndTime = fileEndTime
                        updatedFile.processingTimeSeconds = Int(fileEndTime.timeIntervalSince(fileStartTime))
                        self.videoFiles[fileIndex] = updatedFile
                    }
                }

                let filesRemaining = filesToProcess.count - (index + 1)
                if filesRemaining > 0 {
                    updateDockBadge(filesRemaining: filesRemaining)
                }
            } else if case .failed(let errorReason) = conversionOutcome {
                let fileEndTime = conversionEndTime
                failedFileCount += 1
                addLog("⏱ End time: \(getTimestampString())")
                addLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                addLog("􀁡 FAILED: \(fileInfo.name)")
                addLog("Reason: \(errorReason)")
                addLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                try? FileManager.default.removeItem(atPath: tempOutputFile)

                // Mark file as failed
                let conversionFailedFilePath = fileInfo.path
                DispatchQueue.main.async {
                    if let fileIndex = self.videoFiles.firstIndex(where: { $0.filePath == conversionFailedFilePath }) {
                        var updatedFile = self.videoFiles[fileIndex]
                        updatedFile.status = .failed
                        updatedFile.processingEndTime = fileEndTime
                        self.videoFiles[fileIndex] = updatedFile
                    }
                    self.processingHadError = true
                }
            }

            // A graceful stop finishes every acceptance and cleanup step for the
            // active item, then leaves the remaining queue entries untouched.
            if stopAfterCurrentFileRequested {
                addLog("\n􀛶 Current file finished. Stopping before the next queue item.")
                clearDockBadge()
                break
            }

            // Add on-demand files after the active item finishes. Their visible
            // pending order is applied at the start of the next loop iteration.
            if !pendingBatchFiles.isEmpty {
                addLog("\n􀐱 Processing additional batch...")

                let pendingPaths = Set(pendingBatchFiles.map(\.filePath))
                let additionalFiles = videoFiles.filter {
                    $0.status == .pending && pendingPaths.contains($0.filePath)
                }
                for additionalFile in additionalFiles {
                    if !filesToProcess.contains(where: { $0.path == additionalFile.filePath }) {
                        filesToProcess.append((path: additionalFile.filePath, name: additionalFile.fileName))
                    }
                }
                pendingBatchFiles.removeAll()

                // Update total files count
                DispatchQueue.main.async {
                    self.totalFiles = filesToProcess.count
                }

                // Update dock badge
                updateDockBadge(filesRemaining: filesToProcess.count - (index + 1))
            }

            index += 1
        }

        if let activePostProcessScriptPath,
           postProcessScriptRunTiming == .atEnd,
           !shouldCancelProcessing {
            if completedPostProcessFiles.isEmpty {
                addLog("Post-Process Script skipped: no successful output files")
            } else {
                let scriptSucceeded = await runPostProcessScriptAtEnd(
                    scriptPath: activePostProcessScriptPath,
                    outputPath: outputPath,
                    completedFiles: completedPostProcessFiles,
                    mode: mode
                )
                if !scriptSucceeded {
                    DispatchQueue.main.async {
                        self.processingHadError = true
                    }
                }
            }
        }

        let wasCancelled = shouldCancelProcessing
        let stoppedAfterCurrentFile = stopAfterCurrentFileRequested
        let runEndedAt = Date()
        let summary = ProcessingCompletionSummary(
            mode: mode,
            completedFileCount: completedPostProcessFiles.count,
            skippedFileCount: skippedFileCount,
            failedFileCount: failedFileCount,
            originalBytes: totalOriginalBytes,
            outputBytes: totalOutputBytes,
            startedAt: runStartedAt,
            endedAt: runEndedAt
        )

        if wasCancelled {
            addLog("\nProcessing stopped.")
        } else if stoppedAfterCurrentFile {
            addLog("\nProcessing stopped after the current file.")
        } else {
            addLog("\n􀋚 All files processed!")
        }
        logBatchSummary(summary, cancelled: wasCancelled)

        DispatchQueue.main.async {
            self.isProcessing = false
            self.processingStartedAt = nil
            self.activeMode = nil
            self.activeItemMode = nil
            self.activeProcessingFilePath = nil
            self.smartPreflightItems = [:]
            self.shouldCancelProcessing = false
            self.stopAfterCurrentFileRequested = false
            self.currentInputDurationSeconds = nil
            self.currentInputFrameRate = nil
            self.currentEncodedTimeSeconds = 0
            self.latestFFmpegTimestampSeconds = nil
            self.lastFFmpegTimestampAdvanceAt = nil
            self.estimatedBatchCompletionDate = nil
            self.ffmpegProgressTail = ""
            self.currentFileProgressFraction = 0
            if !wasCancelled {
                self.completionSummary = summary
            }

            if wasCancelled || stoppedAfterCurrentFile || NSApplication.shared.isActive || !self.notificationsEnabled {
                self.clearDockBadge()
            } else {
                self.setDockBadgeCheckmark()
                self.sendProcessingCompleteNotification()
            }
        }
    }

    private func reorderPendingProcessingFiles(
        _ filesToProcess: inout [(path: String, name: String)],
        startingAt index: Int
    ) {
        guard index < filesToProcess.count else { return }

        let completedPrefix = Array(filesToProcess.prefix(index))
        let remainingFiles = Array(filesToProcess.dropFirst(index))
        let remainingByPath = Dictionary(
            uniqueKeysWithValues: remainingFiles.map { ($0.path, $0) }
        )
        let orderedPendingPaths = videoFiles
            .filter { $0.status == .pending }
            .map(\.filePath)

        var includedPaths: Set<String> = []
        var reorderedRemaining: [(path: String, name: String)] = []

        for path in orderedPendingPaths {
            if let file = remainingByPath[path] {
                reorderedRemaining.append(file)
                includedPaths.insert(path)
            }
        }

        // Preserve any entry that is temporarily between UI state updates.
        reorderedRemaining.append(
            contentsOf: remainingFiles.filter { !includedPaths.contains($0.path) }
        )
        filesToProcess = completedPrefix + reorderedRemaining
    }

    private func validatedPostProcessScriptPath(_ scriptPath: String) -> String? {
        let trimmedPath = scriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: trimmedPath, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            addLog("Post-Process Script warning: selected script was not found: \(trimmedPath)")
            DispatchQueue.main.async {
                self.processingHadError = true
            }
            return nil
        }

        return trimmedPath
    }

    private func postProcessScriptLaunchCommand(
        scriptPath: String,
        scriptArguments: [String]
    ) -> (executable: String, arguments: [String]) {
        let scriptExtension = URL(fileURLWithPath: scriptPath).pathExtension.lowercased()

        switch scriptExtension {
        case "sh":
            return ("/bin/sh", [scriptPath] + scriptArguments)
        case "bash":
            return ("/usr/bin/env", ["bash", scriptPath] + scriptArguments)
        case "zsh":
            return ("/bin/zsh", [scriptPath] + scriptArguments)
        case "py":
            return ("/usr/bin/env", ["python3", scriptPath] + scriptArguments)
        default:
            if FileManager.default.isExecutableFile(atPath: scriptPath) {
                return (scriptPath, scriptArguments)
            }
            return ("/bin/zsh", [scriptPath] + scriptArguments)
        }
    }

    private func runPostProcessScriptForItem(
        scriptPath: String,
        completedFile: CompletedPostProcessFile,
        mode: ProcessingMode,
        passFileNameAsFirstArgument: Bool
    ) async -> Bool {
        let outputURL = URL(fileURLWithPath: completedFile.outputPath)
        let outputDirectoryURL = outputURL.deletingLastPathComponent()
        var scriptArguments = [completedFile.inputPath, completedFile.outputPath]
        if passFileNameAsFirstArgument {
            scriptArguments.insert(completedFile.fileName, at: 0)
        }

        return await runPostProcessScript(
            scriptPath: scriptPath,
            phaseLabel: "item",
            scriptArguments: scriptArguments,
            environment: [
                "MP4_TOOL_POST_PROCESS_PHASE": "item",
                "MP4_TOOL_MODE": mode.rawValue,
                "MP4_TOOL_INPUT_FILE": completedFile.inputPath,
                "MP4_TOOL_OUTPUT_FILE": completedFile.outputPath,
                "MP4_TOOL_OUTPUT_DIR": outputDirectoryURL.path,
                "MP4_TOOL_FILE_NAME": completedFile.fileName
            ],
            currentDirectoryURL: outputDirectoryURL
        )
    }

    private func runPostProcessScriptAtEnd(
        scriptPath: String,
        outputPath: String,
        completedFiles: [CompletedPostProcessFile],
        mode: ProcessingMode
    ) async -> Bool {
        let outputFiles = completedFiles.map(\.outputPath)
        let inputFiles = completedFiles.map(\.inputPath)

        return await runPostProcessScript(
            scriptPath: scriptPath,
            phaseLabel: "end",
            scriptArguments: [outputPath] + outputFiles,
            environment: [
                "MP4_TOOL_POST_PROCESS_PHASE": "end",
                "MP4_TOOL_MODE": mode.rawValue,
                "MP4_TOOL_OUTPUT_DIR": outputPath,
                "MP4_TOOL_OUTPUT_FILES": outputFiles.joined(separator: "\n"),
                "MP4_TOOL_INPUT_FILES": inputFiles.joined(separator: "\n"),
                "MP4_TOOL_OUTPUT_COUNT": "\(outputFiles.count)"
            ],
            currentDirectoryURL: URL(fileURLWithPath: outputPath, isDirectory: true)
        )
    }

    private func runPostProcessScript(
        scriptPath: String,
        phaseLabel: String,
        scriptArguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL?
    ) async -> Bool {
        let launchCommand = postProcessScriptLaunchCommand(
            scriptPath: scriptPath,
            scriptArguments: scriptArguments
        )
        let scriptName = URL(fileURLWithPath: scriptPath).lastPathComponent
        addLog("Running post-process script (\(phaseLabel)): \(scriptName)")

        let result: PostProcessScriptResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: PostProcessScriptResult(
                        terminationStatus: nil,
                        outputText: "",
                        errorText: "",
                        startErrorMessage: "Process initialization failed"
                    ))
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchCommand.executable)
                process.arguments = launchCommand.arguments
                process.currentDirectoryURL = currentDirectoryURL

                var processEnvironment = ProcessInfo.processInfo.environment
                processEnvironment["MP4_TOOL_POST_PROCESS_SCRIPT"] = scriptPath
                for (key, value) in environment {
                    processEnvironment[key] = value
                }
                process.environment = processEnvironment

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                let outputBuffer = ThreadSafeDataBuffer()
                let errorBuffer = ThreadSafeDataBuffer()

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    outputBuffer.append(chunk)
                }

                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    errorBuffer.append(chunk)
                }

                DispatchQueue.main.async {
                    self.currentProcess = process
                }

                do {
                    try process.run()
                    process.waitUntilExit()

                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil

                    let remainingOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingOutput.isEmpty {
                        outputBuffer.append(remainingOutput)
                    }

                    let remainingError = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingError.isEmpty {
                        errorBuffer.append(remainingError)
                    }

                    let outputText = String(data: outputBuffer.snapshot(), encoding: .utf8) ?? ""
                    let errorText = String(data: errorBuffer.snapshot(), encoding: .utf8) ?? ""
                    let terminationStatus = process.terminationStatus

                    DispatchQueue.main.async {
                        if self.currentProcess === process {
                            self.currentProcess = nil
                        }
                    }

                    continuation.resume(returning: PostProcessScriptResult(
                        terminationStatus: terminationStatus,
                        outputText: outputText,
                        errorText: errorText,
                        startErrorMessage: nil
                    ))
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil

                    let outputText = String(data: outputBuffer.snapshot(), encoding: .utf8) ?? ""
                    let errorText = String(data: errorBuffer.snapshot(), encoding: .utf8) ?? ""
                    let errorMessage = error.localizedDescription

                    DispatchQueue.main.async {
                        if self.currentProcess === process {
                            self.currentProcess = nil
                        }
                    }

                    continuation.resume(returning: PostProcessScriptResult(
                        terminationStatus: nil,
                        outputText: outputText,
                        errorText: errorText,
                        startErrorMessage: errorMessage
                    ))
                }
            }
        }

        if !result.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logPostProcessScriptOutput(result.outputText, label: "stdout")
        }

        if !result.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logPostProcessScriptOutput(result.errorText, label: "stderr")
        }

        if let startErrorMessage = result.startErrorMessage {
            addLog("Post-Process Script warning: failed to start: \(startErrorMessage)")
            return false
        }

        guard let terminationStatus = result.terminationStatus else {
            addLog("Post-Process Script warning: process did not return a status")
            return false
        }

        if terminationStatus == 0 {
            addLog("Post-process script completed")
            return true
        } else if shouldCancelProcessing {
            addLog("Post-process script cancelled")
            return false
        } else {
            addLog("Post-Process Script warning: exited with code \(terminationStatus)")
            return false
        }
    }

    private func logPostProcessScriptOutput(_ output: String, label: String) {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return }

        addLog("Post-process script \(label):")
        for line in lines.prefix(100) {
            addLog("  \(line)")
        }
        if lines.count > 100 {
            addLog("  ... \(lines.count - 100) more lines")
        }
    }

    private func buildSmartPreflight(
        files: [(path: String, name: String)],
        targetMegabytesPerMinute: Double,
        keepEnglishAudioOnly: Bool,
        keepAllEnglishAudioTracks: Bool
    ) async -> [String: SmartPreflightItem] {
        var results: [String: SmartPreflightItem] = [:]

        for (offset, file) in files.enumerated() {
            guard !shouldCancelProcessing else { break }

            DispatchQueue.main.async {
                self.scanProgress = "Analyzing \(offset + 1) of \(files.count)…"
            }

            let inputBytes = (try? FileManager.default.attributesOfItem(
                atPath: file.path
            ))?[.size] as? Int64 ?? 0
            let duration = await probeDurationSeconds(inputFile: file.path)
            var resolvedMode: ProcessingMode = .encodeH265

            if let duration, duration > 0, inputBytes > 0 {
                let megabytesPerMinute = Double(inputBytes) / 1_000_000 / (duration / 60)
                if megabytesPerMinute <= targetMegabytesPerMinute,
                   let audioStreams = await probeStreams(inputFile: file.path, selectStreams: "a"),
                   let videoStreams = await probeStreams(inputFile: file.path, selectStreams: nil) {
                    let audioMappings = getAudioMappings(
                        audioStreams: audioStreams,
                        keepEnglishOnly: keepEnglishAudioOnly,
                        keepAllEnglishTracks: keepAllEnglishAudioTracks
                    )
                    let compatibilityIssue = await remuxCompatibilityIssue(
                        inputFile: file.path,
                        videoCodec: getVideoCodec(videoStreams: videoStreams),
                        audioStreams: audioStreams,
                        selectedAudioStreamIndexes: Set(audioMappings.map(\.index))
                    )
                    resolvedMode = compatibilityIssue == nil ? .remux : .encodeH265
                }
            }

            results[file.path] = SmartPreflightItem(
                mode: resolvedMode,
                duration: duration,
                inputBytes: inputBytes
            )
        }

        DispatchQueue.main.async {
            self.scanProgress = ""
        }
        return results
    }

    private func convertToMP4(
        inputFile: String,
        tempFile: String,
        mode: ProcessingMode,
        smartRemuxMegabytesPerMinute: Double,
        crfValue: Int = 23,
        resolution: ResolutionOption = .default,
        preset: PresetOption = .fast,
        encodeVideo: Bool = true,
        encodeAudio: Bool = true,
        keepEnglishAudioOnly: Bool,
        keepAllEnglishAudioTracks: Bool,
        keepEnglishSubtitlesOnly: Bool,
        keepAllEnglishSubtitleTracks: Bool,
        sourceDuration: TimeInterval?,
        smartPreflightMode: ProcessingMode? = nil
    ) async -> ConversionOutcome {
        // Probe streams
        guard let audioStreams = await probeStreams(inputFile: inputFile, selectStreams: "a"),
              let videoStreams = await probeStreams(inputFile: inputFile, selectStreams: nil),
              let subtitleStreams = await probeStreams(inputFile: inputFile, selectStreams: "s") else {
            addLog("􀁡 Failed to probe streams (ffprobe couldn't analyze the file)")
            return .failed(reason: "Failed to probe streams")
        }

        let shouldEncodeVideo = mode == .smart ? true : encodeVideo
        let shouldEncodeAudio = mode == .smart ? true : encodeAudio

        // Determine audio stream mappings
        let audioMappings = getAudioMappings(
            audioStreams: audioStreams,
            keepEnglishOnly: keepEnglishAudioOnly,
            keepAllEnglishTracks: keepAllEnglishAudioTracks
        )
        if keepEnglishAudioOnly, shouldEncodeAudio, audioMappings.isEmpty {
            let reason = audioStreams.streams.isEmpty
                ? "No audio tracks were found"
                : "No English or undefined-language audio tracks were found"
            addLog("􀇾 \(reason). Skipping before encode.")
            return .skipped(reason: reason)
        }

        if audioMappings.isEmpty {
            addLog("􀇾 No audio tracks found. Processing as video-only file.")
        }

        // Get video codec
        let videoCodec = getVideoCodec(videoStreams: videoStreams)

        // Get video dimensions
        let videoDimensions = getVideoDimensions(videoStreams: videoStreams)

        // FFmpeg's mux-level out_time can be unavailable or stale for some files.
        // Retain the source frame rate so frame= can provide a progress fallback.
        let videoFrameRate = getVideoFrameRate(videoStreams: videoStreams)
        await MainActor.run {
            self.currentInputFrameRate = videoFrameRate
        }

        let videoDescription: String = {
            var components = [videoCodec?.uppercased() ?? "Unknown codec"]
            if let videoDimensions {
                components.append("\(videoDimensions.width)×\(videoDimensions.height)")
            }
            if let videoFrameRate {
                components.append("\(String(format: "%.3f", videoFrameRate)) fps")
            }
            return components.joined(separator: " · ")
        }()
        addLog("Source Video: \(videoDescription)")
        if audioMappings.isEmpty {
            addLog("Selected Audio: none")
        } else {
            let descriptions = audioMappings.map { mapping in
                let language = mapping.language ?? "und"
                let layout = mapping.channelLayout ?? "unknown layout"
                return "0:\(mapping.index) (\(language) · \(layout))"
            }
            addLog("Selected Audio: \(descriptions.joined(separator: ", "))")
        }

        var effectiveMode = mode
        if mode == .smart {
            let inputBytes = (try? FileManager.default.attributesOfItem(
                atPath: inputFile
            ))?[.size] as? Int64 ?? 0

            if let sourceDuration, sourceDuration > 0, inputBytes > 0 {
                let durationMinutes = sourceDuration / 60
                let megabytesPerMinute = Double(inputBytes) / 1_000_000 / durationMinutes
                addLog(
                    "Smart Analysis: \(String(format: "%.1f", megabytesPerMinute)) MB/min "
                    + "(target ≤ \(String(format: "%.0f", smartRemuxMegabytesPerMinute)) MB/min)"
                )
                effectiveMode = smartPreflightMode
                    ?? (megabytesPerMinute <= smartRemuxMegabytesPerMinute ? .remux : .encodeH265)
            } else {
                addLog("Smart Analysis: File size or runtime is unavailable")
                effectiveMode = smartPreflightMode ?? .encodeH265
            }

            if smartPreflightMode == nil,
               effectiveMode == .remux,
               let compatibilityIssue = await remuxCompatibilityIssue(
                inputFile: inputFile,
                videoCodec: videoCodec,
                audioStreams: audioStreams,
                selectedAudioStreamIndexes: Set(audioMappings.map(\.index))
               ) {
                addLog("Smart Remux unavailable: \(compatibilityIssue)")
                effectiveMode = .encodeH265
            }

            addLog(
                effectiveMode == .remux
                    ? "Smart Decision: Remux"
                    : "Smart Decision: Encode H.265"
            )
        } else if mode == .remux,
                  let compatibilityIssue = await remuxCompatibilityIssue(
                    inputFile: inputFile,
                    videoCodec: videoCodec,
                    audioStreams: audioStreams,
                    selectedAudioStreamIndexes: Set(audioMappings.map(\.index))
                  ) {
            addLog("􀁡 \(compatibilityIssue). Please use encode mode.")
            return .failed(reason: "\(compatibilityIssue) - use encode mode instead")
        }

        await MainActor.run {
            self.activeItemMode = effectiveMode
        }

        for (outputIndex, mapping) in audioMappings.enumerated() {
            let sourceCodec = normalizedProbeValue(mapping.codecName).uppercased()
            if shouldCopyAudio(mapping, mode: effectiveMode, encodeAudio: shouldEncodeAudio) {
                addLog("Audio Track \(outputIndex + 1): \(sourceCodec.isEmpty ? "Unknown" : sourceCodec) copied without re-encoding")
            } else {
                addLog("Audio Track \(outputIndex + 1): \(sourceCodec.isEmpty ? "Unknown" : sourceCodec) → AAC \(aacBitrate(for: mapping))")
            }
        }
        let expectedEncodedAudioLayouts = audioMappings.map { mapping in
            shouldCopyAudio(mapping, mode: effectiveMode, encodeAudio: shouldEncodeAudio)
                ? nil
                : mapping.channelLayout
        }

        // Determine subtitle stream mappings
        let embeddedSubtitleMappings = await getSubtitleMappings(
            inputFile: inputFile,
            subtitleStreams: subtitleStreams,
            keepEnglishOnly: keepEnglishSubtitlesOnly,
            keepAllEnglishTracks: keepAllEnglishSubtitleTracks
        )

        // A usable embedded subtitle is authoritative. Only look beside the
        // video when no embedded track can be written to MP4 under the selected
        // language policy. This also gives image-only PGS sources a text-based
        // fallback without letting a loose sidecar replace embedded SRT/ASS.
        let subtitlePlan: SubtitleSelectionPlan
        if !embeddedSubtitleMappings.isEmpty {
            subtitlePlan = SubtitleSelectionPlan(
                sourceFile: inputFile,
                mappings: embeddedSubtitleMappings,
                isExternal: false
            )
        } else if let siblingSubtitle = siblingSRTSelection(for: inputFile) {
            subtitlePlan = siblingSubtitle
            addLog("Selected sibling subtitle: \(URL(fileURLWithPath: siblingSubtitle.sourceFile).lastPathComponent)")
        } else {
            subtitlePlan = SubtitleSelectionPlan(
                sourceFile: inputFile,
                mappings: [],
                isExternal: false
            )
        }
        let subtitleMappings = subtitlePlan.mappings

        if subtitleMappings.isEmpty,
           keepEnglishSubtitlesOnly,
           !subtitleStreams.streams.isEmpty {
            addLog("􀇾 No English/undefined subtitles found. Processing without subtitles.")
        }
        if subtitleMappings.isEmpty {
            addLog("Selected Subtitles: none")
        } else {
            let descriptions = subtitleMappings.map { subtitle in
                var traits: [String] = []
                if subtitle.isDefault { traits.append("default") }
                if subtitle.isForced { traits.append("forced") }
                if subtitle.isHearingImpaired { traits.append("hearing impaired") }
                if subtitle.isCaptions { traits.append("captions") }
                let traitDescription = traits.isEmpty ? "" : " · \(traits.joined(separator: ", "))"
                let source = subtitlePlan.isExternal ? "sidecar" : "0:\(subtitle.index)"
                return "\(source) (\(subtitle.language ?? "und")\(traitDescription))"
            }
            addLog("Selected Subtitles: \(descriptions.joined(separator: ", "))")
            if let rationale = subtitleMappings.compactMap(\.selectionRationale).first {
                addLog("Subtitle Selection: \(rationale)")
            }
        }

        // FFmpeg 9 can let sparse subtitle streams run far ahead of a slow video
        // encode. On affected Matroska files it may then report progress=end and
        // exit 0 while the encoded video is still incomplete. Keep subtitles out
        // of the expensive encode and add them afterward with a fast stream-copy
        // remux. The final validation still protects the source/output duration.
        let usesSeparateSubtitleMux = !subtitleMappings.isEmpty
            && (effectiveMode != .remux || subtitlePlan.isExternal)
        let encodedAVFile: String? = usesSeparateSubtitleMux
            ? (tempFile as NSString).deletingPathExtension + "-av.mp4"
            : nil
        let primaryOutputFile = encodedAVFile ?? tempFile

        if let encodedAVFile {
            try? FileManager.default.removeItem(atPath: encodedAVFile)
        }
        defer {
            if let encodedAVFile {
                try? FileManager.default.removeItem(atPath: encodedAVFile)
            }
        }

        // Build the primary ffmpeg command. For affected encode workflows this
        // produces a complete video/audio MP4 before subtitles are introduced.
        let cmd = buildFFmpegCommand(
            inputFile: inputFile,
            tempFile: primaryOutputFile,
            mode: effectiveMode,
            crfValue: crfValue,
            resolution: resolution,
            preset: preset,
            encodeVideo: shouldEncodeVideo,
            encodeAudio: shouldEncodeAudio,
            videoCodec: videoCodec,
            videoWidth: videoDimensions?.width,
            videoHeight: videoDimensions?.height,
            audioMappings: audioMappings,
            subtitleMappings: usesSeparateSubtitleMux ? [] : subtitleMappings
        )

        // Log the ffmpeg command being run
        addLog("􀅴 Running in \(effectiveMode.rawValue) mode")
        if usesSeparateSubtitleMux {
            addLog("􀅴 Encoding video and audio first; subtitles will be added in a separate remux")
        }
        addLog("􀅴 FFmpeg command:")
        let commandString = shellCommand(executable: ffmpegPath, arguments: cmd)
        addLog("  \(commandString)")
        if effectiveMode == .encodeH265 || effectiveMode == .encodeH264 {
            addLog("􀐱 Encoding started - this may take a while...")
            activeFramePreviewInputFile = inputFile
            if framePreviewsEnabled {
                startFramePreviewUpdates(inputFile: inputFile)
            }
        } else {
            activeFramePreviewInputFile = nil
            stopFramePreviewUpdates(clearPreview: true)
        }

        // Start timer and file size monitoring
        DispatchQueue.main.async { [self] in
            self.startTime = Date()
            self.originalSize = (try? FileManager.default.attributesOfItem(atPath: inputFile)[.size] as? Int64) ?? 0
            self.newSize = 0

            // Monitor file size every 0.5 seconds
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    if let start = self.startTime {
                        self.elapsedTime = Date().timeIntervalSince(start)
                    }
                    // Update output file size
                    if let size = try? FileManager.default.attributesOfItem(atPath: primaryOutputFile)[.size] as? Int64 {
                        self.newSize = size
                    }
                }
            }
        }

        // Run ffmpeg (now async, won't block)
        let (success, ffmpegError) = await runCommand(arguments: cmd)
        stopFramePreviewUpdates(clearPreview: false)
        activeFramePreviewInputFile = nil

        // Stop timer
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
        }

        guard success else {
            return .failed(reason: ffmpegError)
        }

        guard !shouldCancelProcessing else {
            return .failed(reason: "Cancelled by user")
        }

        // A long video encode can occasionally leave one AAC stream incomplete
        // even though FFmpeg exits successfully and the other streams finish.
        // Re-encode only the affected audio from the source, while stream-copying
        // the already completed video and healthy audio tracks.
        if shouldEncodeAudio, effectiveMode != .remux {
            let mismatchedAudioIndexes = await audioTrackDurationMismatchIndexes(
                outputFile: primaryOutputFile,
                audioMappings: audioMappings
            )
            if !mismatchedAudioIndexes.isEmpty {
                let trackNumbers = mismatchedAudioIndexes.map { String($0 + 1) }.joined(separator: ", ")
                addLog("􀇾 Audio track duration mismatch detected in track(s) \(trackNumbers). Rebuilding affected audio...")
                let repaired = await rebuildMismatchedAudioTracks(
                    outputFile: primaryOutputFile,
                    sourceFile: inputFile,
                    audioMappings: audioMappings,
                    mismatchedIndexes: Set(mismatchedAudioIndexes),
                    outputVideoCodec: effectiveMode == .encodeH265 ? "hevc" : videoCodec
                )
                guard repaired else {
                    return .failed(reason: "Could not rebuild incomplete audio track(s)")
                }

                let remainingMismatches = await audioTrackDurationMismatchIndexes(
                    outputFile: primaryOutputFile,
                    audioMappings: audioMappings
                )
                guard remainingMismatches.isEmpty else {
                    let remainingTracks = remainingMismatches.map { String($0 + 1) }.joined(separator: ", ")
                    return .failed(reason: "Rebuilt audio track(s) \(remainingTracks) are still incomplete")
                }
                addLog("􀁢 Rebuilt audio passed duration validation")
            }
        }

        if usesSeparateSubtitleMux {
            addLog("􀐱 Validating encoded video and audio before adding subtitles...")
            if let validationFailure = await outputValidationFailure(
                outputFile: primaryOutputFile,
                expectedAudioTrackCount: audioMappings.count,
                expectedAudioLayouts: expectedEncodedAudioLayouts,
                expectedAudioDurations: audioMappings.map(\.duration),
                sourceDuration: sourceDuration
            ) {
                addLog("􀁡 Intermediate output validation failed: \(validationFailure)")
                return .failed(reason: "Encoded video/audio validation failed: \(validationFailure)")
            }

            guard let encodedAVFile else {
                return .failed(reason: "Could not prepare subtitle remux")
            }

            let subtitleMuxCommand = buildSubtitleMuxCommand(
                encodedAVFile: encodedAVFile,
                sourceFile: subtitlePlan.sourceFile,
                outputFile: tempFile,
                videoCodec: effectiveMode == .encodeH265 ? "hevc" : videoCodec,
                audioMappings: audioMappings,
                subtitleMappings: subtitleMappings
            )
            addLog("􀐱 Adding \(subtitleMappings.count) subtitle track(s)...")
            addLog("􀅴 Subtitle remux command:")
            addLog("  \(shellCommand(executable: ffmpegPath, arguments: subtitleMuxCommand))")

            let (muxSucceeded, muxError) = await runCommand(arguments: subtitleMuxCommand)
            guard muxSucceeded else {
                return .failed(reason: "Subtitle remux failed: \(muxError)")
            }
            guard !shouldCancelProcessing else {
                return .failed(reason: "Cancelled by user")
            }
        }

        addLog("􀐱 Validating temporary output...")
        if let validationFailure = await outputValidationFailure(
            outputFile: tempFile,
            expectedAudioTrackCount: audioMappings.count,
            expectedAudioLayouts: expectedEncodedAudioLayouts,
            expectedAudioDurations: audioMappings.map(\.duration),
            sourceDuration: sourceDuration
        ) {
            addLog("􀁡 Output validation failed: \(validationFailure)")
            return .failed(reason: "Output validation failed: \(validationFailure)")
        }

        addLog("􀁢 Output validation passed")
        return .success(mode: effectiveMode)
    }

    private func probeStreams(inputFile: String, selectStreams: String?) async -> FFProbeOutput? {
        var arguments = ["-v", "error", "-show_streams", "-print_format", "json"]

        if let streams = selectStreams {
            arguments.append(contentsOf: ["-select_streams", streams])
        }

        arguments.append(inputFile)

        guard let output = await runCommandWithOutput(path: ffprobePath, arguments: arguments) else {
            addLog("􀁡 Failed to probe streams")
            return nil
        }

        guard let data = output.data(using: .utf8),
              let result = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else {
            addLog("􀁡 Failed to parse stream data")
            return nil
        }

        return result
    }

    private func probeDurationSeconds(inputFile: String) async -> TimeInterval? {
        let arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            inputFile
        ]

        guard let output = await runCommandWithOutput(path: ffprobePath, arguments: arguments) else {
            return nil
        }

        let value = output
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let value, let seconds = Double(value), seconds > 0 else {
            return nil
        }

        return seconds
    }

    private func audioTrackDurationMismatchIndexes(
        outputFile: String,
        audioMappings: [AudioMapping]
    ) async -> [Int] {
        guard let output = await probeStreams(inputFile: outputFile, selectStreams: "a") else {
            return Array(audioMappings.indices)
        }

        return audioMappings.indices.filter { index in
            guard index < output.streams.count,
                  let expectedDuration = audioMappings[index].duration,
                  let actualDuration = streamDurationSeconds(output.streams[index]) else {
                return index >= output.streams.count
            }
            let tolerance = max(2, min(10, expectedDuration * 0.001))
            return abs(expectedDuration - actualDuration) > tolerance
        }
    }

    private func rebuildMismatchedAudioTracks(
        outputFile: String,
        sourceFile: String,
        audioMappings: [AudioMapping],
        mismatchedIndexes: Set<Int>,
        outputVideoCodec: String?
    ) async -> Bool {
        let outputURL = URL(fileURLWithPath: outputFile)
        let repairURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension("audio-repair-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: repairURL)
        defer { try? FileManager.default.removeItem(at: repairURL) }

        var arguments = [
            "-nostdin",
            "-i", outputFile,
            "-i", sourceFile,
            "-y",
            "-map", "0:v:0",
            "-c:v", "copy"
        ]

        if outputVideoCodec == "hevc" {
            arguments.append(contentsOf: ["-tag:v", "hvc1"])
        }
        arguments.append(contentsOf: ["-metadata:s:v:0", "title="])
        arguments.append(contentsOf: ["-metadata:s:v:0", "handler_name="])

        for (outputIndex, mapping) in audioMappings.enumerated() {
            if mismatchedIndexes.contains(outputIndex) {
                arguments.append(contentsOf: ["-map", "1:\(mapping.index)"])
                if isAppleCompatibleAudioCodec(normalizedProbeValue(mapping.codecName)),
                   !audioRequiresLayoutNormalization(mapping) {
                    arguments.append(contentsOf: ["-c:a:\(outputIndex)", "copy"])
                } else {
                    arguments.append(contentsOf: ["-c:a:\(outputIndex)", "aac"])
                    if let channelLayout = mapping.channelLayout {
                        arguments.append(contentsOf: [
                            "-channel_layout:a:\(outputIndex)", channelLayout
                        ])
                    }
                    arguments.append(contentsOf: [
                        "-b:a:\(outputIndex)", aacBitrate(for: mapping)
                    ])
                }
            } else {
                arguments.append(contentsOf: ["-map", "0:a:\(outputIndex)"])
                arguments.append(contentsOf: ["-c:a:\(outputIndex)", "copy"])
            }

            if let language = mapping.language {
                arguments.append(contentsOf: [
                    "-metadata:s:a:\(outputIndex)", "language=\(language)"
                ])
            }
            arguments.append(contentsOf: ["-metadata:s:a:\(outputIndex)", "title="])
            arguments.append(contentsOf: ["-metadata:s:a:\(outputIndex)", "handler_name="])
            arguments.append(contentsOf: [
                "-disposition:a:\(outputIndex)", outputIndex == 0 ? "default" : "0"
            ])
        }

        // This normally runs before subtitles are added, but preserving any
        // already-present subtitle streams keeps the recovery path safe to reuse.
        arguments.append(contentsOf: ["-map", "0:s?", "-c:s", "copy"])
        arguments.append(contentsOf: [
            "-map_metadata", "-1",
            // Source chapter metadata can make FFmpeg synthesize hidden text/data
            // tracks that AVPlayer rejects. Final MP4s intentionally contain only
            // the explicitly mapped video, audio, and subtitle streams.
            "-map_chapters", "-1",
            "-movflags", "+faststart",
            "-loglevel", "error",
            "-nostats",
            "-progress", "pipe:2",
            repairURL.path
        ])

        addLog("􀅴 Audio recovery command:")
        addLog("  \(shellCommand(executable: ffmpegPath, arguments: arguments))")
        let result = await runCommand(arguments: arguments)
        guard result.success else {
            addLog("􀁡 Audio recovery failed: \(result.errorMessage)")
            return false
        }

        do {
            try FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: repairURL, to: outputURL)
            return true
        } catch {
            addLog("􀁡 Could not install rebuilt audio: \(error.localizedDescription)")
            return false
        }
    }

    private func outputValidationFailure(
        outputFile: String,
        expectedAudioTrackCount: Int,
        expectedAudioLayouts: [String?],
        expectedAudioDurations: [TimeInterval?],
        sourceDuration: TimeInterval?
    ) async -> String? {
        guard FileManager.default.fileExists(atPath: outputFile) else {
            return "temporary output is missing"
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputFile),
              let outputSize = attributes[.size] as? Int64,
              outputSize >= 1_024 else {
            return "temporary output is empty or obviously truncated"
        }

        guard let outputStreams = await probeStreams(inputFile: outputFile, selectStreams: nil) else {
            return "FFprobe could not read the temporary output"
        }

        let videoTrackCount = outputStreams.streams.filter { $0.codecType == "video" }.count
        guard videoTrackCount > 0 else {
            return "temporary output contains no video stream"
        }

        let auxiliaryTrackCount = outputStreams.streams.filter { $0.codecType == "data" }.count
        guard auxiliaryTrackCount == 0 else {
            return "temporary output contains \(auxiliaryTrackCount) unsupported auxiliary data track(s)"
        }

        let outputAudioStreams = outputStreams.streams.filter { $0.codecType == "audio" }
        let actualAudioTrackCount = outputAudioStreams.count
        guard actualAudioTrackCount == expectedAudioTrackCount else {
            return "expected \(expectedAudioTrackCount) audio track(s), found \(actualAudioTrackCount)"
        }

        for (audioIndex, expectedLayout) in expectedAudioLayouts.enumerated() {
            guard let expectedLayout, audioIndex < outputAudioStreams.count else { continue }
            let actualLayout = outputAudioStreams[audioIndex].channelLayout ?? ""
            guard normalizedProbeValue(actualLayout) == normalizedProbeValue(expectedLayout) else {
                return "audio track \(audioIndex + 1) is missing its expected \(expectedLayout) channel layout"
            }
        }

        for (audioIndex, expectedDuration) in expectedAudioDurations.enumerated() {
            guard let expectedDuration,
                  audioIndex < outputAudioStreams.count,
                  let actualDuration = streamDurationSeconds(outputAudioStreams[audioIndex]) else {
                continue
            }
            let tolerance = max(2, min(10, expectedDuration * 0.001))
            guard abs(expectedDuration - actualDuration) <= tolerance else {
                return String(
                    format: "audio track %d duration mismatch: expected %.2fs, output %.2fs",
                    audioIndex + 1,
                    expectedDuration,
                    actualDuration
                )
            }
        }

        let outputAsset = AVURLAsset(url: URL(fileURLWithPath: outputFile))
        let appleAudioTracks = (try? await outputAsset.loadTracks(withMediaType: .audio)) ?? []
        guard appleAudioTracks.count == expectedAudioTrackCount else {
            return "Apple media frameworks could not read all encoded audio tracks"
        }
        guard (try? await outputAsset.load(.isPlayable)) == true else {
            return "temporary output is not playable by Apple media frameworks"
        }

        guard let outputDuration = await probeDurationSeconds(inputFile: outputFile) else {
            return "temporary output has no readable duration"
        }

        if let sourceDuration {
            let tolerance = max(5, min(30, sourceDuration * 0.005))
            let difference = abs(sourceDuration - outputDuration)
            guard difference <= tolerance else {
                return String(
                    format: "duration mismatch: source %.2fs, output %.2fs",
                    sourceDuration,
                    outputDuration
                )
            }
        }

        addLog(
            "Validated Output: \(formattedByteCount(outputSize)) · "
            + "\(videoTrackCount) video · "
            + "\(actualAudioTrackCount) audio · no auxiliary data · "
            + "\(formatDuration(seconds: Int(outputDuration)))"
        )
        return nil
    }

    private func getAudioMappings(
        audioStreams: FFProbeOutput,
        keepEnglishOnly: Bool,
        keepAllEnglishTracks: Bool
    ) -> [AudioMapping] {
        let streams = audioStreams.streams
        let candidates = streams.enumerated().map { audioIndex, stream in
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
                duration: streamDurationSeconds(stream),
                isDefault: stream.disposition?.isDefault == 1,
                isCommentary: stream.disposition?.isCommentary == 1,
                isVisualImpaired: stream.disposition?.isVisualImpaired == 1,
                isDub: stream.disposition?.isDub == 1
            )
        }
        let selectedIndexes = Set(
            AudioTrackSelectionPolicy.selectedCandidates(
                from: candidates,
                keepEnglishOnly: keepEnglishOnly,
                keepAllEnglishTracks: keepAllEnglishTracks
            ).map(\.streamIndex)
        )

        return streams.compactMap { stream in
            guard selectedIndexes.contains(stream.index) else { return nil }
            let language = stream.tags?["language"]?.lowercased()
                ?? (keepEnglishOnly ? "und" : nil)
            return AudioMapping(
                index: stream.index,
                codecName: stream.codecName,
                language: language,
                channels: stream.channels,
                sourceChannelLayout: stream.channelLayout,
                channelLayout: resolvedAudioChannelLayout(for: stream),
                duration: streamDurationSeconds(stream)
            )
        }
    }

    private func streamDurationSeconds(_ stream: VideoStream) -> TimeInterval? {
        if let value = stream.duration,
           let seconds = TimeInterval(value),
           seconds > 0 {
            return seconds
        }

        guard let taggedDuration = stream.tags?["DURATION"]
                ?? stream.tags?["duration"] else {
            return nil
        }

        let components = taggedDuration.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              let hours = TimeInterval(components[0]),
              let minutes = TimeInterval(components[1]),
              let seconds = TimeInterval(components[2]) else {
            return nil
        }
        let total = (hours * 3_600) + (minutes * 60) + seconds
        return total > 0 ? total : nil
    }

    private func resolvedAudioChannelLayout(for stream: VideoStream) -> String? {
        // Use canonical MPEG layouts for AAC-in-MP4. Passing 5.1(side) makes
        // FFmpeg use a PCE, which some FFmpeg 8.x MP4 outputs and Apple players
        // fail to expose as a readable channel layout.
        switch stream.channels {
        case 1: return "mono"
        case 2: return "stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default:
            guard let channelLayout = stream.channelLayout, !channelLayout.isEmpty else {
                return nil
            }
            return channelLayout
        }
    }

    private func aacBitrate(for mapping: AudioMapping) -> String {
        switch mapping.channels ?? 0 {
        case 1: return "128k"
        case 2: return "256k"
        case 3...4: return "384k"
        case 5...6: return "512k"
        case 7...8: return "768k"
        default: return "256k"
        }
    }

    private func shouldCopyAudio(
        _ mapping: AudioMapping,
        mode: ProcessingMode,
        encodeAudio: Bool
    ) -> Bool {
        // AAC stores its channel arrangement in-band. Copying ambiguous
        // multichannel AAC into MP4 can produce a valid-looking file whose
        // audio track AVFoundation does not expose at all. Safety takes
        // precedence over the copy-audio preference for these tracks.
        if audioRequiresLayoutNormalization(mapping) {
            return false
        }

        return mode == .remux
            || !encodeAudio
            || isAppleCompatibleAudioCodec(normalizedProbeValue(mapping.codecName))
    }

    private func audioRequiresLayoutNormalization(_ mapping: AudioMapping) -> Bool {
        guard normalizedProbeValue(mapping.codecName) == "aac",
              let channels = mapping.channels,
              channels > 2 else {
            return false
        }

        return !isCanonicalAppleAACLayout(
            mapping.sourceChannelLayout,
            channels: channels
        )
    }

    private func audioRequiresLayoutNormalization(_ stream: VideoStream) -> Bool {
        guard normalizedProbeValue(stream.codecName) == "aac",
              let channels = stream.channels,
              channels > 2 else {
            return false
        }

        return !isCanonicalAppleAACLayout(stream.channelLayout, channels: channels)
    }

    private func isCanonicalAppleAACLayout(_ layout: String?, channels: Int) -> Bool {
        let normalizedLayout = normalizedProbeValue(layout)
        guard !normalizedLayout.isEmpty, normalizedLayout != "unknown" else {
            return false
        }

        switch channels {
        case 6:
            return normalizedLayout == "5.1"
        case 8:
            return normalizedLayout == "7.1"
        default:
            // Named 3-, 4-, 5-, and 7-channel layouts can be represented by
            // AAC without guessing. Only reject a layout that is absent.
            return true
        }
    }

    private func remuxCompatibilityIssue(
        inputFile: String,
        videoCodec: String?,
        audioStreams: FFProbeOutput,
        selectedAudioStreamIndexes: Set<Int>
    ) async -> String? {
        let normalizedVideoCodec = normalizedProbeValue(videoCodec)
        if !normalizedVideoCodec.isEmpty,
           !isAppleCompatibleVideoCodec(normalizedVideoCodec) {
            return "Unsupported video codec \(normalizedVideoCodec) detected. Remux requires re-encoding"
        }

        let filteredStreams = audioStreams.streams.filter {
            selectedAudioStreamIndexes.contains($0.index)
        }

        if filteredStreams.contains(where: { isDtsAudioCodec($0.codecName) }) {
            return "DTS audio detected. Remux requires re-encoding"
        }

        if filteredStreams.contains(where: isFloatingPointPCMAudio) {
            return "PCM float audio detected. Remux requires re-encoding"
        }

        if filteredStreams.contains(where: audioRequiresLayoutNormalization) {
            return "Ambiguous multichannel AAC layout detected. Remux requires audio normalization"
        }

        if let unsupportedCodec = filteredStreams
            .compactMap({ normalizedProbeValue($0.codecName) })
            .first(where: { !isAppleCompatibleAudioCodec($0) }) {
            return "Unsupported audio codec \(unsupportedCodec) detected. Remux requires re-encoding"
        }

        if isAppleMediaContainer(inputFile) && !filteredStreams.isEmpty {
            let asset = AVURLAsset(url: URL(fileURLWithPath: inputFile))
            let appleAudioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            if appleAudioTracks.isEmpty {
                return "Audio track is not readable by Apple media frameworks. Remux requires re-encoding"
            }
        }

        if isAppleMediaContainer(inputFile) {
            let asset = AVURLAsset(url: URL(fileURLWithPath: inputFile))
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            if !isPlayable {
                return "Input is not playable by Apple media frameworks. Remux requires re-encoding"
            }
        }

        return nil
    }

    private func isAppleMediaContainer(_ inputFile: String) -> Bool {
        ["mp4", "m4v", "mov"].contains(URL(fileURLWithPath: inputFile).pathExtension.lowercased())
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

    private func isAppleCompatibleVideoCodec(_ codec: String) -> Bool {
        [
            "h264",
            "hevc",
            "h265",
            "mpeg4"
        ].contains(codec)
    }

    private func isDtsAudioCodec(_ codecName: String?) -> Bool {
        let codec = normalizedProbeValue(codecName)
        return codec.contains("dts") || codec.contains("dca")
    }

    private func isFloatingPointPCMAudio(_ stream: VideoStream) -> Bool {
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

    private func getVideoCodec(videoStreams: FFProbeOutput) -> String? {
        return videoStreams.streams.first(where: { $0.codecType == "video" })?.codecName?.lowercased()
    }

    private func getVideoDimensions(videoStreams: FFProbeOutput) -> (width: Int, height: Int)? {
        guard let videoStream = videoStreams.streams.first(where: { $0.codecType == "video" }),
              let width = videoStream.width,
              let height = videoStream.height else {
            return nil
        }
        return (width, height)
    }

    private func getVideoFrameRate(videoStreams: FFProbeOutput) -> Double? {
        guard let videoStream = videoStreams.streams.first(where: { $0.codecType == "video" }) else {
            return nil
        }
        return Self.frameRate(from: videoStream.averageFrameRate)
            ?? Self.frameRate(from: videoStream.realFrameRate)
    }

    private func getSubtitleMappings(
        inputFile: String,
        subtitleStreams: FFProbeOutput,
        keepEnglishOnly: Bool,
        keepAllEnglishTracks: Bool
    ) async -> [SubtitleMapping] {
        let validCodecs = ["subrip", "ass", "ssa", "mov_text"]

        let supportedStreams = subtitleStreams.streams.filter { stream in
            stream.codecName.map(validCodecs.contains) == true
        }
        var candidates: [SubtitleTrackSelectionCandidate] = []
        for (subtitleIndex, stream) in supportedStreams.enumerated() {
            guard let codec = stream.codecName,
                  validCodecs.contains(codec) else {
                continue
            }

            let language = stream.tags?["language"]?.lowercased()
            let title = stream.tags?["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let handlerName = stream.tags?["handler_name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTitle = title?.lowercased() ?? ""
            let forced = stream.disposition?.isForced == 1 || normalizedTitle.contains("forced")
            let hearingImpaired = stream.disposition?.isHearingImpaired == 1
                || normalizedTitle.contains("hearing impaired")
                || normalizedTitle.contains("sdh")
            let captions = stream.disposition?.isCaptions == 1
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
                isForced: forced,
                isHearingImpaired: hearingImpaired,
                isCaptions: captions
                )
            )
        }

        let englishCandidates = candidates.filter(SubtitleTrackSelectionPolicy.isEnglish)
        let contentInspectionPool = englishCandidates.isEmpty
            ? candidates.filter(SubtitleTrackSelectionPolicy.isUndefinedLanguage)
            : englishCandidates
        if SubtitleTrackSelectionPolicy.needsContentInspection(contentInspectionPool) {
            let inspectedIndexes = Set(contentInspectionPool.map(\.streamIndex))
            for index in candidates.indices where inspectedIndexes.contains(candidates[index].streamIndex) {
                guard let metrics = await subtitleContentMetrics(
                    inputFile: inputFile,
                    streamIndex: candidates[index].streamIndex
                ) else { continue }
                let candidate = candidates[index]
                candidates[index] = SubtitleTrackSelectionCandidate(
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

        let selection = SubtitleTrackSelectionPolicy.select(
            from: candidates,
            keepEnglishOnly: keepEnglishOnly,
            keepAllEnglishTracks: keepAllEnglishTracks
        )
        let preferredStreamIndex = selection.preferred?.streamIndex
        return selection.selected.map { candidate in
            SubtitleMapping(
                index: candidate.streamIndex,
                language: candidate.language ?? (keepEnglishOnly ? "und" : nil),
                isDefault: candidate.streamIndex == preferredStreamIndex,
                isForced: candidate.isForced,
                isHearingImpaired: candidate.isHearingImpaired,
                isCaptions: candidate.isCaptions,
                selectionRationale: candidate.streamIndex == preferredStreamIndex
                    ? selection.rationale : nil
            )
        }
    }

    private func subtitleContentMetrics(
        inputFile: String,
        streamIndex: Int
    ) async -> (cueCount: Int, accessibilityMarkerCount: Int)? {
        let arguments = [
            "-nostdin", "-v", "error", "-i", inputFile,
            "-map", "0:\(streamIndex)", "-f", "srt", "-"
        ]
        guard let text = await runCommandWithOutput(path: ffmpegPath, arguments: arguments) else {
            return nil
        }
        return SubtitleTrackSelectionPolicy.contentMetrics(from: text)
    }

    private func siblingSRTSelection(for inputFile: String) -> SubtitleSelectionPlan? {
        let inputURL = URL(fileURLWithPath: inputFile)
        let directory = inputURL.deletingLastPathComponent()
        let sourceStem = inputURL.deletingPathExtension().lastPathComponent
        let normalizedSourceStem = sourceStem.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )

        guard let directoryContents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let allSRTs = directoryContents.filter { $0.pathExtension.lowercased() == "srt" }
        var matchingSRTs = allSRTs.filter { url in
            let stem = url.deletingPathExtension().lastPathComponent.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return stem == normalizedSourceStem
                || stem.hasPrefix(normalizedSourceStem + ".")
                || stem.hasPrefix(normalizedSourceStem + " ")
        }

        // A conventional movie folder containing exactly one video and one SRT
        // is unambiguous even when the release names differ. Never use this
        // fallback in a flat folder containing several videos.
        if matchingSRTs.isEmpty, allSRTs.count == 1 {
            let videoExtensions = Set(["mkv", "mp4", "avi", "mov", "m4v"])
            let videoCount = directoryContents.filter {
                videoExtensions.contains($0.pathExtension.lowercased())
            }.count
            if videoCount == 1 {
                matchingSRTs = allSRTs
            }
        }

        guard !matchingSRTs.isEmpty else { return nil }

        let candidates = matchingSRTs.enumerated().map { subtitleIndex, url in
            let label = url.deletingPathExtension().lastPathComponent.lowercased()
            let metrics = subtitleMetrics(at: url)
            let forced = label.range(of: #"(^|[ ._-])forced($|[ ._-])"#, options: .regularExpression) != nil
            let hearingImpaired = label.range(
                of: #"(^|[ ._-])(sdh|hi|hearing[ ._-]?impaired)($|[ ._-])"#,
                options: .regularExpression
            ) != nil
            return SubtitleTrackSelectionCandidate(
                streamIndex: subtitleIndex,
                subtitleIndex: subtitleIndex,
                language: "eng",
                title: label,
                handlerName: nil,
                cueCount: metrics?.cueCount,
                accessibilityMarkerCount: metrics?.accessibilityMarkerCount ?? 0,
                isDefault: false,
                isForced: forced,
                isHearingImpaired: hearingImpaired,
                isCaptions: hearingImpaired
            )
        }

        guard let selected = SubtitleTrackSelectionPolicy.preferredFullTrack(from: candidates),
              matchingSRTs.indices.contains(selected.subtitleIndex) else {
            return nil
        }
        let selectedURL = matchingSRTs[selected.subtitleIndex]
        let rationale = SubtitleTrackSelectionPolicy.rationale(for: selected, among: candidates)
        return SubtitleSelectionPlan(
            sourceFile: selectedURL.path,
            mappings: [
                SubtitleMapping(
                    index: 0,
                    language: "eng",
                    isDefault: true,
                    isForced: selected.isForced,
                    isHearingImpaired: selected.isHearingImpaired,
                    isCaptions: selected.isCaptions,
                    selectionRationale: "sibling SRT · \(rationale)"
                )
            ],
            isExternal: true
        )
    }

    private func subtitleMetrics(
        at url: URL
    ) -> (cueCount: Int, accessibilityMarkerCount: Int)? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        return SubtitleTrackSelectionPolicy.contentMetrics(from: text)
    }

    private func buildFFmpegCommand(
        inputFile: String,
        tempFile: String,
        mode: ProcessingMode,
        crfValue: Int = 23,
        resolution: ResolutionOption = .default,
        preset: PresetOption = .fast,
        encodeVideo: Bool = true,
        encodeAudio: Bool = true,
        videoCodec: String?,
        videoWidth: Int?,
        videoHeight: Int?,
        audioMappings: [AudioMapping],
        subtitleMappings: [SubtitleMapping]
    ) -> [String] {
        var cmd: [String] = []

        if mode == .encodeH265 {
            cmd = [
                "-nostdin", "-i", inputFile, "-y",
                "-map", "0:v:0", "-map_metadata", "-1",
                "-movflags", "+faststart",
                "-loglevel", "error", "-nostats", "-progress", "pipe:2"
            ]
            if let insertIndex = cmd.firstIndex(of: "-map") {
                if encodeVideo {
                    cmd.insert(contentsOf: ["-c:v", "libx265", "-x265-params", "log-level=0", "-preset", preset.rawValue, "-crf", "\(crfValue)"], at: insertIndex)
                } else {
                    cmd.insert(contentsOf: ["-c:v", "copy"], at: insertIndex)
                }
            }
            if audioMappings.isEmpty {
                // No audio tracks - add -an flag
                if let insertIndex = cmd.firstIndex(of: "-map") {
                    cmd.insert("-an", at: insertIndex)
                }
            }
            // Add video filter for resolution scaling if needed
            if encodeVideo,
               let width = videoWidth, let height = videoHeight,
               let scaleFilter = resolution.scaleFilter(width: width, height: height) {
                cmd.insert(contentsOf: ["-vf", scaleFilter], at: cmd.firstIndex(of: "-c:v") ?? 2)
            }
            if encodeVideo || videoCodec == "hevc" {
                cmd.append(contentsOf: ["-tag:v", "hvc1"])
            }
        } else if mode == .encodeH264 {
            cmd = [
                "-nostdin", "-i", inputFile, "-y",
                "-map", "0:v:0", "-map_metadata", "-1",
                "-movflags", "+faststart",
                "-loglevel", "error", "-nostats", "-progress", "pipe:2"
            ]
            if let insertIndex = cmd.firstIndex(of: "-map") {
                if encodeVideo {
                    cmd.insert(contentsOf: ["-c:v", "libx264", "-preset", preset.rawValue, "-crf", "\(crfValue)", "-threads", "0"], at: insertIndex)
                } else {
                    cmd.insert(contentsOf: ["-c:v", "copy"], at: insertIndex)
                }
            }
            if audioMappings.isEmpty {
                // No audio tracks - add -an flag
                if let insertIndex = cmd.firstIndex(of: "-map") {
                    cmd.insert("-an", at: insertIndex)
                }
            }
            // Add video filter for resolution scaling if needed
            if encodeVideo,
               let width = videoWidth, let height = videoHeight,
               let scaleFilter = resolution.scaleFilter(width: width, height: height) {
                cmd.insert(contentsOf: ["-vf", scaleFilter], at: cmd.firstIndex(of: "-c:v") ?? 2)
            }
            if !encodeVideo && videoCodec == "hevc" {
                cmd.append(contentsOf: ["-tag:v", "hvc1"])
            }
        } else { // remux
            cmd = [
                "-nostdin", "-i", inputFile, "-y",
                "-c:v", "copy", "-map", "0:v:0", "-map_metadata", "-1",
                "-movflags", "+faststart",
                "-loglevel", "error", "-nostats", "-progress", "pipe:2"
            ]
            if audioMappings.isEmpty {
                // No audio tracks - add -an flag
                if let insertIndex = cmd.firstIndex(of: "-map") {
                    cmd.insert("-an", at: insertIndex)
                }
            }
            if videoCodec == "hevc" {
                cmd.append(contentsOf: ["-tag:v", "hvc1"])
            }
        }

        // Strip source-provided video titles/handlers just as we do for audio.
        // MP4 may replace an empty handler with its generic VideoHandler label.
        cmd.append(contentsOf: ["-metadata:s:v:0", "title="])
        cmd.append(contentsOf: ["-metadata:s:v:0", "handler_name="])

        // Map audio tracks respecting language metadata when available
        for (outputIndex, mapping) in audioMappings.enumerated() {
            cmd.append(contentsOf: ["-map", "0:\(mapping.index)"])
            let copiesAudio = shouldCopyAudio(
                mapping,
                mode: mode,
                encodeAudio: encodeAudio
            )
            cmd.append(contentsOf: [
                "-c:a:\(outputIndex)", copiesAudio ? "copy" : "aac"
            ])
            if let language = mapping.language {
                cmd.append(contentsOf: ["-metadata:s:a:\(outputIndex)", "language=\(language)"])
            }
            // Do not carry release-group, codec, or ripper labels into the MP4.
            // FFmpeg may still emit its generic SoundHandler container fallback.
            cmd.append(contentsOf: ["-metadata:s:a:\(outputIndex)", "title="])
            cmd.append(contentsOf: ["-metadata:s:a:\(outputIndex)", "handler_name="])
            if !copiesAudio, let channelLayout = mapping.channelLayout {
                cmd.append(
                    contentsOf: [
                        "-channel_layout:a:\(outputIndex)",
                        channelLayout
                    ]
                )
            }
            if !copiesAudio {
                cmd.append(contentsOf: ["-b:a:\(outputIndex)", aacBitrate(for: mapping)])
            }
            cmd.append(
                contentsOf: [
                    "-disposition:a:\(outputIndex)",
                    outputIndex == 0 ? "default" : "0"
                ]
            )
        }

        // Map subtitle tracks based on selected preference
        for (outputIndex, subtitle) in subtitleMappings.enumerated() {
            cmd.append(contentsOf: ["-map", "0:\(subtitle.index)"])
            cmd.append(contentsOf: ["-c:s:\(outputIndex)", "mov_text"])
            appendSubtitleMetadataAndDisposition(
                subtitle,
                outputIndex: outputIndex,
                to: &cmd
            )
        }

        // Never let FFmpeg implicitly rebuild QuickTime chapter/data tracks. Some
        // otherwise valid sources contain malformed auxiliary tracks that make the
        // resulting MP4 unreadable by AVPlayer.
        cmd.append(contentsOf: ["-map_chapters", "-1"])
        cmd.append(tempFile)

        return cmd
    }

    private func buildSubtitleMuxCommand(
        encodedAVFile: String,
        sourceFile: String,
        outputFile: String,
        videoCodec: String?,
        audioMappings: [AudioMapping],
        subtitleMappings: [SubtitleMapping]
    ) -> [String] {
        var cmd = [
            "-nostdin",
            "-i", encodedAVFile,
            "-i", sourceFile,
            "-y",
            "-map", "0:v:0",
            "-c:v", "copy"
        ]

        if videoCodec == "hevc" {
            cmd.append(contentsOf: ["-tag:v", "hvc1"])
        }
        cmd.append(contentsOf: ["-metadata:s:v:0", "title="])
        cmd.append(contentsOf: ["-metadata:s:v:0", "handler_name="])

        for (outputIndex, mapping) in audioMappings.enumerated() {
            // The intermediate file contains only the selected tracks, in this
            // same order, so map its compact audio indexes rather than the
            // original input's absolute stream indexes.
            cmd.append(contentsOf: ["-map", "0:a:\(outputIndex)"])
            cmd.append(contentsOf: ["-c:a:\(outputIndex)", "copy"])
            if let language = mapping.language {
                cmd.append(contentsOf: ["-metadata:s:a:\(outputIndex)", "language=\(language)"])
            }
            cmd.append(contentsOf: ["-metadata:s:a:\(outputIndex)", "title="])
            cmd.append(contentsOf: ["-metadata:s:a:\(outputIndex)", "handler_name="])
            cmd.append(contentsOf: [
                "-disposition:a:\(outputIndex)",
                outputIndex == 0 ? "default" : "0"
            ])
        }

        for (outputIndex, subtitle) in subtitleMappings.enumerated() {
            cmd.append(contentsOf: ["-map", "1:\(subtitle.index)"])
            cmd.append(contentsOf: ["-c:s:\(outputIndex)", "mov_text"])
            appendSubtitleMetadataAndDisposition(
                subtitle,
                outputIndex: outputIndex,
                to: &cmd
            )
        }

        cmd.append(contentsOf: [
            "-map_metadata", "-1",
            "-map_chapters", "-1",
            "-movflags", "+faststart",
            "-loglevel", "error",
            "-nostats",
            "-progress", "pipe:2",
            outputFile
        ])
        return cmd
    }

    private func appendSubtitleMetadataAndDisposition(
        _ subtitle: SubtitleMapping,
        outputIndex: Int,
        to arguments: inout [String]
    ) {
        if let language = subtitle.language {
            arguments.append(contentsOf: ["-metadata:s:s:\(outputIndex)", "language=\(language)"])
        }
        let title = standardizedSubtitleTitle(subtitle)
        arguments.append(contentsOf: ["-metadata:s:s:\(outputIndex)", "title=\(title)"])
        arguments.append(contentsOf: ["-metadata:s:s:\(outputIndex)", "handler_name=\(title)"])

        var dispositions: [String] = []
        if subtitle.isDefault { dispositions.append("default") }
        if subtitle.isForced { dispositions.append("forced") }
        if subtitle.isHearingImpaired { dispositions.append("hearing_impaired") }
        if subtitle.isCaptions { dispositions.append("captions") }
        arguments.append(contentsOf: [
            "-disposition:s:\(outputIndex)",
            dispositions.isEmpty ? "0" : dispositions.joined(separator: "+")
        ])
    }

    private func standardizedSubtitleTitle(_ subtitle: SubtitleMapping) -> String {
        let languageName = languageDisplayName(subtitle.language)
        var qualifiers: [String] = []
        if subtitle.isForced { qualifiers.append("Forced") }
        if subtitle.isHearingImpaired || subtitle.isCaptions { qualifiers.append("SDH") }
        return qualifiers.isEmpty
            ? languageName
            : "\(languageName) (\(qualifiers.joined(separator: ", ")))"
    }

    private func languageDisplayName(_ language: String?) -> String {
        let normalized = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "und"
        let knownNames = [
            "und": "Undefined", "eng": "English", "spa": "Spanish",
            "fra": "French", "fre": "French", "deu": "German", "ger": "German",
            "ita": "Italian", "por": "Portuguese", "nld": "Dutch", "dut": "Dutch",
            "pol": "Polish", "rus": "Russian", "ukr": "Ukrainian",
            "ces": "Czech", "cze": "Czech", "ara": "Arabic", "bul": "Bulgarian",
            "dan": "Danish", "est": "Estonian", "fin": "Finnish", "heb": "Hebrew",
            "hin": "Hindi", "hun": "Hungarian", "lav": "Latvian", "lit": "Lithuanian",
            "ell": "Greek", "gre": "Greek", "nor": "Norwegian",
            "ron": "Romanian", "rum": "Romanian", "slv": "Slovenian",
            "swe": "Swedish", "tur": "Turkish"
        ]
        return knownNames[normalized]
            ?? Locale(identifier: "en").localizedString(forLanguageCode: normalized)
            ?? normalized.uppercased()
    }

    private func runCommand(arguments: [String]) async -> (success: Bool, errorMessage: String) {
        activeHistoryFFmpegCommands.append(
            shellCommand(executable: ffmpegPath, arguments: arguments)
        )
        let expectedDuration = currentInputDurationSeconds
        let expectedFrameRate = currentInputFrameRate
        return await withCheckedContinuation { continuation in
            let ffmpegPath = self.ffmpegPath
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: (false, "Process initialization failed"))
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpegPath)
                process.arguments = arguments

                let errorPipe = Pipe()
                let outputPipe = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardError = errorPipe
                process.standardOutput = outputPipe

                let capturedErrorData = ThreadSafeDataBuffer()
                let capturedOutputData = ThreadSafeDataBuffer()

                errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let chunkData = handle.availableData
                    guard !chunkData.isEmpty else { return }

                    capturedErrorData.append(chunkData)

                    guard let self,
                          let chunkText = String(data: chunkData, encoding: .utf8) else {
                        return
                    }

                    DispatchQueue.main.async {
                        Task { @MainActor in
                            self.ingestFFmpegProgressChunk(chunkText)
                        }
                    }
                }

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunkData = handle.availableData
                    guard !chunkData.isEmpty else { return }
                    capturedOutputData.append(chunkData)
                }

                // Store process reference so we can monitor it
                DispatchQueue.main.async {
                    self.currentProcess = process
                }

                do {
                    try process.run()

                    // Start monitoring progress on main thread
                    DispatchQueue.main.async {
                        self.startEncodingProgress()
                    }

                    // Wait for completion in background
                    process.waitUntilExit()

                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    let remainingErrorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    capturedErrorData.append(remainingErrorData)
                    let remainingOutputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    capturedOutputData.append(remainingOutputData)
                    let finalErrorData = capturedErrorData.snapshot()
                    let finalOutputData = capturedOutputData.snapshot()

                    let errorOutput = String(data: finalErrorData, encoding: .utf8) ?? ""
                    let stdoutOutput = String(data: finalOutputData, encoding: .utf8) ?? ""
                    let combinedOutput = errorOutput + "\n" + stdoutOutput
                    let exitCode = process.terminationStatus
                    let terminationReason = Self.terminationReasonDescription(process.terminationReason)
                    let finalFrame = Self.latestFFmpegFrame(in: combinedOutput)
                    let finalMediaTime = Self.latestFFmpegMediaTimeSeconds(in: combinedOutput)
                    let finalProgress = Self.latestFFmpegProgressValue("progress", in: combinedOutput)
                    let finalSpeed = Self.latestFFmpegProgressValue("speed", in: combinedOutput)
                    let diagnosticLines = Self.diagnosticLines(from: combinedOutput)

                    var exitSummary = "FFmpeg process ended: status \(exitCode) · reason \(terminationReason)"
                    if let finalFrame {
                        exitSummary += " · frame \(finalFrame)"
                    }
                    if let finalMediaTime {
                        exitSummary += String(format: " · media time %.2fs", finalMediaTime)
                    }
                    if let finalSpeed, !finalSpeed.isEmpty {
                        exitSummary += " · speed \(finalSpeed)"
                    }
                    if let finalProgress, !finalProgress.isEmpty {
                        exitSummary += " · progress \(finalProgress)"
                    }

                    // Stop monitoring
                    DispatchQueue.main.async {
                        self.addLog(exitSummary)
                        if !diagnosticLines.isEmpty {
                            self.addLog("FFmpeg diagnostic output (last \(diagnosticLines.count) meaningful lines):")
                            for line in diagnosticLines {
                                self.addLog("  \(line)")
                            }
                        }
                        self.stopEncodingProgress()
                        self.currentProcess = nil
                    }

                    if exitCode == 0 {
                        if let expectedDuration,
                           let expectedFrameRate,
                           let finalFrame {
                            let tolerance = max(5, min(30, expectedDuration * 0.005))
                            let videoTime = TimeInterval(finalFrame) / expectedFrameRate
                            if expectedDuration - videoTime > tolerance {
                                let message = String(
                                    format: "FFmpeg exited successfully but video ended prematurely at frame %d (%.2fs of %.2fs)",
                                    finalFrame,
                                    videoTime,
                                    expectedDuration
                                )
                                DispatchQueue.main.async {
                                    self.addLog("􀁡 \(message)")
                                }
                                continuation.resume(returning: (false, message))
                                return
                            }
                        } else if let expectedDuration, let finalMediaTime {
                            let tolerance = max(5, min(30, expectedDuration * 0.005))
                            if expectedDuration - finalMediaTime > tolerance {
                                let message = String(
                                    format: "FFmpeg exited successfully but ended prematurely at %.2fs of %.2fs",
                                    finalMediaTime,
                                    expectedDuration
                                )
                                DispatchQueue.main.async {
                                    self.addLog("􀁡 \(message)")
                                }
                                continuation.resume(returning: (false, message))
                                return
                            }
                        }
                        continuation.resume(returning: (true, ""))
                    } else if self.shouldCancelProcessing {
                        continuation.resume(returning: (false, "Cancelled by user"))
                    } else {
                        var errorMessage = "FFmpeg exited with code \(exitCode)"

                        // Try stderr first, then stdout
                        if !diagnosticLines.isEmpty {
                            errorMessage = Self.mostMeaningfulError(in: diagnosticLines, exitCode: exitCode)
                        } else {
                            DispatchQueue.main.async {
                                self.addLog("FFmpeg failed with exit code \(exitCode) and produced no diagnostic output")
                            }
                        }

                        continuation.resume(returning: (false, errorMessage))
                    }
                } catch {
                    let errorMsg = error.localizedDescription
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    DispatchQueue.main.async {
                        self.stopEncodingProgress()
                        self.currentProcess = nil
                    }
                    continuation.resume(returning: (false, errorMsg))
                }
            }
        }
    }

    private func startEncodingProgress() {
        guard let startTime = self.startTime else { return }

        encodingTimer?.invalidate()
        encodingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                let elapsed = Date().timeIntervalSince(startTime)
                self.updateEncodingProgressDisplay(elapsedWallSeconds: elapsed)
            }
        }
    }

    private func stopEncodingProgress() {
        encodingTimer?.invalidate()
        encodingTimer = nil
        ffmpegProgressTail = ""
        currentFileProgressFraction = 0
        encodingProgress = ""
    }

    private func startFramePreviewUpdates(inputFile: String) {
        stopFramePreviewUpdates(clearPreview: true)

        let token = UUID()
        framePreviewToken = token
        framePreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastPreviewTime: TimeInterval?

            while !Task.isCancelled, self.framePreviewToken == token {
                let duration = self.currentInputDurationSeconds ?? 0
                let initialTime = duration > 0 ? min(max(duration * 0.05, 1), 30) : 1
                let previewTime = self.currentEncodedTimeSeconds > 1
                    ? self.currentEncodedTimeSeconds
                    : initialTime

                if lastPreviewTime == nil || abs(previewTime - (lastPreviewTime ?? 0)) >= 2 {
                    if let data = await self.extractFramePreview(
                        inputFile: inputFile,
                        timestamp: previewTime,
                        token: token
                    ),
                       !Task.isCancelled,
                       self.framePreviewToken == token,
                       let image = NSImage(data: data) {
                        self.currentFramePreview = image
                        lastPreviewTime = previewTime
                    }
                }

                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
            }
        }
    }

    private func stopFramePreviewUpdates(clearPreview: Bool) {
        framePreviewToken = UUID()
        framePreviewTask?.cancel()
        framePreviewTask = nil

        if let process = framePreviewProcess, process.isRunning {
            process.terminate()
        }
        framePreviewProcess = nil

        if clearPreview {
            currentFramePreview = nil
        }
    }

    private func extractFramePreview(
        inputFile: String,
        timestamp: TimeInterval,
        token: UUID
    ) async -> Data? {
        let executable = ffmpegPath
        let arguments = [
            "-nostdin",
            "-ss", String(format: "%.3f", max(timestamp, 0)),
            "-i", inputFile,
            "-map", "0:v:0",
            "-frames:v", "1",
            "-vf", "scale=320:180:force_original_aspect_ratio=decrease",
            "-an", "-sn",
            "-threads", "1",
            "-q:v", "5",
            "-loglevel", "error",
            "-f", "image2pipe",
            "-vcodec", "mjpeg",
            "pipe:1"
        ]

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                let outputBuffer = ThreadSafeDataBuffer(maxBytes: nil)
                let errorBuffer = ThreadSafeDataBuffer()
                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    outputBuffer.append(data)
                }
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    errorBuffer.append(data)
                }

                DispatchQueue.main.async {
                    guard self.framePreviewToken == token else {
                        process.terminate()
                        return
                    }
                    self.framePreviewProcess = process
                }

                do {
                    try process.run()
                    process.waitUntilExit()

                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    let remainingOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingOutput.isEmpty {
                        outputBuffer.append(remainingOutput)
                    }

                    let previewData = outputBuffer.snapshot()
                    DispatchQueue.main.async {
                        if self.framePreviewProcess === process {
                            self.framePreviewProcess = nil
                        }
                    }
                    continuation.resume(
                        returning: process.terminationStatus == 0 && !previewData.isEmpty
                            ? previewData
                            : nil
                    )
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    DispatchQueue.main.async {
                        if self.framePreviewProcess === process {
                            self.framePreviewProcess = nil
                        }
                    }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func runCommandWithOutput(path: String, arguments: [String]) async -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                let outputBuffer = ThreadSafeDataBuffer(maxBytes: nil)
                let errorBuffer = ThreadSafeDataBuffer(maxBytes: nil)

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    outputBuffer.append(chunk)
                }

                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    errorBuffer.append(chunk)
                }

                do {
                    try process.run()
                    process.waitUntilExit()

                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil

                    let remainingOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingOutput.isEmpty {
                        outputBuffer.append(remainingOutput)
                    }

                    let remainingError = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingError.isEmpty {
                        errorBuffer.append(remainingError)
                    }

                    let outputData = outputBuffer.snapshot()

                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: nil)
                        return
                    }

                    continuation.resume(returning: String(data: outputData, encoding: .utf8))
                } catch {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func moveFileAsync(from source: String, to destination: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    // Remove existing file if present
                    if FileManager.default.fileExists(atPath: destination) {
                        try FileManager.default.removeItem(atPath: destination)
                    }
                    // Move file
                    try FileManager.default.moveItem(atPath: source, toPath: destination)
                    continuation.resume(returning: true)
                } catch {
                    DispatchQueue.main.async {
                        self.addLog("􀁡 File move error: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func deleteFileAsync(at path: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    continuation.resume(returning: true)
                } catch {
                    DispatchQueue.main.async {
                        self.addLog("􀁡 File delete error: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func cancelScan() {
        shouldCancelScan = true
        shouldCancelProcessing = true
        activeFramePreviewInputFile = nil
        stopFramePreviewUpdates(clearPreview: true)

        // Terminate current process if one is running
        if let process = currentProcess, process.isRunning {
            process.terminate()
            addLog("􀛶 Terminating current operation...")
            scheduleForcedStop(for: process)
        } else {
            addLog("􀊆 Cancelling...")
        }

        // Clear dock badge when cancelled
        clearDockBadge()
    }

    func requestStopAfterCurrentFile() {
        guard isProcessing, !stopAfterCurrentFileRequested else { return }
        stopAfterCurrentFileRequested = true
        addLog("􀛶 Stop requested after the current file finishes.")
    }

    func cancelStopAfterCurrentFile() {
        guard isProcessing, stopAfterCurrentFileRequested else { return }
        stopAfterCurrentFileRequested = false
        addLog("􀁢 Stop-after-current-file request canceled. The batch will continue.")
    }

    private func scheduleForcedStop(for process: Process) {
        forcedStopTask?.cancel()
        forcedStopTask = Task { @MainActor [weak self, weak process] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            guard let self, let process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
            self.addLog("􀛶 FFmpeg did not stop gracefully; forced it to stop.")
            self.forcedStopTask = nil
        }
    }

    func cancelForApplicationTermination() async {
        cancelScan()

        guard let process = currentProcess, process.isRunning else { return }

        // Give FFmpeg a brief opportunity to close its output and exit cleanly.
        for _ in 0..<20 {
            guard process.isRunning else { return }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }

        // Do not leave a child encoder behind if it ignores SIGTERM.
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            addLog("Forced the current operation to stop before quitting.")
        }
    }

    func scanInputFolder(directoryPath: String, outputPath: String = "") async {
        let sleepAssertion = SystemSleepAssertion(reason: "MP4 Tool is scanning for video files")
        defer { sleepAssertion.invalidate() }

        DispatchQueue.main.async {
            self.isProcessing = true
            self.scanProgress = "Scanning for video files..."
            self.videoFiles = []
        }

        let videoFormats = ["mkv", "mp4", "avi", "mov", "m4v"]
        let wordsToIgnore = ["sample", "SAMPLE", "Sample"]

        // Perform recursive scan in background
        let videoFileInfos: [VideoFileInfo] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var files: [VideoFileInfo] = []
                var filesScanned = 0
                var lastUpdateTime = Date()

                let fileManager = FileManager.default
                guard let enumerator = fileManager.enumerator(
                    at: URL(fileURLWithPath: directoryPath),
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    continuation.resume(returning: [])
                    return
                }

                for case let fileURL as URL in enumerator {
                    // Only process regular files
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                          resourceValues.isRegularFile == true else {
                        continue
                    }

                    filesScanned += 1

                    // Update progress periodically
                    let now = Date()
                    if filesScanned % 50 == 0 || now.timeIntervalSince(lastUpdateTime) > 0.5 {
                        lastUpdateTime = now
                        let scannedCount = filesScanned
                        DispatchQueue.main.async {
                            self.scanProgress = "Scanned \(scannedCount) files..."
                        }
                    }

                    let fileName = fileURL.lastPathComponent
                    let ext = fileURL.pathExtension.lowercased()

                    // Check if it's a supported video file
                    guard videoFormats.contains(ext) else { continue }

                    // Skip files with ignored words
                    if wordsToIgnore.contains(where: { fileName.contains($0) }) {
                        continue
                    }

                    // Get file size
                    if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                       let fileSize = attributes[.size] as? Int64 {
                        let sizeMB = Int(fileSize / (1024 * 1024))

                        files.append(VideoFileInfo(
                            fileName: fileName,
                            filePath: fileURL.path,
                            fileExtension: ext.uppercased(),
                            fileSizeMB: sizeMB
                        ))
                    }
                }

                // Sort by file path for consistent ordering
                files.sort { $0.filePath < $1.filePath }

                continuation.resume(returning: files)
            }
        }

        DispatchQueue.main.async {
            self.videoFiles = videoFileInfos
            self.totalFiles = videoFileInfos.count
            self.scanProgress = ""
            self.isProcessing = false

            // Check for conflicts if output path is provided
            if !outputPath.isEmpty {
                for (index, _) in self.videoFiles.enumerated() {
                    self.checkFileForConflicts(fileIndex: index, outputPath: outputPath, createSubfolders: false)
                }
            }
        }

        addLog("􀅴 Found \(videoFileInfos.count) video files to process")
    }

    // MARK: - Notifications

    private func sendProcessingCompleteNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Processing Complete"
        content.body = "Your video files have been processed successfully."
        content.sound = .default

        let request = UNNotificationRequest(identifier: "processingComplete", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func clearProcessingNotifications() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["processingComplete"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["processingComplete"])
        if #available(macOS 13.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        }

        // Clear app badge
        clearDockBadge()
    }

    // Check for file conflicts for a specific file
    func checkFileForConflicts(
        fileIndex: Int,
        outputPath: String,
        createSubfolders: Bool,
        automaticRename: Bool = false
    ) {
        guard fileIndex < videoFiles.count else { return }

        let fileInfo = videoFiles[fileIndex]
        let inputFilePath = fileInfo.filePath
        let outputFileName = makeOutputFileName(fromInputFileName: fileInfo.fileName, automaticRename: automaticRename)

        let outputFilePath: String
        if createSubfolders {
            let folderName = (outputFileName as NSString).deletingPathExtension
            let outputDir = (outputPath as NSString).appendingPathComponent(folderName)
            outputFilePath = (outputDir as NSString).appendingPathComponent(outputFileName)
        } else {
            outputFilePath = (outputPath as NSString).appendingPathComponent(outputFileName)
        }

        var fileConflicts: [String] = []

        // Check 1: Is the input file in the same location as the output?
        let inputDir = (inputFilePath as NSString).deletingLastPathComponent
        if !createSubfolders && inputDir == outputPath {
            fileConflicts.append("Same folder")
        }

        // Check 2: Does the output file already exist?
        if FileManager.default.fileExists(atPath: outputFilePath) {
            fileConflicts.append("File exists")
        }

        if !fileConflicts.isEmpty {
            videoFiles[fileIndex].hasConflict = true
            videoFiles[fileIndex].conflictReason = fileConflicts.joined(separator: " • ")
        } else {
            videoFiles[fileIndex].hasConflict = false
            videoFiles[fileIndex].conflictReason = ""
        }
    }

    // Check for files that would be replaced/overwritten during processing
    func checkForFileConflicts(
        outputPath: String,
        createSubfolders: Bool,
        automaticRename: Bool = false
    ) -> Bool {
        var hasConflicts = false

        // Only check files in the queue
        if !videoFiles.isEmpty {
            for (index, _) in videoFiles.enumerated() {
                checkFileForConflicts(
                    fileIndex: index,
                    outputPath: outputPath,
                    createSubfolders: createSubfolders,
                    automaticRename: automaticRename
                )
                if videoFiles[index].hasConflict {
                    hasConflicts = true
                }
            }
        }

        return hasConflicts
    }

    private func makeOutputFileName(fromInputFileName inputFileName: String, automaticRename: Bool) -> String {
        if automaticRename {
            return AutomaticVideoFileNamer.suggestedOutputFileName(
                fromInputFileName: inputFileName,
                outputExtension: "mp4",
                fallbackSuffix: nil
            )
        }
        return ((inputFileName as NSString).deletingPathExtension as NSString).appendingPathExtension("mp4") ?? inputFileName
    }
}
