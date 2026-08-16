//
//  RunHistoryView.swift
//  MP4 Tool
//

import SwiftUI

struct RunHistoryView: View {
    @ObservedObject private var history = ProcessingHistoryStore.shared
    @State private var showingClearConfirmation = false

    var body: some View {
        Group {
            if history.entries.isEmpty {
                ContentUnavailableView(
                    "No Processing History",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Successfully processed files will appear here.")
                )
            } else {
                Table(history.entries) {
                    TableColumn("File Name") { entry in
                        Text(entry.fileName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .width(min: 220, ideal: 360)

                    TableColumn("Original Size") { entry in
                        Text(formattedBytes(entry.originalBytes))
                            .monospacedDigit()
                    }
                    .width(min: 95, ideal: 110)

                    TableColumn("New Size") { entry in
                        Text(formattedBytes(entry.outputBytes))
                            .monospacedDigit()
                    }
                    .width(min: 95, ideal: 110)

                    TableColumn("Space Saved") { entry in
                        Text(formattedBytes(entry.savedBytes))
                            .monospacedDigit()
                    }
                    .width(min: 95, ideal: 110)

                    TableColumn("Saved") { entry in
                        Text(entry.savedPercentage, format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                        + Text("%")
                    }
                    .width(min: 65, ideal: 75)

                    TableColumn("Date") { entry in
                        Text(entry.processedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                    .width(min: 145, ideal: 170)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = history.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
        .frame(minWidth: 760, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    showingClearConfirmation = true
                } label: {
                    Label("Clear History", systemImage: "trash")
                }
                .disabled(history.entries.isEmpty)
            }
        }
        .confirmationDialog(
            "Clear all processing history?",
            isPresented: $showingClearConfirmation
        ) {
            Button("Clear History", role: .destructive) {
                history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every saved history entry.")
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
