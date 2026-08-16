//
//  ProcessingStagingStorage.swift
//  MP4 Tool
//

import Foundation
import Darwin

struct ProcessingStagingLocation {
    let directoryURL: URL
    let usesDestinationVolume: Bool
    let destinationVolumeIsEligible: Bool
    let availableBytes: Int64?
}

enum ProcessingStagingStorage {
    private static let directoryName = ".mp4tool-staging"
    private static let filePrefix = "mp4tool-"
    private static let knownDestinationDirectoriesKey = "knownProcessingStagingDirectories"
    private static let minimumReserveBytes: Int64 = 512 * 1_024 * 1_024

    static func location(outputPath: String, preferDestinationVolume: Bool) -> ProcessingStagingLocation {
        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        let destinationIsEligible = destinationVolumeIsEligible(outputPath: outputPath)
        let usesDestination = preferDestinationVolume && destinationIsEligible
        let directoryURL = usesDestination
            ? outputURL.appendingPathComponent(directoryName, isDirectory: true)
            : systemDirectoryURL

        return ProcessingStagingLocation(
            directoryURL: directoryURL,
            usesDestinationVolume: usesDestination,
            destinationVolumeIsEligible: destinationIsEligible,
            availableBytes: availableBytes(at: directoryURL)
        )
    }

    static func prepareDirectory(for location: ProcessingStagingLocation) throws {
        try FileManager.default.createDirectory(
            at: location.directoryURL,
            withIntermediateDirectories: true
        )

        if location.usesDestinationVolume {
            rememberDestinationDirectory(location.directoryURL.path)
        }
    }

    static func temporaryOutputURL(in location: ProcessingStagingLocation) -> URL {
        let processID = ProcessInfo.processInfo.processIdentifier
        return location.directoryURL.appendingPathComponent(
            "\(filePrefix)\(processID)-\(UUID().uuidString).mp4"
        )
    }

    static func capacityIssue(
        estimatedOutputBytes: Int64,
        location: ProcessingStagingLocation,
        outputPath: String
    ) -> String? {
        let estimate = max(estimatedOutputBytes, 1)
        let requiredBytes = estimate + max(minimumReserveBytes, estimate / 20)

        guard let scratchAvailable = availableBytes(at: location.directoryURL) else {
            return "Available scratch space could not be determined at \(location.directoryURL.path)."
        }
        guard scratchAvailable >= requiredBytes else {
            return "Scratch storage has \(formattedBytes(scratchAvailable)) available, but approximately \(formattedBytes(requiredBytes)) is required."
        }

        // Destination staging uses the same capacity already checked above.
        if !location.usesDestinationVolume {
            guard let destinationAvailable = availableBytes(
                at: URL(fileURLWithPath: outputPath, isDirectory: true)
            ) else {
                return "Available destination space could not be determined at \(outputPath)."
            }
            guard destinationAvailable >= requiredBytes else {
                return "The destination has \(formattedBytes(destinationAvailable)) available, but approximately \(formattedBytes(requiredBytes)) is required."
            }
        }

        return nil
    }

    static func cleanupAbandonedFiles() -> Int {
        let defaults = UserDefaults.standard
        let rememberedDirectories = defaults.stringArray(forKey: knownDestinationDirectoriesKey) ?? []
        let directoryPaths = Set([systemDirectoryURL.path] + rememberedDirectories)
        var removedCount = 0

        for directoryPath in directoryPaths {
            let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for fileURL in files where fileURL.lastPathComponent.hasPrefix(filePrefix) {
                guard let ownerProcessID = ownerProcessID(for: fileURL.lastPathComponent),
                      !processIsRunning(ownerProcessID) else {
                    continue
                }

                if (try? FileManager.default.removeItem(at: fileURL)) != nil {
                    removedCount += 1
                }
            }

            removeDirectoryIfEmpty(directoryURL)
        }

        return removedCount
    }

    static func removeDirectoryIfEmpty(_ directoryURL: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path),
              contents.isEmpty else {
            return
        }
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private static var systemDirectoryURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MP4 Tool Staging", isDirectory: true)
    }

    private static func destinationVolumeIsEligible(outputPath: String) -> Bool {
        guard !outputPath.isEmpty else { return false }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputPath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: outputPath) else {
            return false
        }

        let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        guard let values = try? outputURL.resourceValues(
            forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey]
        ) else {
            return false
        }

        return values.volumeIsLocal == true && values.volumeIsReadOnly != true
    }

    private static func availableBytes(at url: URL) -> Int64? {
        var existingURL = url
        while !FileManager.default.fileExists(atPath: existingURL.path) {
            let parent = existingURL.deletingLastPathComponent()
            guard parent.path != existingURL.path else { return nil }
            existingURL = parent
        }

        guard let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: existingURL.path
        ), let freeSize = attributes[.systemFreeSize] as? NSNumber else {
            return nil
        }
        return freeSize.int64Value
    }

    private static func rememberDestinationDirectory(_ path: String) {
        let defaults = UserDefaults.standard
        var paths = defaults.stringArray(forKey: knownDestinationDirectoriesKey) ?? []
        paths.removeAll { $0 == path }
        paths.append(path)
        defaults.set(Array(paths.suffix(20)), forKey: knownDestinationDirectoriesKey)
    }

    private static func ownerProcessID(for fileName: String) -> pid_t? {
        let remainder = fileName.dropFirst(filePrefix.count)
        guard let separator = remainder.firstIndex(of: "-"),
              let processID = Int32(remainder[..<separator]) else {
            return nil
        }
        return processID
    }

    private static func processIsRunning(_ processID: pid_t) -> Bool {
        guard processID > 0 else { return false }
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
