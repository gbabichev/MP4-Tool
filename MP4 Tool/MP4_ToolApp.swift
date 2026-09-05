//
//  MP4_ToolApp.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI
import AppKit

@MainActor
private final class MP4ToolAppDelegate: NSObject, NSApplicationDelegate {
    weak var videoProcessor: VideoProcessor?
    var reopenMainWindow: (() -> Void)?
    var isMainWindowVisible = false
    private var terminationTask: Task<Void, Never>?

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !isMainWindowVisible, let reopenMainWindow else {
            return true
        }

        // A tool window can keep the app visible after the primary window is
        // closed. Treat a Dock/Finder reopen as a request for that primary
        // singleton rather than relying on AppKit's all-windows visibility.
        Task { @MainActor in
            reopenMainWindow()
            sender.activate(ignoringOtherApps: true)
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let videoProcessor, videoProcessor.isProcessing else {
            return .terminateNow
        }

        guard terminationTask == nil else {
            return .terminateLater
        }

        let alert = NSAlert()
        alert.messageText = "Quit While Processing?"
        alert.informativeText = "An encode or remux is still running. Quitting now will stop the active operation and discard its unfinished output."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Processing")
        alert.addButton(withTitle: "Quit and Stop")
        alert.buttons.last?.hasDestructiveAction = true

        guard alert.runModal() == .alertSecondButtonReturn else {
            return .terminateCancel
        }

        terminationTask = Task { [weak self, weak videoProcessor, weak sender] in
            guard let videoProcessor else {
                sender?.reply(toApplicationShouldTerminate: true)
                return
            }

            await videoProcessor.cancelForApplicationTermination()

            // Allow the processing task to consume its cancellation and clean up.
            for _ in 0..<20 where videoProcessor.isProcessing {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    break
                }
            }

            self?.terminationTask = nil
            sender?.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
}

@main
struct MP4_ToolApp: App {
    @NSApplicationDelegateAdaptor(MP4ToolAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var sharedCLIViewModel = ContentViewModel()
    @StateObject private var windowCommandRegistry = WindowCommandRegistry()
    @State private var isCommandLineToolInstalled = CommandLineToolInstaller.canRemoveInstalledTool

    init() {
        Task { @MainActor in
            do {
                try CLICommandServer.shared.start()
                AppUpdateCenter.debugLog("CLI command server listening at \(CLICommandServer.socketPath)")
            } catch {
                AppUpdateCenter.debugLog("CLI command server failed to start: \(error.localizedDescription)")
            }
        }

        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                AppUpdateCenter.debugLog("Firing init-scheduled automatic launch update check")
                AppUpdateCenter.shared.checkForUpdates(trigger: .automaticLaunch)
            }
        }
    }

    private func refreshCommandLineToolState() {
        isCommandLineToolInstalled = CommandLineToolInstaller.canRemoveInstalledTool
    }

    private func installCommandLineTool() {
        Task { @MainActor in
            await CommandLineToolInstaller.installFromMenu()
            refreshCommandLineToolState()
        }
    }

    private func uninstallCommandLineTool() {
        Task { @MainActor in
            await CommandLineToolInstaller.removeFromMenu()
            refreshCommandLineToolState()
        }
    }

    private func openProcessingLog() {
        let log = PersistentProcessingLog.shared
        guard log.ensureLogFileExists() else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(log.logFileURL)
    }

    private func openProcessingLogFolder() {
        let log = PersistentProcessingLog.shared
        guard log.ensureLogFileExists() else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(log.directoryURL)
    }

