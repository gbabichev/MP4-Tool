//
//  MP4_ToolApp.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI

@main
struct MP4_ToolApp: App {
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
        WindowGroup(id: "main") {
            MainWindowRootView(
                sharedViewModel: isCommandLineToolInstalled ? sharedCLIViewModel : nil,
                registersCLIHandler: isCommandLineToolInstalled
            )
            .environmentObject(windowCommandRegistry)
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
                    openWindow(id: "main")
                }) {
                    Label("New Window", systemImage: "plus.rectangle.on.rectangle")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(isCommandLineToolInstalled)
                .help(isCommandLineToolInstalled ? "New windows are disabled while the command line tool is installed so CLI actions target one shared queue." : "Open a new MP4 Tool window")

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

                if windowCommandRegistry.activeAvailability.canToggleFFmpeg {
                    Button(action: {
                        windowCommandRegistry.activeActions?.toggleFFmpegSource()
                    }) {
                        Label("Toggle FFmpeg Source", systemImage: "arrow.triangle.swap")
                    }
                    .help("Switch between bundled and system FFmpeg")

                    Divider()
                }
                
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

        Window("Scan for Non-MP4 Files", id: "nonMP4Scanner") {
            NonMP4ScannerView()
        }

        Window("Validate MP4 Files", id: "mp4Validation") {
            MP4ValidationView()
        }
    }
}

private struct MainWindowRootView: View {
    let sharedViewModel: ContentViewModel?
    let registersCLIHandler: Bool

    @StateObject private var localViewModel = ContentViewModel()
    @State private var windowID = UUID()

    private var activeViewModel: ContentViewModel {
        sharedViewModel ?? localViewModel
    }

    var body: some View {
        ContentView(
            viewModel: activeViewModel,
            windowID: windowID,
            registersCLIHandler: registersCLIHandler
        )
    }
}
