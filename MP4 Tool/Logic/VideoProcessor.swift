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

struct VideoStream: Codable {
    let index: Int
    let codecType: String?
    let codecName: String?
    let tags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case tags
    }
}

struct FFProbeOutput: Codable {
    let streams: [VideoStream]
}

enum ProcessingMode: String, CaseIterable {
    case encodeH264 = "encode_h264"
    case encodeH265 = "encode_h265"
    case remux = "remux"

    var description: String {
        switch self {
        case .encodeH264: return "Encode (H.264)"
        case .encodeH265: return "Encode (H.265)"
        case .remux: return "Remux (Copy to MP4)"
        }
    }
}

enum ProcessingStatus {
    case pending
    case processing
    case completed
    case failed
}

struct VideoFileInfo: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let fileExtension: String
    let fileSizeMB: Int
    var status: ProcessingStatus = .pending
    var processingTimeSeconds: Int = 0
    var newSizeMB: Int = 0
    var hasConflict: Bool = false
    var conflictReason: String = ""
}

class VideoProcessor: ObservableObject {
    @Published var isProcessing = false
    @Published var currentFile = ""
    @Published var totalFiles = 0
    @Published var currentFileIndex = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var originalSize: Int64 = 0
    @Published var newSize: Int64 = 0
    @Published var logText: String = ""
    @Published var scanProgress: String = ""
    @Published var encodingProgress: String = ""
    @Published var videoFiles: [VideoFileInfo] = []
    @Published var ffmpegAvailable = false
    @Published var ffmpegMissingMessage = ""
    @Published var processingHadError = false

    private var startTime: Date?
    private var timer: Timer?
    private nonisolated(unsafe) var shouldCancelScan = false
    private nonisolated(unsafe) var shouldCancelProcessing = false
    private var encodingTimer: Timer?
    private var currentProcess: Process?

    private let ffmpegPath: String
    private let ffprobePath: String

    init() {
        var foundFfmpeg = false
        var foundFfprobe = false
        var tempFfmpegPath = ""
        var tempFfprobePath = ""

        // 1. Try bundled binaries in Resources
        if let ffmpegURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "bin"),
           let ffprobeURL = Bundle.main.url(forResource: "ffprobe", withExtension: nil, subdirectory: "bin") {
            tempFfmpegPath = ffmpegURL.path
            tempFfprobePath = ffprobeURL.path
            foundFfmpeg = FileManager.default.fileExists(atPath: tempFfmpegPath)
            foundFfprobe = FileManager.default.fileExists(atPath: tempFfprobePath)
        } else if let ffmpegURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
                  let ffprobeURL = Bundle.main.url(forResource: "ffprobe", withExtension: nil) {
            // If bin folder was flattened
            tempFfmpegPath = ffmpegURL.path
            tempFfprobePath = ffprobeURL.path
            foundFfmpeg = FileManager.default.fileExists(atPath: tempFfmpegPath)
            foundFfprobe = FileManager.default.fileExists(atPath: tempFfprobePath)
        } else {
            // Fallback to resource path
            let resourcePath = Bundle.main.resourcePath ?? ""
            tempFfmpegPath = resourcePath + "/bin/ffmpeg"
            tempFfprobePath = resourcePath + "/bin/ffprobe"
            foundFfmpeg = FileManager.default.fileExists(atPath: tempFfmpegPath)
            foundFfprobe = FileManager.default.fileExists(atPath: tempFfprobePath)
        }

        // 2. If bundled binaries not found, try system PATH
        if !foundFfmpeg || !foundFfprobe {
            tempFfmpegPath = Self.findInPath(command: "ffmpeg") ?? ""
            tempFfprobePath = Self.findInPath(command: "ffprobe") ?? ""
            foundFfmpeg = !tempFfmpegPath.isEmpty
            foundFfprobe = !tempFfprobePath.isEmpty
        }

        self.ffmpegPath = tempFfmpegPath
        self.ffprobePath = tempFfprobePath

