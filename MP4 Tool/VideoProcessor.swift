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

class VideoProcessor: ObservableObject {
    @Published var isProcessing = false
    @Published var currentFile = ""
    @Published var progress: Double = 0.0
    @Published var totalFiles = 0
    @Published var currentFileIndex = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var originalSize: Int64 = 0
    @Published var newSize: Int64 = 0
    @Published var logs: [String] = []
    @Published var scanProgress: String = ""

    private var startTime: Date?
    private var timer: Timer?
    private var shouldCancelScan = false

    private let ffmpegPath: String
    private let ffprobePath: String

    init() {
        // Try multiple methods to locate bundled binaries
        if let ffmpegURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "bin"),
           let ffprobeURL = Bundle.main.url(forResource: "ffprobe", withExtension: nil, subdirectory: "bin") {
            self.ffmpegPath = ffmpegURL.path
            self.ffprobePath = ffprobeURL.path
        } else if let ffmpegURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
                  let ffprobeURL = Bundle.main.url(forResource: "ffprobe", withExtension: nil) {
            // If bin folder was flattened
            self.ffmpegPath = ffmpegURL.path
            self.ffprobePath = ffprobeURL.path
        } else {
            // Fallback to resource path
            let resourcePath = Bundle.main.resourcePath ?? ""
            self.ffmpegPath = resourcePath + "/bin/ffmpeg"
            self.ffprobePath = resourcePath + "/bin/ffprobe"
        }

        addLog("ℹ️ Initialized with ffmpeg at: \(ffmpegPath)")
        addLog("ℹ️ Initialized with ffprobe at: \(ffprobePath)")

