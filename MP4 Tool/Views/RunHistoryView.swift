//
//  RunHistoryView.swift
//  MP4 Tool
//

import SwiftUI

struct RunHistoryView: View {
    @ObservedObject private var history = ProcessingHistoryStore.shared
    @State private var selection: Set<ProcessingHistoryEntry.ID> = []
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
                Table(history.entries, selection: $selection) {
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
                .contextMenu(forSelectionType: ProcessingHistoryEntry.ID.self) { selectedIDs in
                    Button("Delete", role: .destructive) {
                        delete(selectedIDs)
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            }
        }
        .onDeleteCommand {
            delete(selection)
        }
        .onChange(of: history.entries.map(\.id)) { _, entryIDs in
            selection.formIntersection(entryIDs)
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
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Clear History…", role: .destructive) {
                        showingClearConfirmation = true
                    }
                    .disabled(history.entries.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }

                Button(role: .destructive) {
                    delete(selection)
                } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
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

    private func delete(_ ids: Set<ProcessingHistoryEntry.ID>) {
        guard !ids.isEmpty else { return }
        history.remove(ids: ids)
        selection.subtract(ids)
    }
}
