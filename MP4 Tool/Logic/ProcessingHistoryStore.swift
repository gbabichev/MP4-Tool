//
//  ProcessingHistoryStore.swift
//  MP4 Tool
//

import Foundation
import Combine

struct ProcessingHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let fileName: String
    let originalBytes: Int64
    let outputBytes: Int64
    let processedAt: Date

    var savedBytes: Int64 {
        originalBytes - outputBytes
    }

    var savedPercentage: Double {
        guard originalBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(originalBytes) * 100
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
        processedAt: Date
    ) -> Bool {
        let entry = ProcessingHistoryEntry(
            id: UUID(),
            fileName: fileName,
            originalBytes: originalBytes,
            outputBytes: outputBytes,
            processedAt: processedAt
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
