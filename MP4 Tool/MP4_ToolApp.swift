//
//  MP4_ToolApp.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

import SwiftUI

@main
struct MP4_ToolApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
            }

            CommandMenu("Tools") {
                Button("Scan for Non-MP4 Files...") {
                    NotificationCenter.default.post(name: .scanForNonMP4, object: nil)
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let scanForNonMP4 = Notification.Name("scanForNonMP4")
}
