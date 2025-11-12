//
//  MP4_ToolApp.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI
import Combine

class AppState: ObservableObject {
    @Published var hasBundledFFmpeg: Bool = false
    @Published var hasSystemFFmpeg: Bool = false

    var canToggleFFmpeg: Bool {
        // Only enable toggle if both bundled AND system FFmpeg are available
        return hasBundledFFmpeg && hasSystemFFmpeg
    }
}

@main
struct MP4_ToolApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(action: {
                    NotificationCenter.default.post(name: .showAbout, object: nil)
                }) {
                    Text("About MP4 Tool")
                }
            }

            CommandGroup(replacing: .newItem) {
                Button(action: {
                    openWindow(id: "main")
                }) {
                    Label("New Window", systemImage: "plus.rectangle.on.rectangle")
                }
                .keyboardShortcut("n", modifiers: .command)

                Button(action: {
                    NotificationCenter.default.post(name: .openInputFolder, object: nil)
                }) {
                    Label("Open Input Folder...", systemImage: "folder")
                }
                .keyboardShortcut("o", modifiers: .command)

                Button(action: {
                    NotificationCenter.default.post(name: .selectOutputFolder, object: nil)
                }) {
                    Label("Select Output Folder...", systemImage: "folder.badge.gearshape")
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button(action: {
                    NotificationCenter.default.post(name: .clearFolders, object: nil)
                }) {
                    Label("Clear List", systemImage: "arrow.counterclockwise")
                }
                .keyboardShortcut("l", modifiers: .command)
            }

            CommandMenu("Tools") {
                Button(action: {
                    NotificationCenter.default.post(name: .startProcessing, object: nil)
                }) {
                    Label("Process", systemImage: "play.fill")
                }
                .keyboardShortcut("p", modifiers: .command)

                Divider()

                if appState.canToggleFFmpeg {
                    Button(action: {
                        NotificationCenter.default.post(name: .toggleFFmpegSource, object: nil)
                    }) {
                        Label("Toggle FFmpeg Source", systemImage: "arrow.triangle.swap")
                    }
                    .help("Switch between bundled and system FFmpeg")

                    Divider()
                }


                Button(action: {
                    NotificationCenter.default.post(name: .scanForNonMP4, object: nil)
                }) {
                    Label("Scan for Non-MP4 Files...", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])

                Button(action: {
                    NotificationCenter.default.post(name: .validateMP4Files, object: nil)
                }) {
                    Label("Validate MP4 Files...", systemImage: "checkmark.circle")
                }
                .keyboardShortcut("V", modifiers: [.command, .shift])

                Divider()

                Button(action: {
                    NotificationCenter.default.post(name: .exportLog, object: nil)
                }) {
                    Label("Export Log to TXT...", systemImage: "square.and.arrow.up")
                }
                .keyboardShortcut("E", modifiers: [.command, .shift])
            }

            CommandGroup(after: .help) {
                Button(action: {
                    NotificationCenter.default.post(name: .showTutorial, object: nil)
                }) {
                    Label("Tutorial", systemImage: "lightbulb.fill")
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let openInputFolder = Notification.Name("openInputFolder")
    static let selectOutputFolder = Notification.Name("selectOutputFolder")
    static let clearFolders = Notification.Name("clearFolders")
    static let startProcessing = Notification.Name("startProcessing")
    static let scanForNonMP4 = Notification.Name("scanForNonMP4")
    static let validateMP4Files = Notification.Name("validateMP4Files")
    static let exportLog = Notification.Name("exportLog")
    static let showTutorial = Notification.Name("showTutorial")
    static let showAbout = Notification.Name("showAbout")
    static let toggleFFmpegSource = Notification.Name("toggleFFmpegSource")
}
