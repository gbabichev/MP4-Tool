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
    private var terminationTask: Task<Void, Never>?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let videoProcessor, videoProcessor.isProcessing else {
            return .terminateNow
        }

        guard terminationTask == nil else {
            return .terminateLater
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

    var body: some Scene {
        Window("MP4 Tool", id: "main") {
            MainWindowRootView(
                viewModel: sharedCLIViewModel
            )
            .environmentObject(windowCommandRegistry)
            .onAppear {
                appDelegate.videoProcessor = sharedCLIViewModel.processor
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

                Button(action: {
                    openWindow(id: "runHistory")
                }) {
                    Label("Run History", systemImage: "clock.arrow.circlepath")
                }

                Divider()

                Button(action: {
                    openWindow(id: "videoSplitter")
                }) {
                    Label("Video Splitter", systemImage: "scissors")
                }

                Button(action: {
                    openWindow(id: "offsetStartChecker")
                }) {
                    Label("Check Offset Starts", systemImage: "clock.arrow.2.circlepath")
                }

                Button(action: {
                    openWindow(id: "subtitleMuxer")
                }) {
                    Label("Subtitle Merger", systemImage: "captions.bubble.fill")
                }

                Button(action: {
                    openWindow(id: "trackEditor")
                }) {
                    Label("Track Editor", systemImage: "list.bullet.rectangle")
                }

                Divider()
                
                Button(action: {
                    openWindow(id: "nonMP4Scanner")
                }) {
                    Label("Scan for Non-MP4 Files...", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])

                Button(action: {
                    openWindow(id: "mp4Validation")
                }) {
                    Label("Validate MP4 Files...", systemImage: "checkmark.circle")
                }
                .keyboardShortcut("V", modifiers: [.command, .shift])

                Divider()

                Button(action: {
                    windowCommandRegistry.activeActions?.exportLog()
                }) {
                    Label("Export Log to TXT...", systemImage: "square.and.arrow.up")
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
        
        Window("Video Splitter", id: "videoSplitter") {
            VideoSplitterView()
        }

        Window("Check Offset Starts", id: "offsetStartChecker") {
            OffsetStartCheckerView()
        }

        Window("Subtitle Merger", id: "subtitleMuxer") {
            SubtitleMuxerView()
        }

        Window("Track Editor", id: "trackEditor") {
            TrackEditorView()
        }
        .defaultSize(width: 1120, height: 760)

        Window("Scan for Non-MP4 Files", id: "nonMP4Scanner") {
            NonMP4ScannerView()
        }

        Window("Validate MP4 Files", id: "mp4Validation") {
            MP4ValidationView()
        }

        Window("Run History", id: "runHistory") {
            RunHistoryView()
        }
        .defaultSize(width: 980, height: 520)
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