        // Set availability status
        if foundFfmpeg && foundFfprobe {
            self.ffmpegAvailable = true
            addLog("􀅴 Found ffmpeg and ffprobe")
        } else {
            self.ffmpegAvailable = false
            var missing: [String] = []
            if !foundFfmpeg { missing.append("ffmpeg") }
            if !foundFfprobe { missing.append("ffprobe") }
            self.ffmpegMissingMessage = "Missing required tools: \(missing.joined(separator: ", ")).\nPlease install ffmpeg & ffprobe. Or compile this app with binaries bundled into the Resource folder."
            addLog("􀇾 WARNING: \(self.ffmpegMissingMessage)")
        }
    }

    private static func findInPath(command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "which \(command)"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {
            // Silent failure
        }

        return nil
    }

    func addLog(_ message: String) {
        DispatchQueue.main.async {
            if !self.logText.isEmpty {
                self.logText += "\n"
            }
            self.logText += message
            print(message)
        }
    }

    private func getTimestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
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

    private func updateDockBadge(filesRemaining: Int) {
        DispatchQueue.main.async {
            NSApplication.shared.dockTile.badgeLabel = String(filesRemaining)
        }
    }

    private func setDockBadgeCheckmark() {
        DispatchQueue.main.async {
            NSApplication.shared.dockTile.badgeLabel = "✓"
        }
    }

    private func clearDockBadge() {
        DispatchQueue.main.async {
            NSApplication.shared.dockTile.badgeLabel = ""
        }
    }

    func processFolder(
        inputPath: String,
        outputPath: String,
        mode: ProcessingMode,
        crfValue: Int = 23,
        createSubfolders: Bool,
        deleteOriginal: Bool = true,
        keepEnglishAudioOnly: Bool,
        keepEnglishSubtitlesOnly: Bool
    ) async {
        DispatchQueue.main.async {
            self.isProcessing = true
            self.logText = ""
            self.currentFileIndex = 0
            self.shouldCancelProcessing = false
            self.processingHadError = false
        }

        addLog("􀊄 Starting processing...")
        if !inputPath.isEmpty {
            addLog("􀈖 Input Directory: \(inputPath)")
        }
        addLog("􀈖 Output Directory: \(outputPath)")
        addLog("􀣋 Mode: \(mode.rawValue)")
        if mode == .encodeH265 || mode == .encodeH264 {
            addLog("􀏃 CRF: \(crfValue)")
        }
        addLog("􀈕 Create Subfolders: \(createSubfolders)")
        addLog("􀈑 Delete Original: \(deleteOriginal)")
        addLog("􀀁 Keep English Audio Only: \(keepEnglishAudioOnly)")
        addLog("􀀃 Keep English Subtitles Only: \(keepEnglishSubtitlesOnly)")

        // Verify output directory exists
        guard FileManager.default.fileExists(atPath: outputPath) else {
            addLog("􀁡 Output directory does not exist!")
            DispatchQueue.main.async { self.isProcessing = false }
            return
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

        // Set initial dock badge with total files
        updateDockBadge(filesRemaining: filesToProcess.count)

        for (index, fileInfo) in filesToProcess.enumerated() {
            // Check for cancellation
            if shouldCancelProcessing {
                addLog("􀛶 Processing cancelled by user")
                clearDockBadge()
                break
            }

            // Check if file has been deleted from the queue
            if !videoFiles.contains(where: { $0.filePath == fileInfo.path }) {
                addLog("􀛷 Skipped: \(fileInfo.name) (removed from queue)")
                continue
            }

            // Mark file as processing
            DispatchQueue.main.async {
                self.currentFileIndex = index + 1
                self.currentFile = fileInfo.name
                if index < self.videoFiles.count {
                    self.videoFiles[index].status = .processing
                }
            }

            addLog("\n􀎶 File \(index + 1)/\(filesToProcess.count)")
            addLog("⏱ Start time: \(getTimestampString())")
            addLog("􀅴 Processing: \(fileInfo.name)")

            let inputFilePath = fileInfo.path
            let outputFileName = ((fileInfo.name as NSString).deletingPathExtension as NSString).appendingPathExtension("mp4")!

            let outputFilePath: String
            if createSubfolders {
                let folderName = (fileInfo.name as NSString).deletingPathExtension
                let outputDir = (outputPath as NSString).appendingPathComponent(folderName)
                outputFilePath = (outputDir as NSString).appendingPathComponent(outputFileName)

                try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
            } else {
                outputFilePath = (outputPath as NSString).appendingPathComponent(outputFileName)
            }

            let tempOutputFile = NSTemporaryDirectory() + UUID().uuidString + ".mp4"

            // Process the video
            let fileStartTime = Date()
            let (conversionSuccess, errorReason) = await convertToMP4(
                inputFile: inputFilePath,
                tempFile: tempOutputFile,
                mode: mode,
                crfValue: crfValue,
                keepEnglishAudioOnly: keepEnglishAudioOnly,
                keepEnglishSubtitlesOnly: keepEnglishSubtitlesOnly
            )
            let fileEndTime = Date()

            if conversionSuccess {
                // Get file sizes
                let inputSize = try? FileManager.default.attributesOfItem(atPath: inputFilePath)[.size] as? Int64 ?? 0
                let outputSize = try? FileManager.default.attributesOfItem(atPath: tempOutputFile)[.size] as? Int64 ?? 0

                let inputSizeMB = (inputSize ?? 0) / (1024 * 1024)
                let outputSizeMB = (outputSize ?? 0) / (1024 * 1024)

                // Move to final location (run in background to avoid blocking on network shares)
                addLog("􀐱 Moving file to output location...")
                let moveSuccess = await moveFileAsync(from: tempOutputFile, to: outputFilePath)

                if !moveSuccess {
                    addLog("⏱ End time: \(getTimestampString())")
                    addLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    addLog("􀁡 FAILED: Could not move file to output location")
                    addLog("File: \(fileInfo.name)")
                    addLog("Output path may not be writable or disk may be full")
                    addLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                    try? FileManager.default.removeItem(atPath: tempOutputFile)

                    // Mark file as failed
                    DispatchQueue.main.async {
                        if index < self.videoFiles.count {
                            self.videoFiles[index].status = .failed
                        }
                        self.processingHadError = true
                    }
                    continue
                }

                addLog("⏱ End time: \(getTimestampString())")
                addLog("􀁢 Done processing")
                addLog("􀅴 Moved file. Old Size: \(inputSizeMB)MB New Size: \(outputSizeMB)MB")

                let duration = fileEndTime.timeIntervalSince(fileStartTime)
                addLog("􀅴 Completed in \(formatDuration(seconds: Int(duration)))")

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

                // Mark file as completed with processing time and new size
                let filesRemaining = filesToProcess.count - (index + 1)
                DispatchQueue.main.async {
                    if index < self.videoFiles.count {
                        self.videoFiles[index].status = .completed
                        self.videoFiles[index].processingTimeSeconds = Int(duration)
                        self.videoFiles[index].newSizeMB = Int(outputSizeMB)
                    }
                }

                // Update dock badge with remaining files
                if filesRemaining > 0 {
                    updateDockBadge(filesRemaining: filesRemaining)
                }
            } else {
                addLog("⏱ End time: \(getTimestampString())")
                addLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                addLog("􀁡 FAILED: \(fileInfo.name)")
                addLog("Reason: \(errorReason)")
                addLog("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
                try? FileManager.default.removeItem(atPath: tempOutputFile)

                // Mark file as failed
                DispatchQueue.main.async {
                    if index < self.videoFiles.count {
                        self.videoFiles[index].status = .failed
                    }
                    self.processingHadError = true
                }
            }
        }

        addLog("\n􀋚 All files processed!")

        // Set dock badge to checkmark when done
        setDockBadgeCheckmark()

        DispatchQueue.main.async {
            self.isProcessing = false
            self.shouldCancelProcessing = false

            // Send notification if app is not in focus
            if !NSApplication.shared.isActive {
                self.sendProcessingCompleteNotification()
            }
        }
    }

    private func convertToMP4(
        inputFile: String,
        tempFile: String,
        mode: ProcessingMode,
        crfValue: Int = 23,
        keepEnglishAudioOnly: Bool,
        keepEnglishSubtitlesOnly: Bool
    ) async -> (success: Bool, errorReason: String) {
        // Probe streams
        guard let audioStreams = await probeStreams(inputFile: inputFile, selectStreams: "a"),
              let videoStreams = await probeStreams(inputFile: inputFile, selectStreams: nil),
              let subtitleStreams = await probeStreams(inputFile: inputFile, selectStreams: "s") else {
            addLog("􀁡 Failed to probe streams (ffprobe couldn't analyze the file)")
            return (false, "Failed to probe streams")
        }

        // Determine audio stream mappings
        var audioMappings = getAudioMappings(audioStreams: audioStreams, keepEnglishOnly: keepEnglishAudioOnly)
        if audioMappings.isEmpty {
            if keepEnglishAudioOnly {
                // If no English/undefined tracks found, fall back to keeping all tracks
                addLog("􀇾 No English/undefined audio found. Processing all audio tracks.")
                audioMappings = getAudioMappings(audioStreams: audioStreams, keepEnglishOnly: false)
                if audioMappings.isEmpty {
                    addLog("􀁡 No audio tracks found. Skipping.")
                    return (false, "No audio tracks found in file")
                }
            } else {
                addLog("􀁡 No audio tracks found. Skipping.")
                return (false, "No audio tracks found in file")
            }
        }

        // Get video codec
        let videoCodec = getVideoCodec(videoStreams: videoStreams)

        // Check for AV1 in remux mode
        if mode == .remux && videoCodec == "av1" {
            addLog("􀁡 AV1 codec detected. Please use encode mode.")
            return (false, "AV1 codec not supported in remux mode - use encode mode instead")
        }

        // Determine subtitle stream mappings
        var subtitleMappings = getSubtitleMappings(
            subtitleStreams: subtitleStreams,
            keepEnglishOnly: keepEnglishSubtitlesOnly
        )

        // If no English/undefined subtitles found and filter is enabled, fall back to all subtitles
        if subtitleMappings.isEmpty && keepEnglishSubtitlesOnly {
            addLog("􀇾 No English/undefined subtitles found. Processing all subtitles.")
            subtitleMappings = getSubtitleMappings(
                subtitleStreams: subtitleStreams,
                keepEnglishOnly: false
            )
        }

        // Build ffmpeg command
        let cmd = buildFFmpegCommand(
            inputFile: inputFile,
            tempFile: tempFile,
            mode: mode,
            crfValue: crfValue,
            videoCodec: videoCodec,
            audioMappings: audioMappings,
            subtitleMappings: subtitleMappings
        )

        // Log the ffmpeg command being run
        addLog("􀅴 Running in \(mode.rawValue) mode")
        addLog("􀅴 FFmpeg command:")
        let commandString = ([ffmpegPath] + cmd).joined(separator: " ")
        addLog("  \(commandString)")
        if mode == .encodeH265 || mode == .encodeH264 {
            addLog("􀐱 Encoding started - this may take a while...")
        }

        // Start timer and file size monitoring
        DispatchQueue.main.async {
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
                    if let size = try? FileManager.default.attributesOfItem(atPath: tempFile)[.size] as? Int64 {
                        self.newSize = size
                    }
                }
            }
        }

        // Run ffmpeg (now async, won't block)
        let (success, ffmpegError) = await runCommand(arguments: cmd)

        // Stop timer
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
        }

        if success {
            return (true, "")
        } else {
            return (false, ffmpegError)
        }
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

    private func getAudioMappings(audioStreams: FFProbeOutput, keepEnglishOnly: Bool) -> [(index: Int, language: String?)] {
        let streams = audioStreams.streams

        if keepEnglishOnly {
            return streams.compactMap { stream in
                let language = (stream.tags?["language"] ?? "und").lowercased()
                guard language == "eng" || language == "und" else {
                    return nil
                }
                return (index: stream.index, language: "eng")
            }
        } else {
            return streams.map { stream in
                let language = stream.tags?["language"]?.lowercased()
                return (index: stream.index, language: language)
            }
        }
    }

    private func getVideoCodec(videoStreams: FFProbeOutput) -> String? {
        return videoStreams.streams.first(where: { $0.codecType == "video" })?.codecName?.lowercased()
    }

    private func getSubtitleMappings(
        subtitleStreams: FFProbeOutput,
        keepEnglishOnly: Bool
    ) -> [(index: Int, language: String?)] {
        let validCodecs = ["subrip", "ass", "ssa", "mov_text"]

        return subtitleStreams.streams.compactMap { stream in
            guard let codec = stream.codecName,
                  validCodecs.contains(codec) else {
                return nil
            }

            let language = stream.tags?["language"]?.lowercased()

            if keepEnglishOnly {
                let normalizedLanguage = language ?? "und"
                guard normalizedLanguage == "eng" || normalizedLanguage == "und" else {
                    return nil
                }
                return (index: stream.index, language: "eng")
            }

            return (index: stream.index, language: language)
        }
    }

    private func buildFFmpegCommand(
        inputFile: String,
        tempFile: String,
        mode: ProcessingMode,
        crfValue: Int = 23,
        videoCodec: String?,
        audioMappings: [(index: Int, language: String?)],
        subtitleMappings: [(index: Int, language: String?)]
    ) -> [String] {
        var cmd: [String] = []

        if mode == .encodeH265 {
            cmd = [
                "-i", inputFile, "-y",
                "-c:v", "libx265", "-x265-params", "log-level=0", "-preset", "fast", "-crf", "\(crfValue)",
                "-c:a", "aac", "-b:a", "192k", "-channel_layout", "5.1",
                "-map", "0:v:0", "-map_metadata", "-1",
                "-tag:v", "hvc1", "-movflags", "+faststart", "-loglevel", "quiet"
            ]
        } else if mode == .encodeH264 {
            cmd = [
                "-i", inputFile, "-y",
                "-c:v", "libx264", "-preset", "fast", "-crf", "\(crfValue)",
                "-c:a", "aac", "-b:a", "192k", "-channel_layout", "5.1",
                "-map", "0:v:0", "-map_metadata", "-1",
                "-movflags", "+faststart", "-loglevel", "quiet"
            ]
        } else { // remux
            cmd = [
                "-i", inputFile, "-y",
                "-c:v", "copy", "-c:a", "copy", "-map", "0:v:0", "-map_metadata", "-1",
                "-movflags", "+faststart", "-loglevel", "quiet"
            ]
            if videoCodec == "hevc" {
                cmd.append(contentsOf: ["-tag:v", "hvc1"])
            }
        }

        // Map audio tracks respecting language metadata when available
        for (outputIndex, mapping) in audioMappings.enumerated() {
            cmd.append(contentsOf: ["-map", "0:\(mapping.index)"])
            if let language = mapping.language {
                cmd.append(contentsOf: ["-metadata:s:a:\(outputIndex)", "language=\(language)"])
            }
        }

        // Map subtitle tracks based on selected preference
        for (outputIndex, subtitle) in subtitleMappings.enumerated() {
            cmd.append(contentsOf: ["-map", "0:\(subtitle.index)"])
            cmd.append(contentsOf: ["-c:s:\(outputIndex)", "mov_text"])
            if let language = subtitle.language {
                cmd.append(contentsOf: ["-metadata:s:s:\(outputIndex)", "language=\(language)"])
            }
        }

        cmd.append(tempFile)

        return cmd
    }

    private func runCommand(arguments: [String]) async -> (success: Bool, errorMessage: String) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: (false, "Process initialization failed"))
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.ffmpegPath)
                process.arguments = arguments

                let errorPipe = Pipe()
                let outputPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = outputPipe

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

                    // Stop monitoring
                    DispatchQueue.main.async {
                        self.stopEncodingProgress()
                        self.currentProcess = nil
                    }

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: (true, ""))
                    } else {
                        // Capture both stderr and stdout for error details
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

                        var errorMessage = "Process exited with code \(process.terminationStatus)"

                        // Try stderr first, then stdout
                        if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                            let lines = errorOutput.split(separator: "\n", omittingEmptySubsequences: true)

                            // Log all stderr for debugging
                            DispatchQueue.main.async {
                                self.addLog("􀅴 FFmpeg output:")
                                for line in lines {
                                    self.addLog("  \(line)")
                                }
                            }

                            // Look for meaningful error lines (skip progress and warnings)
                            for line in lines.reversed() {
                                let lineStr = String(line)
                                if lineStr.lowercased().contains("error") ||
                                   lineStr.lowercased().contains("invalid") ||
                                   lineStr.lowercased().contains("not found") ||
                                   lineStr.lowercased().contains("unknown") ||
                                   lineStr.lowercased().contains("failed") ||
                                   lineStr.lowercased().contains("incompatible") {
                                    errorMessage = lineStr
                                    break
                                }
                            }
                            // If no specific error found, use last line
                            if errorMessage.starts(with: "Process exited") {
                                if let lastError = lines.last {
                                    errorMessage = String(lastError)
                                }
                            }
                        } else if let stdoutOutput = String(data: outputData, encoding: .utf8), !stdoutOutput.isEmpty {
                            let lines = stdoutOutput.split(separator: "\n", omittingEmptySubsequences: true)

                            // Log all output for debugging
                            DispatchQueue.main.async {
                                self.addLog("􀅴 FFmpeg output:")
                                for line in lines {
                                    self.addLog("  \(line)")
                                }
                            }

                            if let lastLine = lines.last {
                                errorMessage = String(lastLine)
                            }
                        }

                        continuation.resume(returning: (false, errorMessage))
                    }
                } catch {
                    let errorMsg = error.localizedDescription
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
                let elapsed = Int(Date().timeIntervalSince(startTime))
                let minutes = elapsed / 60
                let seconds = elapsed % 60

                self.encodingProgress = "Encoding... Time: \(minutes)m \(seconds)s"
            }
        }
    }

    private func stopEncodingProgress() {
        encodingTimer?.invalidate()
        encodingTimer = nil
        encodingProgress = ""
    }

    private func runCommandWithOutput(path: String, arguments: [String]) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                addLog("􀇾 Process stderr: \(errorOutput)")
            }

            if process.terminationStatus != 0 {
                addLog("􀁡 Process exited with status: \(process.terminationStatus)")
                return nil
            }

            return String(data: outputData, encoding: .utf8)
        } catch {
            addLog("􀁡 Process error: \(error.localizedDescription)")
            return nil
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

        // Terminate current process if one is running
        if let process = currentProcess, process.isRunning {
            process.terminate()
            addLog("􀛶 Terminating current operation...")
        } else {
            addLog("􀊆 Cancelling...")
        }

        // Clear dock badge when cancelled
        clearDockBadge()
    }

    func scanInputFolder(directoryPath: String, outputPath: String = "") async {
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

    func scanForNonMP4Files(directoryPath: String) async {
        DispatchQueue.main.async {
            self.isProcessing = true
            self.logText = ""
            self.scanProgress = "Starting scan..."
            self.shouldCancelScan = false
        }

        addLog("􀊫 Scanning directory for non-MP4 files...")
        addLog("􀈖 Directory: \(directoryPath)")

        guard FileManager.default.fileExists(atPath: directoryPath) else {
            addLog("􀁡 Directory does not exist!")
            DispatchQueue.main.async {
                self.isProcessing = false
                self.scanProgress = ""
            }
            return
        }

        // Skip counting and scan directly with incremental progress
        addLog("􀅴 Scanning files (this may take a while on network shares)...")

        // Perform file scanning in a synchronous context
        let result: ([String], Int, Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: ([], 0, false))
                    return
                }

                let videoExtensions = ["mkv", "mp4", "avi", "mov", "m4v", "flv", "wmv", "webm", "mpeg", "mpg"]
                var nonMP4Files: [String] = []
                var totalVideoFiles = 0
                var filesScanned = 0
                var lastUpdateTime = Date()

                // Configure enumerator to skip hidden files and packages
                let fileManager = FileManager.default
                guard let enumerator = fileManager.enumerator(
                    at: URL(fileURLWithPath: directoryPath),
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    continuation.resume(returning: ([], 0, false))
                    return
                }

                // Recursively scan directory
                for case let fileURL as URL in enumerator {
                    // Check for cancellation more frequently (local copy to avoid actor isolation warning)
                    let shouldCancel = self.shouldCancelScan
                    if shouldCancel {
                        continuation.resume(returning: (nonMP4Files, totalVideoFiles, true))
                        return
                    }

                    // Only process regular files
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                          resourceValues.isRegularFile == true else {
                        continue
                    }

                    filesScanned += 1

                    // Update progress every 50 files or every 0.5 seconds (whichever comes first)
                    let now = Date()
                    if filesScanned % 50 == 0 || now.timeIntervalSince(lastUpdateTime) > 0.5 {
                        lastUpdateTime = now
                        let scannedCount = filesScanned
                        DispatchQueue.main.async {
                            self.scanProgress = "Scanned \(scannedCount) files..."
                        }
                    }

                    let ext = fileURL.pathExtension.lowercased()

                    // Check if it's a video file
                    if videoExtensions.contains(ext) {
                        totalVideoFiles += 1

                        // If it's not an MP4, add to list
                        if ext != "mp4" {
                            nonMP4Files.append(fileURL.path)
                        }
                    }
                }

                continuation.resume(returning: (nonMP4Files, totalVideoFiles, false))
            }
        }

        let (nonMP4Files, totalVideoFiles, wasCancelled) = result

        DispatchQueue.main.async {
            self.scanProgress = ""
        }

        if wasCancelled {
            addLog("􀊆 Scan cancelled by user")
            addLog("􀅴 Partial results: \(totalVideoFiles) video files found, \(nonMP4Files.count) non-MP4")
        } else {
            addLog("􀐱 Scan complete!")
            addLog("􀅴 Total video files found: \(totalVideoFiles)")
            addLog("􀅴 Non-MP4 video files: \(nonMP4Files.count)")
        }

        if nonMP4Files.isEmpty {
            addLog("􀁢 All video files are already MP4 format!")
        } else {
            addLog("\n􀈊 Non-MP4 files:")
            // Sort files using natural (numeric-aware) sorting
            let sortedFiles = nonMP4Files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for filePath in sortedFiles {
                let ext = (filePath as NSString).pathExtension.uppercased()
                addLog("[\(ext)] - \(filePath)")
            }
            addLog("\n􀐱 Total non-MP4 files: \(nonMP4Files.count)")
        }

        DispatchQueue.main.async {
            self.isProcessing = false
            self.shouldCancelScan = false
        }
    }

    func validateMP4Files(directoryPath: String) async {
        DispatchQueue.main.async {
            self.isProcessing = true
            self.logText = ""
            self.scanProgress = "Starting validation..."
            self.shouldCancelScan = false
        }

        addLog("􀊫 Validating MP4 files in directory...")
        addLog("􀈖 Directory: \(directoryPath)")

        guard FileManager.default.fileExists(atPath: directoryPath) else {
            addLog("􀁡 Directory does not exist!")
            DispatchQueue.main.async {
                self.isProcessing = false
                self.scanProgress = ""
            }
            return
        }

        addLog("􀅴 Scanning and validating files (this may take a while on network shares)...")

        // First, collect all MP4 files synchronously
        let (mp4FilePaths, totalMP4Files): ([URL], Int) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fileManager = FileManager.default
                guard let enumerator = fileManager.enumerator(
                    at: URL(fileURLWithPath: directoryPath),
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    continuation.resume(returning: ([], 0))
                    return
                }

                var collectedPaths: [URL] = []
                var filesScanned = 0
                var lastUpdateTime = Date()

                for case let fileURL as URL in enumerator {
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                          resourceValues.isRegularFile == true else {
                        continue
                    }

                    filesScanned += 1

                    // Update progress every 50 files or every 0.5 seconds
                    let now = Date()
                    if filesScanned % 50 == 0 || now.timeIntervalSince(lastUpdateTime) > 0.5 {
                        lastUpdateTime = now
                        let scannedCount = filesScanned
                        DispatchQueue.main.async {
                            self.scanProgress = "Scanned \(scannedCount) files..."
                        }
                    }

                    let ext = fileURL.pathExtension.lowercased()

                    // Only collect MP4 files
                    guard ext == "mp4" else { continue }

                    collectedPaths.append(fileURL)
                }

                continuation.resume(returning: (collectedPaths, collectedPaths.count))
            }
        }

        // Now validate the collected MP4 files asynchronously
        var validFiles: [String] = []
        var invalidFiles: [(path: String, reason: String)] = []

        for (index, fileURL) in mp4FilePaths.enumerated() {
            // Check for cancellation
            if shouldCancelScan {
                break
            }

            // Validate the MP4 file using AVFoundation
            let asset = AVURLAsset(url: fileURL)

            do {
                let isPlayable = try await asset.load(.isPlayable)
                if isPlayable {
                    validFiles.append(fileURL.path)
                } else {
                    invalidFiles.append((path: fileURL.path, reason: "Asset not playable"))
                }
            } catch {
                invalidFiles.append((path: fileURL.path, reason: "Could not load asset: \(error.localizedDescription)"))
            }

            // Update progress
            let scannedCount = index + 1
            DispatchQueue.main.async {
                self.scanProgress = "Validating \(scannedCount)/\(totalMP4Files) files..."
            }
        }

        let wasCancelled = shouldCancelScan

        DispatchQueue.main.async {
            self.scanProgress = ""
        }

        if wasCancelled {
            addLog("􀊆 Validation cancelled by user")
            addLog("􀅴 Partial results: \(totalMP4Files) MP4 files found, \(validFiles.count) valid, \(invalidFiles.count) invalid")
        } else {
            addLog("􀐱 Validation complete!")
            addLog("􀅴 Total MP4 files found: \(totalMP4Files)")
            addLog("􀅴 Valid MP4 files: \(validFiles.count)")
            addLog("􀅴 Invalid MP4 files: \(invalidFiles.count)")
        }

        if invalidFiles.isEmpty {
            addLog("\n􀁢 All MP4 files are valid!")
        } else {
            addLog("\n􀁡 Invalid MP4 files:")
            // Sort files using natural sorting
            let sortedFiles = invalidFiles.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            for (filePath, reason) in sortedFiles {
                addLog("  ✗ \(filePath) - \(reason)")
            }
        }

        DispatchQueue.main.async {
            self.isProcessing = false
            self.shouldCancelScan = false
        }
    }

    // MARK: - Notifications

    private func sendProcessingCompleteNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Processing Complete"
        content.body = "Your video files have been processed successfully."
        content.sound = .default
        content.badge = NSNumber(value: 1)

        let request = UNNotificationRequest(identifier: "processingComplete", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)

        // Set app badge
        DispatchQueue.main.async {
            NSApplication.shared.dockTile.badgeLabel = "1"
        }
    }

    func clearProcessingNotifications() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["processingComplete"])

        // Clear app badge
        DispatchQueue.main.async {
            NSApplication.shared.dockTile.badgeLabel = ""
        }
    }

    // Check for file conflicts for a specific file
    func checkFileForConflicts(
        fileIndex: Int,
        outputPath: String,
        createSubfolders: Bool
    ) {
        guard fileIndex < videoFiles.count else { return }

        let fileInfo = videoFiles[fileIndex]
        let inputFilePath = fileInfo.filePath
        let outputFileName = ((fileInfo.fileName as NSString).deletingPathExtension as NSString).appendingPathExtension("mp4")!

        let outputFilePath: String
        if createSubfolders {
            let folderName = (fileInfo.fileName as NSString).deletingPathExtension
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
            let conflictReason = fileConflicts.joined(separator: " • ")
            DispatchQueue.main.async {
                self.videoFiles[fileIndex].hasConflict = true
                self.videoFiles[fileIndex].conflictReason = conflictReason
            }
        }
    }

    // Check for files that would be replaced/overwritten during processing
    func checkForFileConflicts(
        inputPath: String,
        outputPath: String,
        createSubfolders: Bool
    ) -> Bool {
        var hasConflicts = false

        // Only check files in the queue
        if !videoFiles.isEmpty {
            for (index, _) in videoFiles.enumerated() {
                checkFileForConflicts(fileIndex: index, outputPath: outputPath, createSubfolders: createSubfolders)
                if videoFiles[index].hasConflict {
                    hasConflicts = true
                }
            }
        }

        return hasConflicts
    }
}