    var body: some Scene {
        Window("MP4 Tool", id: "main") {
            MainWindowRootView(
                viewModel: sharedCLIViewModel
            )
            .standardWindowToolbarDivider()
            .environmentObject(windowCommandRegistry)
            .onAppear {
                appDelegate.videoProcessor = sharedCLIViewModel.processor
                appDelegate.reopenMainWindow = {
                    openWindow(id: "main")
                }
                appDelegate.isMainWindowVisible = true
            }
            .onDisappear {
                appDelegate.isMainWindowVisible = false
            }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(action: {
                    windowCommandRegistry.activeActions?.showAbout()
                }) {
                    Label("About MP4 Tool", systemImage: "info.circle")
                }
                .disabled(!windowCommandRegistry.hasActiveWindow)

                Button(action: {
                    AppUpdateCenter.shared.checkForUpdates(trigger: .manual)
                }) {
                    Label("Check for Updates...", systemImage: "arrow.triangle.2.circlepath.circle")
                }

                Divider()

                if isCommandLineToolInstalled {
                    Button(action: {
                        uninstallCommandLineTool()
                    }) {
                        Label("Uninstall Command Line Tool...", systemImage: "trash")
                    }
                } else {
                    Button(action: {
                        installCommandLineTool()
                    }) {
                        Label("Install Command Line Tool...", systemImage: "terminal")
                    }
                }
            }

            CommandGroup(replacing: .newItem) {
                Button(action: {
                    windowCommandRegistry.activeActions?.openInputFolder()
                }) {
                    Label("Open Input Folder...", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(windowCommandRegistry.activeAvailability.isProcessing || !windowCommandRegistry.hasActiveWindow)

                Button(action: {
                    windowCommandRegistry.activeActions?.selectOutputFolder()
                }) {
                    Label("Select Output Folder...", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(windowCommandRegistry.activeAvailability.isProcessing || !windowCommandRegistry.hasActiveWindow)

                Divider()

                Button(action: {
                    windowCommandRegistry.activeActions?.clearFolders()
                }) {
                    Label("Clear List", systemImage: "arrow.counterclockwise")
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!windowCommandRegistry.activeAvailability.canClearFolders || windowCommandRegistry.activeAvailability.isProcessing)
            }

            CommandMenu("Tools") {
                Button(action: {
                    windowCommandRegistry.activeActions?.startProcessing()
                }) {
                    Label("Process", systemImage: "play.fill")
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!windowCommandRegistry.activeAvailability.canStartProcessing || windowCommandRegistry.activeAvailability.isProcessing)

                Divider()

                Button(action: {
                    openWindow(id: "inspectRepair")
                }) {
                    Label("Inspect & Repair...", systemImage: "stethoscope")
                }
                .keyboardShortcut("V", modifiers: [.command, .shift])

                Button(action: {
                    openWindow(id: "trackEditor")
                }) {
                    Label("Track Editor...", systemImage: "list.bullet.rectangle")
                }
                .help("Inspect, add, remove, and edit audio or subtitle tracks")

                Button(action: {
                    openWindow(id: "videoSplitter")
                }) {
                    Label("Video Splitter", systemImage: "scissors")
                }

                Button(action: {
                    openWindow(id: "nonMP4Scanner")
                }) {
                    Label("Scan for Non-MP4 Files...", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])

                Divider()

                Button(action: {
                    openWindow(id: "runHistory")
                }) {
                    Label("Run History", systemImage: "clock.arrow.circlepath")
                }
            }

            CommandMenu("Log") {
                Button(action: openProcessingLog) {
                    Label("Open Processing Log", systemImage: "doc.text")
                }

                Button(action: openProcessingLogFolder) {
                    Label("Open Log Folder", systemImage: "folder")
                }

                Divider()

                Button(action: {
                    windowCommandRegistry.activeActions?.exportLog()
                }) {
                    Label("Export Current Log to TXT...", systemImage: "square.and.arrow.up")
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])
                .disabled(!windowCommandRegistry.activeAvailability.canExportLog)
            }

            CommandGroup(after: .help) {
                Button(action: {
                    windowCommandRegistry.activeActions?.showTutorial()
                }) {
                    Label("Tutorial", systemImage: "lightbulb.fill")
                }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(!windowCommandRegistry.hasActiveWindow)
            }
        }
        .defaultSize(width: 1_100, height: 720)
        
        Window("Video Splitter", id: "videoSplitter") {
            VideoSplitterView()
                .standardWindowToolbarDivider()
        }

        Window("Inspect & Repair", id: "inspectRepair") {
            InspectRepairView()
                .standardWindowToolbarDivider()
        }
        .defaultSize(width: 1_100, height: 720)

        Window("Track Editor", id: "trackEditor") {
            TrackEditorView()
                .standardWindowToolbarDivider()
        }
        .defaultSize(width: 1120, height: 760)

        Window("Scan for Non-MP4 Files", id: "nonMP4Scanner") {
            NonMP4ScannerView()
                .standardWindowToolbarDivider()
        }

        Window("Run History", id: "runHistory") {
            RunHistoryView()
                .standardWindowToolbarDivider()
        }
        .defaultSize(width: 980, height: 520)
    }
}

private extension View {
    /// Draws a consistent boundary between the native window toolbar and the
    /// SwiftUI content, independent of the toolbar style macOS chooses.
    func standardWindowToolbarDivider() -> some View {
        overlay(alignment: .top) {
            Divider()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct MainWindowRootView: View {
    @ObservedObject var viewModel: ContentViewModel

    @State private var windowID = UUID()

    var body: some View {
        ContentView(
            viewModel: viewModel,
            windowID: windowID
        )
    }
}
