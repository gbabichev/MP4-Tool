//
//  VideoSplitterViewModel.swift
//  MP4 Tool
//
//  Created by George Babichev on 1/26/26.
//

import Foundation
import AppKit
import Combine
import SwiftUI

struct VideoSplitCandidate: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let splitTimeSeconds: TimeInterval
    let splitTimeLabel: String
}

@MainActor
final class VideoSplitterViewModel: ObservableObject {
    @Published var inputFolderPath: String = ""
    @Published var outputFolderPath: String = ""
    @AppStorage("videoSplitterBlackMinDuration") var blackMinDuration: Double = 0.5
    @AppStorage("videoSplitterBlackThresholdSeconds") var blackThresholdSeconds: Double = 180
    @AppStorage("videoSplitterPicThreshold") var picThreshold: Double = 0.85
    @AppStorage("videoSplitterHalfwayScanEnabled") var halfwayScanEnabled: Bool = false
    @AppStorage("videoSplitterHalfwayWindowMinutes") var halfwayWindowMinutes: Double = 6
    @AppStorage("videoSplitterRenameFiles") var renameFiles: Bool = false
    @Published var isScanning = false
    @Published var scanProgress = ""
    @Published var scanAlertText = ""
    @Published var results: [VideoSplitCandidate] = []
    @Published var selectedResultIDs: Set<UUID> = []
    @Published var isSplitting = false
    @Published var splitProgress = ""
    @Published var ffmpegAvailable = false
    @Published var ffmpegMissingMessage = ""
    @Published var isUsingSystemFFmpeg = false

    private var ffmpegPath: String = ""
    private var ffprobePath: String = ""
    private var ffprobeAvailable = false
    private var scanTask: Task<Void, Never>?
    private let processLock = NSLock()
    private nonisolated(unsafe) var currentScanProcess: Process?
    private var scanToken = UUID()

    init() {
        locateFFmpeg()
    }

    var canScan: Bool {
        !inputFolderPath.isEmpty && ffmpegAvailable && !isScanning
    }

    var canSplit: Bool {
        !outputFolderPath.isEmpty && !selectedResultIDs.isEmpty && ffmpegAvailable && !isScanning && !isSplitting
    }
    
    var canCancelScan: Bool {
        isScanning
    }

    var ffmpegStatusLabel: String {
        if ffmpegAvailable {
            return isUsingSystemFFmpeg ? "FFmpeg: System" : "FFmpeg: Bundled"
        }
        return "FFmpeg: Not Available"
    }

    func selectFolder(isInput: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = isInput ? "Select folder containing video files to analyze" : "Select output folder for split files"

        if panel.runModal() == .OK, let url = panel.url {
            if isInput {
                inputFolderPath = url.path
            } else {
                outputFolderPath = url.path
            }
        }
    }

    func scanForSplits() {
        guard canScan else { return }
        clampSettings()
        results = []
        selectedResultIDs = []
        scanProgress = "Preparing scan..."
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
        terminateCurrentScanProcess()
        scanProgress = "Scan canceled."
        isScanning = false
    }

    func splitSelectedFiles() {
        guard canSplit else { return }
        isSplitting = true
        splitProgress = "Preparing splits..."

        Task {
            await runSplit()
        }
    }

    func clampSettings() {
        if blackMinDuration < 0.05 { blackMinDuration = 0.05 }
        if blackThresholdSeconds < 0 { blackThresholdSeconds = 0 }
        if picThreshold < 0 { picThreshold = 0 }
        if picThreshold > 1 { picThreshold = 1 }
        if halfwayWindowMinutes < 1 { halfwayWindowMinutes = 1 }
    }

