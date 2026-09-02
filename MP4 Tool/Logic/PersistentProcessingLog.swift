//
//  PersistentProcessingLog.swift
//  MP4 Tool
//

import Foundation

/// A bounded, persistent companion to the in-app processing log.
///
/// The active file is rotated at 5 MB and five archives are retained. Disk
/// logging is intentionally independent from clearing or resetting the log
/// inspector so diagnostic history survives app relaunches and processing runs.
final class PersistentProcessingLog: @unchecked Sendable {
    static let shared = PersistentProcessingLog()

    static let maximumFileSize: Int64 = 5 * 1_024 * 1_024
    static let retainedArchiveCount = 5

    let directoryURL: URL
    let logFileURL: URL

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let timestampFormatter: DateFormatter
    private var currentFileSize: Int64 = 0

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        directoryURL = applicationSupport
            .appendingPathComponent("MP4 Tool", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        logFileURL = directoryURL.appendingPathComponent("MP4 Tool.log")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        timestampFormatter = formatter

        _ = prepareActiveFile()
    }

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        guard prepareActiveFile() else { return }

        let entry = "\(timestampFormatter.string(from: Date()))  \(message)\n"
        guard let data = entry.data(using: .utf8) else { return }

        if currentFileSize > 0,
           currentFileSize + Int64(data.count) > Self.maximumFileSize {
            rotateFiles()
            guard prepareActiveFile() else { return }
        }

        do {
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            currentFileSize += Int64(data.count)
        } catch {
            // Logging must never interrupt processing. Console output remains
            // available if the Application Support location cannot be written.
            print("Could not write persistent MP4 Tool log: \(error.localizedDescription)")
        }
    }

    /// Ensures the active file exists before a menu action attempts to open it.
    @discardableResult
    func ensureLogFileExists() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return prepareActiveFile()
    }

    private func prepareActiveFile() -> Bool {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            if !fileManager.fileExists(atPath: logFileURL.path) {
                guard fileManager.createFile(atPath: logFileURL.path, contents: nil) else {
                    return false
                }
            }
            currentFileSize = fileSize(at: logFileURL)
            return true
        } catch {
            print("Could not prepare persistent MP4 Tool log: \(error.localizedDescription)")
            return false
        }
    }

    private func rotateFiles() {
        let oldestArchive = archiveURL(number: Self.retainedArchiveCount)
        try? fileManager.removeItem(at: oldestArchive)

        if Self.retainedArchiveCount > 1 {
            for number in stride(
                from: Self.retainedArchiveCount - 1,
                through: 1,
                by: -1
            ) {
                let source = archiveURL(number: number)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try? fileManager.moveItem(at: source, to: archiveURL(number: number + 1))
            }
        }

        if fileManager.fileExists(atPath: logFileURL.path) {
            try? fileManager.moveItem(at: logFileURL, to: archiveURL(number: 1))
        }
        currentFileSize = 0
    }

    private func archiveURL(number: Int) -> URL {
        directoryURL.appendingPathComponent("MP4 Tool.\(number).log")
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64 ?? 0
    }
}
