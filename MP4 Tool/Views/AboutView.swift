//
//  AboutView.swift
//  MP4 Tool
//
//  Created by George Babichev on 10/11/25.
//

/*
 AboutView.swift provides the About screen for the MP4 Tool app.
 It displays app branding, version info, copyright, and a link to the author's website.
 This view is intended to inform users about the app and its creator.
*/

import SwiftUI

struct LiveAppIconView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var refreshID = UUID()

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .id(refreshID) // force SwiftUI to re-evaluate the image
            .frame(width: 124, height: 124)
            .onChange(of: colorScheme) { _,_ in
                // Let AppKit update its icon, then refresh the view
                DispatchQueue.main.async {
                    refreshID = UUID()
                }
            }
    }
}

// MARK: - AboutView

/// A view presenting information about the app, including branding, version, copyright, and author link.
struct AboutView: View {
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            // Semi-transparent background overlay
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            // Main vertical stack arranging all elements with spacing
            VStack(spacing: 20) {
                HStack(spacing: 10) {
                    Image("gbabichev")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(radius: 10)

                    LiveAppIconView()
                }

                // App name displayed prominently
                Text("MP4 Tool")
                    .font(.title)
                    .bold()

                Text("Video Conversion & Remux Utility")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Divider()
                    .padding(.horizontal, 40)

                // App version fetched dynamically from Info.plist; fallback to "1.0"
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                    .foregroundColor(.secondary)
                    .font(.caption)

                // Current year dynamically retrieved for copyright notice
                Link("© \(String(Calendar.current.component(.year, from: Date()))) George Babichev", destination: URL(string: "https://georgebabichev.com")!)
                    .font(.footnote)
                    .foregroundColor(.accentColor)

                Button {
                    isPresented = false
                } label: {
                    Text("Close")
                        .frame(width: 120)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(40)
            .frame(width: 400)
            .background(Color(nsColor: .windowBackgroundColor))
            .cornerRadius(16)
            .shadow(radius: 20)
        }
    }
}