    private func runScan(token: UUID) async {
        guard ffmpegAvailable else {
            showAlert(title: "FFmpeg Missing", message: ffmpegMissingMessage)
            isScanning = false
            scanProgress = ""
            return
        }
        
        if halfwayScanEnabled && !ffprobeAvailable {
            showAlert(title: "FFprobe Missing", message: "Halfway scan requires ffprobe to read video duration. Please install or bundle ffprobe.")
            isScanning = false
            scanProgress = ""
            return
        }

        let fileManager = FileManager.default
        let files: [String]
        do {
            files = try fileManager.contentsOfDirectory(atPath: inputFolderPath)
        } catch {
            showAlert(title: "Unable to Read Folder", message: error.localizedDescription)
            isScanning = false
            scanProgress = ""
            return
        }

        let videoFiles = files
            .filter { $0.lowercased().hasSuffix(".mp4") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        if videoFiles.isEmpty {
            showAlert(title: "No MP4 Files", message: "No .mp4 files were found in the selected folder.")
            isScanning = false
            scanProgress = ""
            return
        }

        for (index, fileName) in videoFiles.enumerated() {
            if Task.isCancelled || token != scanToken {
                scanProgress = "Scan canceled."
                isScanning = false
                return
            }

            scanProgress = "Analyzing \(index + 1)/\(videoFiles.count): \(fileName)"

            let filePath = (inputFolderPath as NSString).appendingPathComponent(fileName)
            if let splitTime = await detectSplitTime(filePath: filePath) {
                if Task.isCancelled || token != scanToken {
                    scanProgress = "Scan canceled."
                    isScanning = false
                    return
                }
                let timeLabel = formatTime(splitTime)
                let candidate = VideoSplitCandidate(
                    fileName: fileName,
                    filePath: filePath,
                    splitTimeSeconds: splitTime,
                    splitTimeLabel: timeLabel
                )
                results.append(candidate)
            }
        }

        if token != scanToken {
            scanProgress = "Scan canceled."
            isScanning = false
            return
        }

        if results.isEmpty {
            scanProgress = "No split points found."
        } else {
            scanProgress = "Found \(results.count) split point(s)."
            selectedResultIDs = Set(results.map { $0.id })
        }

        if results.count != videoFiles.count {
            scanAlertText = "Split points found for \(results.count) of \(videoFiles.count) files."
        } else {
            scanAlertText = ""
        }

        isScanning = false
    }

    private func runSplit() async {
        guard !outputFolderPath.isEmpty else {
            showAlert(title: "Output Folder Required", message: "Select an output folder to write split files.")
            isSplitting = false
            splitProgress = ""
            return
        }

        let selectedResults = results.filter { selectedResultIDs.contains($0.id) }
        if selectedResults.isEmpty {
            splitProgress = ""
            isSplitting = false
            return
        }

        let sequentialNameMap = buildSequentialNameMap(for: selectedResults)

        for (index, result) in selectedResults.enumerated() {
            if Task.isCancelled { break }
            splitProgress = "Splitting \(index + 1)/\(selectedResults.count): \(result.fileName)"

            let inputFile = result.filePath
            let outputNames = buildOutputNames(for: result, sequentialNameMap: sequentialNameMap)
            let output1 = (outputFolderPath as NSString).appendingPathComponent(outputNames.first)
            let output2 = (outputFolderPath as NSString).appendingPathComponent(outputNames.second)

            let splitTime = result.splitTimeLabel

            let cmd1 = [
                "-ss", "00:00:00",
                "-i", inputFile,
                "-to", splitTime,
                "-c", "copy",
                output1,
                "-y",
                "-loglevel", "quiet"
            ]

            let cmd2 = [
                "-ss", splitTime,
                "-i", inputFile,
                "-c", "copy",
                output2,
                "-y",
                "-loglevel", "quiet"
            ]

            _ = await runProcessCaptureStderr(path: ffmpegPath, arguments: cmd1)
            _ = await runProcessCaptureStderr(path: ffmpegPath, arguments: cmd2)
        }

        splitProgress = "Split complete."
        isSplitting = false
    }

    func outputPreview(for result: VideoSplitCandidate) -> String {
        let orderedResults = orderedResultsForNaming()
        let sequentialNameMap = buildSequentialNameMap(for: orderedResults)

        if renameFiles, !orderedResults.contains(where: { $0.id == result.id }) {
            return "Not selected"
        }

        let names = buildOutputNames(for: result, sequentialNameMap: sequentialNameMap)
        return "\(names.first)  •  \(names.second)"
    }

    private func orderedResultsForNaming() -> [VideoSplitCandidate] {
        let selectedResults = results.filter { selectedResultIDs.contains($0.id) }
        return selectedResults.isEmpty ? results : selectedResults
    }

    private func buildSequentialNameMap(for orderedResults: [VideoSplitCandidate]) -> [UUID: (first: String, second: String)]? {
        guard renameFiles, let first = orderedResults.first else {
            return nil
        }

        let baseName = (first.fileName as NSString).deletingPathExtension
        print("VideoSplitter rename base: \(baseName)")
        guard let pattern = episodePattern(from: baseName) else {
            print("VideoSplitter rename pattern: <nil>")
            return nil
        }

        let ext = (first.fileName as NSString).pathExtension.isEmpty ? "mp4" : (first.fileName as NSString).pathExtension
        print("VideoSplitter rename pattern: prefix=\(pattern.prefix) start=\(pattern.start) pad=\(pattern.padLength) suffix=\(pattern.suffix) ext=\(ext)")
        var currentNumber = pattern.start
        var map: [UUID: (first: String, second: String)] = [:]

        for result in orderedResults {
            let firstNum = formatEpisodeNumber(currentNumber, padLength: pattern.padLength)
            let secondNum = formatEpisodeNumber(currentNumber + 1, padLength: pattern.padLength)
            let firstName = "\(pattern.prefix)\(firstNum)\(pattern.suffix).\(ext)"
            let secondName = "\(pattern.prefix)\(secondNum)\(pattern.suffix).\(ext)"
            print("VideoSplitter rename: \(result.fileName) -> \(firstName), \(secondName)")
            map[result.id] = (firstName, secondName)
            currentNumber += 2
        }

        return map
    }

    private func buildOutputNames(
        for result: VideoSplitCandidate,
        sequentialNameMap: [UUID: (first: String, second: String)]?
    ) -> (first: String, second: String) {
        if let sequentialNameMap, let mapped = sequentialNameMap[result.id] {
            return mapped
        }

        let fileName = result.fileName as NSString
        let baseName = fileName.deletingPathExtension
        let extensionName = fileName.pathExtension.isEmpty ? "mp4" : fileName.pathExtension

        if renameFiles, let pattern = episodePattern(from: baseName) {
            let firstNum = formatEpisodeNumber(pattern.start, padLength: pattern.padLength)
            let secondNum = formatEpisodeNumber(pattern.start + 1, padLength: pattern.padLength)
            let firstName = "\(pattern.prefix)\(firstNum)\(pattern.suffix).\(extensionName)"
            let secondName = "\(pattern.prefix)\(secondNum)\(pattern.suffix).\(extensionName)"
            return (firstName, secondName)
        }

        return ("\(baseName)_part1.\(extensionName)", "\(baseName)_part2.\(extensionName)")
    }

    private func episodePattern(from name: String) -> EpisodePattern? {
        if let rangePattern = parseEpisodeRange(from: name) {
            print("VideoSplitter parse range: \(name) -> prefix=\(rangePattern.prefix) first=\(rangePattern.first) second=\(rangePattern.second) pad=\(rangePattern.padLength) suffix=\(rangePattern.suffix)")
            return EpisodePattern(
                prefix: rangePattern.prefix,
                start: rangePattern.first,
                padLength: rangePattern.padLength,
                suffix: rangePattern.suffix
            )
        }

        if let singlePattern = parseSingleEpisode(from: name) {
            print("VideoSplitter parse single: \(name) -> prefix=\(singlePattern.prefix) number=\(singlePattern.number) pad=\(singlePattern.padLength) suffix=\(singlePattern.suffix)")
            return EpisodePattern(
                prefix: singlePattern.prefix,
                start: singlePattern.number,
                padLength: singlePattern.padLength,
                suffix: singlePattern.suffix
            )
        }

        print("VideoSplitter parse failed: \(name)")
        return nil
    }

    private func parseEpisodeRange(from name: String) -> (prefix: String, first: Int, second: Int, padLength: Int, suffix: String)? {
        let patterns = [
            "^(.*[Ee])(\\d+)[-_]\\s*(?:[Ee])?(\\d+)(\\D*)$",
            "^(.*)(\\d+)[-_]\\s*(?:[Ee])?(\\d+)(\\D*)$"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }

            let range = NSRange(name.startIndex..., in: name)
            guard let match = regex.firstMatch(in: name, options: [], range: range),
                  match.numberOfRanges >= 5,
                  let prefixRange = Range(match.range(at: 1), in: name),
                  let firstRange = Range(match.range(at: 2), in: name),
                  let secondRange = Range(match.range(at: 3), in: name),
                  let suffixRange = Range(match.range(at: 4), in: name)
            else {
                continue
            }

            let prefix = String(name[prefixRange])
            let firstString = String(name[firstRange])
            let secondString = String(name[secondRange])
            let suffix = String(name[suffixRange])

            guard let firstNumber = Int(firstString), let secondNumber = Int(secondString) else {
                continue
            }

            let padLength = max(firstString.count, secondString.count)
            return (prefix, firstNumber, secondNumber, padLength, suffix)
        }

        return nil
    }

