//
//  VideoProcessor.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import Foundation
import Combine

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
    case encode = "encode"
    case remux = "remux"

    var description: String {
        switch self {
        case .encode: return "Encode (H.265)"
        case .remux: return "Remux (Copy)"
        }
    }
}

enum ProcessingStatus {
    case pending
    case processing
    case completed
}

struct VideoFileInfo: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let fileExtension: String
    let fileSizeMB: Int
    var status: ProcessingStatus = .pending
    var processingTimeSeconds: Int = 0
}

class VideoProcessor: ObservableObject {
    @Published var isProcessing = false
    @Published var currentFile = ""
    @Published var progress: Double = 0.0
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

    func processFolder(inputPath: String, outputPath: String, mode: ProcessingMode, crfValue: Int = 23, createSubfolders: Bool, deleteOriginal: Bool = true, keepEnglishAudioOnly: Bool) async {
        DispatchQueue.main.async {
            self.isProcessing = true
            self.logText = ""
            self.currentFileIndex = 0
            self.progress = 0
            self.shouldCancelProcessing = false
        }

        addLog("􀊄 Starting processing...")
        addLog("􀈖 Input Directory: \(inputPath)")
        addLog("􀈖 Output Directory: \(outputPath)")
        addLog("􀣋 Mode: \(mode.rawValue)")
        if mode == .encode {
            addLog("􀏃 CRF: \(crfValue)")
        }
        addLog("􀈕 Create Subfolders: \(createSubfolders)")
        addLog("􀈑 Delete Original: \(deleteOriginal)")
        addLog("􀀁 Keep English Audio Only: \(keepEnglishAudioOnly)")

        // Verify directories exist
        guard FileManager.default.fileExists(atPath: inputPath) else {
            addLog("􀁡 Input directory does not exist!")
            DispatchQueue.main.async { self.isProcessing = false }
            return
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            addLog("􀁡 Output directory does not exist!")
            DispatchQueue.main.async { self.isProcessing = false }
            return
        }

        // Get files to process
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

            DispatchQueue.main.async {
                self.totalFiles = files.count
            }

            addLog("􀐱 Found \(files.count) files to process")

            for (index, file) in files.enumerated() {
                // Check for cancellation
                if shouldCancelProcessing {
                    addLog("􀛶 Processing cancelled by user")
                    break
                }

                // Mark file as processing
                DispatchQueue.main.async {
                    self.currentFileIndex = index + 1
                    self.currentFile = file
                    if index < self.videoFiles.count {
                        self.videoFiles[index].status = .processing
                    }
                }

                addLog("\n􀎶 File \(index + 1)/\(files.count)")
                addLog("􀅴 Processing: \(file)")

                let inputFilePath = (inputPath as NSString).appendingPathComponent(file)
                let outputFileName = ((file as NSString).deletingPathExtension as NSString).appendingPathExtension("mp4")!

                let outputFilePath: String
                if createSubfolders {
                    let folderName = (file as NSString).deletingPathExtension
                    let outputDir = (outputPath as NSString).appendingPathComponent(folderName)
                    outputFilePath = (outputDir as NSString).appendingPathComponent(outputFileName)

                    try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
                } else {
                    outputFilePath = (outputPath as NSString).appendingPathComponent(outputFileName)
                }

                let tempOutputFile = NSTemporaryDirectory() + UUID().uuidString + ".mp4"

                // Process the video
                let fileStartTime = Date()
                let success = await convertToMP4(
                    inputFile: inputFilePath,
                    tempFile: tempOutputFile,
                    mode: mode,
                    crfValue: crfValue,
                    keepEnglishAudioOnly: keepEnglishAudioOnly
                )
                let fileEndTime = Date()

                if success {
                    // Get file sizes
                    let inputSize = try? FileManager.default.attributesOfItem(atPath: inputFilePath)[.size] as? Int64 ?? 0
                    let outputSize = try? FileManager.default.attributesOfItem(atPath: tempOutputFile)[.size] as? Int64 ?? 0

                    let inputSizeMB = (inputSize ?? 0) / (1024 * 1024)
                    let outputSizeMB = (outputSize ?? 0) / (1024 * 1024)

                    // Move to final location
                    try? FileManager.default.removeItem(atPath: outputFilePath)
                    try? FileManager.default.moveItem(atPath: tempOutputFile, toPath: outputFilePath)

                    addLog("􀁢 Done processing")
                    addLog("􀅴 Moved file. Old Size: \(inputSizeMB)MB New Size: \(outputSizeMB)MB")

                    let duration = fileEndTime.timeIntervalSince(fileStartTime)
                    let minutes = Int(duration) / 60
                    let seconds = Int(duration) % 60
                    addLog("􀅴 Completed in \(minutes)m \(seconds)s")

                    // Delete original file if requested
                    if deleteOriginal {
                        try? FileManager.default.removeItem(atPath: inputFilePath)
                        addLog("􀈑 Deleted original file")
                    } else {
                        addLog("􀅴 Kept original file")
                    }

                    // Mark file as completed with processing time
                    DispatchQueue.main.async {
                        if index < self.videoFiles.count {
                            self.videoFiles[index].status = .completed
                            self.videoFiles[index].processingTimeSeconds = Int(duration)
                        }
                    }
                } else {
                    addLog("􀁡 Error processing video. Moving on...")
                    try? FileManager.default.removeItem(atPath: tempOutputFile)
                }

                DispatchQueue.main.async {
                    self.progress = Double(index + 1) / Double(files.count)
                }
            }

            addLog("\n􀋚 All files processed!")

        } catch {
            addLog("􀁡 Error: \(error.localizedDescription)")
        }

