//
//  ProcessingHistoryStore.swift
//  MP4 Tool
//

import Foundation
import Combine

struct ProcessingHistoryDetails: Codable, Equatable {
    let runID: String
    let inputPath: String
    let outputPath: String
    let mode: String
    let sourceDurationSeconds: TimeInterval?
    let encodingRuntimeSeconds: TimeInterval?
    let encodeVideo: Bool
    let encodeAudio: Bool
    let crfValue: Int?
    let resolution: String?
    let encoderPreset: String?
    let createSubfolders: Bool
    let automaticRename: Bool
    let deleteOriginal: Bool
    let keepEnglishAudioOnly: Bool
    let keepAllEnglishAudioTracks: Bool
    let keepEnglishSubtitlesOnly: Bool
    let keepAllEnglishSubtitleTracks: Bool
    let ffmpegSource: String
    let ffmpegVersion: String
    let appVersion: String
    let appBuild: String
    let ffmpegCommands: [String]
}

struct ProcessingHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let fileName: String
    let originalBytes: Int64
    let outputBytes: Int64
    let startedAt: Date?
    let processedAt: Date
    let runtimeSeconds: TimeInterval?
    let details: ProcessingHistoryDetails?

    var savedBytes: Int64 {
        originalBytes - outputBytes
    }

    var savedPercentage: Double {
        guard originalBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(originalBytes) * 100
    }

    var encodeSpeedMultiple: Double? {
        guard let details,
              details.encodeVideo,
              !details.mode.localizedCaseInsensitiveContains("remux"),
              let sourceDuration = details.sourceDurationSeconds,
              let encodingRuntime = details.encodingRuntimeSeconds,
              sourceDuration > 0,
              encodingRuntime > 0 else {
            return nil
        }
        return sourceDuration / encodingRuntime
    }
}

@MainActor
final class ProcessingHistoryStore: ObservableObject {
    static let shared = ProcessingHistoryStore()

    @Published private(set) var entries: [ProcessingHistoryEntry] = []
    @Published private(set) var errorMessage: String?

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    @discardableResult
    func record(
        fileName: String,
        originalBytes: Int64,
        outputBytes: Int64,
        startedAt: Date,
        processedAt: Date,
        runtimeSeconds: TimeInterval,
        details: ProcessingHistoryDetails
    ) -> Bool {
        let entry = ProcessingHistoryEntry(
            id: UUID(),
            fileName: fileName,
            originalBytes: originalBytes,
            outputBytes: outputBytes,
            startedAt: startedAt,
            processedAt: processedAt,
            runtimeSeconds: runtimeSeconds,
            details: details
        )
        entries.insert(entry, at: 0)
        return persist()
    }

    func clear() {
        do {
            if fileManager.fileExists(atPath: historyFileURL.path) {
                try fileManager.removeItem(at: historyFileURL)
            }
            entries = []
            errorMessage = nil
        } catch {
            errorMessage = "Could not clear processing history: \(error.localizedDescription)"
        }
    }

    func remove(ids: Set<ProcessingHistoryEntry.ID>) {
        guard !ids.isEmpty else { return }

        let previousEntries = entries
        entries.removeAll { ids.contains($0.id) }

        guard persist() else {
            entries = previousEntries
            return
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: historyFileURL.path) else { return }

        do {
            let data = try Data(contentsOf: historyFileURL)
            entries = try decoder.decode([ProcessingHistoryEntry].self, from: data)
                .sorted { $0.processedAt > $1.processedAt }
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = "Could not read processing history: \(error.localizedDescription)"
        }
    }

    private func persist() -> Bool {
        do {
            try fileManager.createDirectory(
                at: historyDirectoryURL,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(entries)
            try data.write(to: historyFileURL, options: .atomic)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Could not save processing history: \(error.localizedDescription)"
            return false
        }
    }

    private var historyDirectoryURL: URL {
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        return applicationSupportURL.appendingPathComponent("MP4 Tool", isDirectory: true)
    }

    private var historyFileURL: URL {
        historyDirectoryURL.appendingPathComponent("processing-history.json")
    }
}