    private func parseSingleEpisode(from name: String) -> (prefix: String, number: Int, padLength: Int, suffix: String)? {
        let patterns = [
            "^(.*[Ee])(\\d+)(\\D*)$",
            "^(.*)(\\d+)(\\D*)$"
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }

            let range = NSRange(name.startIndex..., in: name)
            guard let match = regex.firstMatch(in: name, options: [], range: range),
                  match.numberOfRanges >= 4,
                  let prefixRange = Range(match.range(at: 1), in: name),
                  let numberRange = Range(match.range(at: 2), in: name),
                  let suffixRange = Range(match.range(at: 3), in: name)
            else {
                continue
            }

            let prefix = String(name[prefixRange])
            let numberString = String(name[numberRange])
            let suffix = String(name[suffixRange])

            guard let number = Int(numberString) else {
                continue
            }

            let padLength = numberString.count
            return (prefix, number, padLength, suffix)
        }

        return nil
    }

    private func formatEpisodeNumber(_ number: Int, padLength: Int) -> String {
        if number < 10 {
            return String(format: "%0*d", padLength, number)
        }
        return String(number)
    }


    private func detectSplitTime(filePath: String) async -> TimeInterval? {
        let minDuration = String(format: "%.2f", blackMinDuration)
        let picThresholdValue = String(format: "%.2f", picThreshold)

        var offsetSeconds: TimeInterval = 0
        var arguments = [
            "-hide_banner",
            "-i", filePath,
            "-vf", "blackdetect=d=\(minDuration):pic_th=\(picThresholdValue)",
            "-an",
            "-f", "null",
            "-"
        ]

        if halfwayScanEnabled {
            if let duration = await getDuration(filePath: filePath), duration > 0 {
                let half = duration / 2
                let windowSeconds = max(60, halfwayWindowMinutes * 60)
                let start = max(0, half - (windowSeconds / 2))
                offsetSeconds = start
                arguments = [
                    "-hide_banner",
                    "-ss", formatTime(start),
                    "-t", formatTime(windowSeconds),
                    "-i", filePath,
                    "-vf", "blackdetect=d=\(minDuration):pic_th=\(picThresholdValue)",
                    "-an",
                    "-f", "null",
                    "-"
                ]
            } else {
                return nil
            }
        }

        guard let stderrOutput = await runProcessCaptureStderr(path: ffmpegPath, arguments: arguments) else {
            return nil
        }

        let blackTimes = parseBlackStartTimes(from: stderrOutput)
        let adjustedTimes = blackTimes.map { $0 + offsetSeconds }
        return adjustedTimes.first { $0 > blackThresholdSeconds }
    }

    private func parseBlackStartTimes(from output: String) -> [TimeInterval] {
        let pattern = "black_start:([0-9]+\\.?[0-9]*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: range)

        return matches.compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: output) else {
                return nil
            }
            return Double(String(output[range]))
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remaining = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remaining)
    }

    private func runProcessCaptureStderr(path: String, arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                let errorPipe = Pipe()
                let outputPipe = Pipe()
                process.standardError = errorPipe
                process.standardOutput = outputPipe

                do {
                    self.processLock.lock()
                    self.currentScanProcess = process
                    self.processLock.unlock()

                    try process.run()
                    process.waitUntilExit()

                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorOutput = String(data: errorData, encoding: .utf8)

                    self.processLock.lock()
                    if self.currentScanProcess === process {
                        self.currentScanProcess = nil
                    }
                    self.processLock.unlock()

                    if process.terminationStatus != 0 {
                        continuation.resume(returning: nil)
                        return
                    }

                    continuation.resume(returning: errorOutput)
                } catch {
                    self.processLock.lock()
                    if self.currentScanProcess === process {
                        self.currentScanProcess = nil
                    }
                    self.processLock.unlock()
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func getDuration(filePath: String) async -> TimeInterval? {
        let arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            filePath
        ]

        guard let output = await runProcessCaptureStdout(path: ffprobePath, arguments: arguments) else {
            return nil
        }

        return Double(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func runProcessCaptureStdout(path: String, arguments: [String]) async -> String? {
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
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        continuation.resume(returning: nil)
                        return
                    }

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func terminateCurrentScanProcess() {
        processLock.lock()
        let process = currentScanProcess
        processLock.unlock()

        process?.terminate()
    }

    private func locateFFmpeg() {
        var bundledPath = ""
        var hasBundled = false

        if let ffmpegURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "bin") {
            bundledPath = ffmpegURL.path
            hasBundled = FileManager.default.fileExists(atPath: bundledPath)
        } else if let ffmpegURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) {
            bundledPath = ffmpegURL.path
            hasBundled = FileManager.default.fileExists(atPath: bundledPath)
        } else {
            let resourcePath = Bundle.main.resourcePath ?? ""
            bundledPath = resourcePath + "/bin/ffmpeg"
            hasBundled = FileManager.default.fileExists(atPath: bundledPath)
        }

        if hasBundled {
            ffmpegPath = bundledPath
            ffmpegAvailable = true
            isUsingSystemFFmpeg = false
            ffprobePath = findBundledFFprobe() ?? ""
            ffprobeAvailable = !ffprobePath.isEmpty
            return
        }

        if let systemFFmpeg = Self.findInPath(command: "ffmpeg") {
            ffmpegPath = systemFFmpeg
            ffmpegAvailable = true
            isUsingSystemFFmpeg = true
            ffprobePath = Self.findInPath(command: "ffprobe") ?? ""
            ffprobeAvailable = !ffprobePath.isEmpty
            return
        }

        ffmpegAvailable = false
        ffmpegMissingMessage = "Missing required tool: ffmpeg. Please install ffmpeg or bundle it with the app."
    }

    private func findBundledFFprobe() -> String? {
        if let ffprobeURL = Bundle.main.url(forResource: "ffprobe", withExtension: nil, subdirectory: "bin") {
            let path = ffprobeURL.path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }

        if let ffprobeURL = Bundle.main.url(forResource: "ffprobe", withExtension: nil) {
            let path = ffprobeURL.path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }

        let resourcePath = Bundle.main.resourcePath ?? ""
        let fallback = resourcePath + "/bin/ffprobe"
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

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
    private struct EpisodePattern {
        let prefix: String
        let start: Int
        let padLength: Int
        let suffix: String
    }
