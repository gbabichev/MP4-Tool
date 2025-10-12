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

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
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
                    Label("Clear List", systemImage: "xmark.circle")
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

                Button(action: {
                    NotificationCenter.default.post(name: .scanForNonMP4, object: nil)
                }) {
                    Label("Scan for Non-MP4 Files...", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])

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
    static let exportLog = Notification.Name("exportLog")
    static let showTutorial = Notification.Name("showTutorial")
    static let showAbout = Notification.Name("showAbout")
}