        DispatchQueue.main.async {
            self.isProcessing = false
            self.shouldCancelProcessing = false
        }
    }

    private func convertToMP4(inputFile: String, tempFile: String, mode: ProcessingMode, crfValue: Int = 23, keepEnglishAudioOnly: Bool) async -> Bool {
        // Probe streams
        guard let audioStreams = await probeStreams(inputFile: inputFile, selectStreams: "a"),
              let videoStreams = await probeStreams(inputFile: inputFile, selectStreams: nil),
              let subtitleStreams = await probeStreams(inputFile: inputFile, selectStreams: "s") else {
            addLog("􀁡 Failed to probe streams")
            return false
        }

        // Determine audio stream mappings
        let audioMappings = getAudioMappings(audioStreams: audioStreams, keepEnglishOnly: keepEnglishAudioOnly)
        if audioMappings.isEmpty {
            let message = keepEnglishAudioOnly
                ? "􀁡 No English audio found. Skipping."
                : "􀁡 No audio tracks found. Skipping."
            addLog(message)
            return false
        }

        // Get video codec
        let videoCodec = getVideoCodec(videoStreams: videoStreams)

        // Check for AV1 in remux mode
        if mode == .remux && videoCodec == "av1" {
            addLog("􀁡 AV1 codec detected. Please use encode mode.")
            return false
        }

        // Get subtitle streams
        let validSubtitles = getSubtitleStreams(subtitleStreams: subtitleStreams)

        // Build ffmpeg command
        let cmd = buildFFmpegCommand(
            inputFile: inputFile,
            tempFile: tempFile,
            mode: mode,
            crfValue: crfValue,
            videoCodec: videoCodec,
            audioMappings: audioMappings,
            subtitleStreams: validSubtitles
        )

        addLog("􀅴 Running in \(mode.rawValue) mode")
        if mode == .encode {
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
        let success = await runCommand(arguments: cmd)

        // Stop timer
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.timer = nil
        }

        return success
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

    private func getSubtitleStreams(subtitleStreams: FFProbeOutput) -> [(index: Int, codec: String, language: String)] {
        let validCodecs = ["subrip", "ass", "ssa", "mov_text"]

        return subtitleStreams.streams.compactMap { stream in
            guard let codec = stream.codecName,
                  validCodecs.contains(codec),
                  let language = stream.tags?["language"],
                  language == "eng" || language == "und" else {
                return nil
            }
            return (stream.index, codec, language)
        }
    }

    private func buildFFmpegCommand(
        inputFile: String,
        tempFile: String,
        mode: ProcessingMode,
        crfValue: Int = 23,
        videoCodec: String?,
        audioMappings: [(index: Int, language: String?)],
        subtitleStreams: [(index: Int, codec: String, language: String)]
    ) -> [String] {
        var cmd: [String] = []

        if mode == .encode {
            cmd = [
                "-i", inputFile, "-y",
                "-c:v", "libx265", "-x265-params", "log-level=0", "-preset", "fast", "-crf", "\(crfValue)",
                "-c:a", "aac", "-b:a", "192k", "-channel_layout", "5.1",
                "-map", "0:v:0", "-map_metadata", "-1",
                "-tag:v", "hvc1", "-movflags", "+faststart", "-loglevel", "quiet"
            ]
        } else {
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

        // Map first subtitle
        if let sub = subtitleStreams.first {
            cmd.append(contentsOf: ["-map", "0:\(sub.index)", "-c:s", "mov_text", "-metadata:s:s:0", "language=\(sub.language)"])
        }

        cmd.append(tempFile)

        return cmd
    }

    private func runCommand(arguments: [String]) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: false)
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.ffmpegPath)
                process.arguments = arguments

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

                    let success = process.terminationStatus == 0
                    continuation.resume(returning: success)
                } catch {
                    let errorMsg = error.localizedDescription
                    DispatchQueue.main.async {
                        self.stopEncodingProgress()
                        self.currentProcess = nil
                        self.addLog("􀁡 Process error: \(errorMsg)")
                    }
                    continuation.resume(returning: false)
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

                let outputSizeMB = self.newSize / (1024 * 1024)

                self.encodingProgress = "Encoding... Time: \(minutes)m \(seconds)s • Output: \(outputSizeMB)MB"
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
    }

    func scanInputFolder(directoryPath: String) async {
        DispatchQueue.main.async {
            self.isProcessing = true
            self.scanProgress = "Scanning for video files..."
            self.videoFiles = []
        }

        let videoFormats = ["mkv", "mp4", "avi"]
        let wordsToIgnore = ["sample", "SAMPLE", "Sample", ".DS_Store"]

        do {
            let allFiles = try FileManager.default.contentsOfDirectory(atPath: directoryPath)
            let files = allFiles
                .filter { file in
                    let ext = (file as NSString).pathExtension.lowercased()
                    return videoFormats.contains(ext) && !wordsToIgnore.contains { file.contains($0) }
                }
                .sorted()

            var videoFileInfos: [VideoFileInfo] = []

            for file in files {
                let filePath = (directoryPath as NSString).appendingPathComponent(file)
                let ext = (file as NSString).pathExtension.uppercased()

                if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
                   let fileSize = attributes[.size] as? Int64 {
                    let sizeMB = Int(fileSize / (1024 * 1024))

                    videoFileInfos.append(VideoFileInfo(
                        fileName: file,
                        filePath: filePath,
                        fileExtension: ext,
                        fileSizeMB: sizeMB
                    ))
                }
            }

            DispatchQueue.main.async {
                self.videoFiles = videoFileInfos
                self.totalFiles = videoFileInfos.count
                self.scanProgress = ""
                self.isProcessing = false
            }

            addLog("􀅴 Found \(videoFileInfos.count) video files to process")
        } catch {
            addLog("􀁡 Error scanning folder: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.scanProgress = ""
                self.isProcessing = false
            }
        }
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
            for filePath in nonMP4Files {
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
}