        // Verify files exist
        if !FileManager.default.fileExists(atPath: ffmpegPath) {
            addLog("⚠️ WARNING: ffmpeg binary not found at expected path!")
            addLog("ℹ️ Bundle resource path: \(Bundle.main.resourcePath ?? "unknown")")
        }
        if !FileManager.default.fileExists(atPath: ffprobePath) {
            addLog("⚠️ WARNING: ffprobe binary not found at expected path!")
        }
    }

    func addLog(_ message: String) {
        DispatchQueue.main.async {
            self.logs.append(message)
            print(message)
        }
    }

    func processFolder(inputPath: String, outputPath: String, mode: ProcessingMode, createSubfolders: Bool, deleteOriginal: Bool = true) async {
        DispatchQueue.main.async {
            self.isProcessing = true
            self.logs.removeAll()
            self.currentFileIndex = 0
            self.progress = 0
        }

        addLog("▶️ Starting processing...")
        addLog("📂 Input Directory: \(inputPath)")
        addLog("📂 Output Directory: \(outputPath)")
        addLog("⚙️ Mode: \(mode.rawValue)")
        addLog("📁 Create Subfolders: \(createSubfolders)")
        addLog("🗑️ Delete Original: \(deleteOriginal)")

        // Verify directories exist
        guard FileManager.default.fileExists(atPath: inputPath) else {
            addLog("❌ Input directory does not exist!")
            DispatchQueue.main.async { self.isProcessing = false }
            return
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            addLog("❌ Output directory does not exist!")
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

            addLog("📊 Found \(files.count) files to process")

            for (index, file) in files.enumerated() {
                DispatchQueue.main.async {
                    self.currentFileIndex = index + 1
                    self.currentFile = file
                }

                addLog("\n🎬 File \(index + 1)/\(files.count)")
                addLog("ℹ️ Processing: \(file)")

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
                let success = await convertToMP4(inputFile: inputFilePath, tempFile: tempOutputFile, mode: mode)
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

                    addLog("✅ Done processing")
                    addLog("ℹ️ Moved file. Old Size: \(inputSizeMB)MB New Size: \(outputSizeMB)MB")

                    let duration = fileEndTime.timeIntervalSince(fileStartTime)
                    let minutes = Int(duration) / 60
                    let seconds = Int(duration) % 60
                    addLog("ℹ️ Completed in \(minutes)m \(seconds)s")

                    // Delete original file if requested
                    if deleteOriginal {
                        try? FileManager.default.removeItem(atPath: inputFilePath)
                        addLog("🗑️ Deleted original file")
                    } else {
                        addLog("ℹ️ Kept original file")
                    }
                } else {
                    addLog("❌ Error processing video. Moving on...")
                    try? FileManager.default.removeItem(atPath: tempOutputFile)
                }

                DispatchQueue.main.async {
                    self.progress = Double(index + 1) / Double(files.count)
                }
            }

            addLog("\n🚀 All files processed!")

        } catch {
            addLog("❌ Error: \(error.localizedDescription)")
        }

        DispatchQueue.main.async {
            self.isProcessing = false
        }
    }

    private func convertToMP4(inputFile: String, tempFile: String, mode: ProcessingMode) async -> Bool {
        // Probe streams
        guard let audioStreams = await probeStreams(inputFile: inputFile, selectStreams: "a"),
              let videoStreams = await probeStreams(inputFile: inputFile, selectStreams: nil),
              let subtitleStreams = await probeStreams(inputFile: inputFile, selectStreams: "s") else {
            addLog("❌ Failed to probe streams")
            return false
        }

        // Get English audio indices
        let audioIndices = getEnglishAudioIndices(audioStreams: audioStreams)
        if audioIndices.isEmpty {
            addLog("❌ No English audio found. Skipping.")
            return false
        }

        // Get video codec
        let videoCodec = getVideoCodec(videoStreams: videoStreams)

        // Check for AV1 in remux mode
        if mode == .remux && videoCodec == "av1" {
            addLog("❌ AV1 codec detected. Please use encode mode.")
            return false
        }

        // Get subtitle streams
        let validSubtitles = getSubtitleStreams(subtitleStreams: subtitleStreams)

        // Build ffmpeg command
        let cmd = buildFFmpegCommand(
            inputFile: inputFile,
            tempFile: tempFile,
            mode: mode,
            videoCodec: videoCodec,
            audioIndices: audioIndices,
            subtitleStreams: validSubtitles
        )

        addLog("ℹ️ Running in \(mode.rawValue) mode")

        // Start timer
        DispatchQueue.main.async {
            self.startTime = Date()
            self.originalSize = (try? FileManager.default.attributesOfItem(atPath: inputFile)[.size] as? Int64) ?? 0
            self.newSize = 0

            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if let start = self.startTime {
                    self.elapsedTime = Date().timeIntervalSince(start)
                }
                self.newSize = (try? FileManager.default.attributesOfItem(atPath: tempFile)[.size] as? Int64) ?? 0
            }
        }

        // Run ffmpeg
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

        addLog("🔍 Debug: Running ffprobe at: \(ffprobePath)")
        addLog("🔍 Debug: File exists: \(FileManager.default.fileExists(atPath: ffprobePath))")
        addLog("🔍 Debug: Arguments: \(arguments)")

        guard let output = await runCommandWithOutput(path: ffprobePath, arguments: arguments) else {
            addLog("❌ Debug: runCommandWithOutput returned nil")
            return nil
        }

        addLog("🔍 Debug: Got output, length: \(output.count) chars")

        guard let data = output.data(using: .utf8),
              let result = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else {
            addLog("❌ Debug: Failed to decode JSON. Output: \(output.prefix(500))")
            return nil
        }

        return result
    }

    private func getEnglishAudioIndices(audioStreams: FFProbeOutput) -> [Int] {
        return audioStreams.streams.filter { stream in
            let language = stream.tags?["language"] ?? "und"
            return language == "eng" || language == "und"
        }.map { $0.index }
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
        videoCodec: String?,
        audioIndices: [Int],
        subtitleStreams: [(index: Int, codec: String, language: String)]
    ) -> [String] {
        var cmd: [String] = []

        if mode == .encode {
            cmd = [
                "-i", inputFile, "-y",
                "-c:v", "libx265", "-x265-params", "log-level=0", "-preset", "fast", "-crf", "23",
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

        // Map English audio
        for idx in audioIndices {
            cmd.append(contentsOf: ["-map", "0:\(idx)"])
            cmd.append(contentsOf: ["-metadata:s:a:0", "language=eng"])
        }

        // Map first subtitle
        if let sub = subtitleStreams.first {
            cmd.append(contentsOf: ["-map", "0:\(sub.index)", "-c:s", "mov_text", "-metadata:s:s:0", "language=\(sub.language)"])
        }

        cmd.append(tempFile)

        return cmd
    }

    private func runCommand(arguments: [String]) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            addLog("❌ Process error: \(error.localizedDescription)")
            return false
        }
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
                addLog("⚠️ Process stderr: \(errorOutput)")
            }

            if process.terminationStatus != 0 {
                addLog("❌ Process exited with status: \(process.terminationStatus)")
                return nil
            }

            return String(data: outputData, encoding: .utf8)
        } catch {
            addLog("❌ Process error: \(error.localizedDescription)")
            return nil
        }
    }

    func cancelScan() {
        shouldCancelScan = true
        addLog("⏸️ Cancelling scan...")
    }

    func scanForNonMP4Files(directoryPath: String) async {
        DispatchQueue.main.async {
            self.isProcessing = true
            self.logs.removeAll()
            self.scanProgress = "Starting scan..."
            self.shouldCancelScan = false
        }

        addLog("🔍 Scanning directory for non-MP4 files...")
        addLog("📂 Directory: \(directoryPath)")

        guard FileManager.default.fileExists(atPath: directoryPath) else {
            addLog("❌ Directory does not exist!")
            DispatchQueue.main.async {
                self.isProcessing = false
                self.scanProgress = ""
            }
            return
        }

        // Skip counting and scan directly with incremental progress
        addLog("ℹ️ Scanning files (this may take a while on network shares)...")

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
                    // Check for cancellation more frequently
                    if self.shouldCancelScan {
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
            addLog("⏸️ Scan cancelled by user")
            addLog("ℹ️ Partial results: \(totalVideoFiles) video files found, \(nonMP4Files.count) non-MP4")
        } else {
            addLog("📊 Scan complete!")
            addLog("ℹ️ Total video files found: \(totalVideoFiles)")
            addLog("ℹ️ Non-MP4 video files: \(nonMP4Files.count)")
        }

        if nonMP4Files.isEmpty {
            addLog("✅ All video files are already MP4 format!")
        } else {
            addLog("\n📝 Non-MP4 files:")
            for (index, filePath) in nonMP4Files.enumerated() {
                let fileName = (filePath as NSString).lastPathComponent
                let ext = (fileName as NSString).pathExtension.uppercased()
                addLog("  \(index + 1). [\(ext)] \(fileName)")
                addLog("     Path: \(filePath)")
            }
        }

        DispatchQueue.main.async {
            self.isProcessing = false
            self.shouldCancelScan = false
        }
    }
}
