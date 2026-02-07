import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

let queueNonMP4FlaggedFilesNotification = Notification.Name("MP4Tool.QueueNonMP4FlaggedFiles")
let queueNonMP4FlaggedFilesPathsKey = "paths"

struct NonMP4ScanResult: Identifiable {
    let id = UUID()
    let fileName: String
    let filePath: String
    let fileExtension: String

    var isFlagged: Bool {
        fileExtension.lowercased() != "mp4"
    }
}

@MainActor
final class NonMP4ScannerViewModel: ObservableObject {
    @Published var inputFolderPath: String = ""
    @Published var isScanning = false
    @Published var scanProgress = ""
    @Published var scanAlertText = ""
    @Published var results: [NonMP4ScanResult] = []

    private var scanTask: Task<Void, Never>?
    private var scanToken = UUID()
    private var exportDialogHostWindow: NSWindow?

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "avi", "mov", "m4v", "flv", "wmv", "webm", "mpeg", "mpg"
    ]

    var canScan: Bool {
        !inputFolderPath.isEmpty && !isScanning
    }

    var canCancelScan: Bool {
        isScanning
    }

    var flaggedResults: [NonMP4ScanResult] {
        results.filter(\.isFlagged)
    }

    var canExportFlagged: Bool {
        !isScanning && !flaggedResults.isEmpty
    }

    var canSendFlaggedToMainApp: Bool {
        !isScanning && !flaggedResults.isEmpty
    }

    func selectInputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Select folder to scan for non-MP4 files"

        if panel.runModal() == .OK, let url = panel.url {
            inputFolderPath = url.path
        }
    }

    func openInputFolderInFinder() {
        guard !inputFolderPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: inputFolderPath, isDirectory: true))
    }

    func scan() {
        guard canScan else { return }
        results = []
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
        scanProgress = "Scan canceled."
        isScanning = false
    }

    func exportFlaggedToFile() {
        let flaggedPaths = flaggedResults.map(\.filePath)
        guard !flaggedPaths.isEmpty else {
            scanAlertText = "No flagged files to export."
            return
        }

        let hostWindow = makeHiddenChromeHostWindow()
        exportDialogHostWindow = hostWindow
        hostWindow.makeKeyAndOrderFront(nil)

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "non-mp4-files.txt"

        panel.beginSheetModal(for: hostWindow) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }

                defer {
                    self.exportDialogHostWindow?.orderOut(nil)
                    self.exportDialogHostWindow = nil
                }

                guard response == .OK, let url = panel.url else {
                    return
                }

                let body = flaggedPaths.joined(separator: "\n")
                do {
                    try body.write(to: url, atomically: true, encoding: .utf8)
                    self.scanAlertText = "Exported \(flaggedPaths.count) flagged path(s) to \(url.path)."
                } catch {
                    self.scanAlertText = "Failed to export flagged files: \(error.localizedDescription)"
                }
            }
        }
    }

    func sendFlaggedToMainApp() {
        let flaggedPaths = flaggedResults.map(\.filePath)
        guard !flaggedPaths.isEmpty else {
            scanAlertText = "No flagged files to send to main app."
            return
        }

        NotificationCenter.default.post(
            name: queueNonMP4FlaggedFilesNotification,
            object: nil,
            userInfo: [queueNonMP4FlaggedFilesPathsKey: flaggedPaths]
        )
        scanAlertText = "Sent \(flaggedPaths.count) flagged file(s) to main app."
    }

    private func runScan(token: UUID) async {
        let files = collectVideoFilesRecursively(in: inputFolderPath)

        if files.isEmpty {
            scanProgress = "No video files found in folder or subfolders."
            scanAlertText = ""
            isScanning = false
            return
        }

        for (index, fileInfo) in files.enumerated() {
            if Task.isCancelled || token != scanToken {
                scanProgress = "Scan canceled."
                isScanning = false
                return
            }

            scanProgress = "Scanning \(index + 1)/\(files.count): \(fileInfo.relativePath)"

            results.append(
                NonMP4ScanResult(
                    fileName: fileInfo.relativePath,
                    filePath: fileInfo.fullPath,
                    fileExtension: fileInfo.fileExtension
                )
            )
        }

        if token != scanToken {
            scanProgress = "Scan canceled."
            isScanning = false
            return
        }

        let flaggedCount = flaggedResults.count
        scanProgress = "Checked \(results.count) video file(s)."

        if flaggedCount > 0 {
            scanAlertText = "Flagged non-MP4 file(s): \(flaggedCount)."
        } else {
            scanAlertText = "All scanned video files are MP4."
        }

        isScanning = false
    }

    private func collectVideoFilesRecursively(in rootPath: String) -> [(relativePath: String, fullPath: String, fileExtension: String)] {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: options
        ) else {
            return []
        }

        var files: [(relativePath: String, fullPath: String, fileExtension: String)] = []

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard Self.videoExtensions.contains(ext) else {
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else {
                continue
            }

            let relativePath = fileURL.path.replacingOccurrences(of: rootPath + "/", with: "")
            files.append((relativePath: relativePath, fullPath: fileURL.path, fileExtension: ext))
        }

        return files.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private func makeHiddenChromeHostWindow() -> NSWindow {
        let size = NSSize(width: 640, height: 480)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2)
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovable = false
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        return window
    }
}
