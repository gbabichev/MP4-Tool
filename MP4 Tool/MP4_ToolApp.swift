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
    @FocusedValue(\.windowCommandHandler) private var windowCommandHandler

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(action: {
                    windowCommandHandler?.showAbout()
                }) {
                    Text("About MP4 Tool")
                }
                .disabled(windowCommandHandler == nil)
            }

            CommandGroup(replacing: .newItem) {
                Button(action: {
                    openWindow(id: "main")
                }) {
                    Label("New Window", systemImage: "plus.rectangle.on.rectangle")
                }
                .keyboardShortcut("n", modifiers: .command)

                Button(action: {
                    windowCommandHandler?.openInputFolder()
                }) {
                    Label("Open Input Folder...", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(windowCommandHandler?.isProcessing ?? true)

                Button(action: {
                    windowCommandHandler?.selectOutputFolder()
                }) {
                    Label("Select Output Folder...", systemImage: "folder.badge.plus")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(windowCommandHandler?.isProcessing ?? true)

                Divider()

                Button(action: {
                    windowCommandHandler?.clearFolders()
                }) {
                    Label("Clear List", systemImage: "arrow.counterclockwise")
                }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!(windowCommandHandler?.canClearFolders ?? false) || (windowCommandHandler?.isProcessing ?? false))
            }

            CommandMenu("Tools") {
                Button(action: {
                    windowCommandHandler?.startProcessing()
                }) {
                    Label("Process", systemImage: "play.fill")
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!(windowCommandHandler?.canStartProcessing ?? false) || (windowCommandHandler?.isProcessing ?? false))

                Divider()

                if windowCommandHandler?.canToggleFFmpeg == true {
                    Button(action: {
                        windowCommandHandler?.toggleFFmpegSource()
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
                    windowCommandHandler?.exportLog()
                }) {
                    Label("Export Log to TXT...", systemImage: "square.and.arrow.up")
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])
                .disabled(!(windowCommandHandler?.canExportLog ?? false))
            }

            CommandGroup(after: .help) {
                Button(action: {
                    windowCommandHandler?.showTutorial()
                }) {
                    Label("Tutorial", systemImage: "lightbulb.fill")
                }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(windowCommandHandler == nil)
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
