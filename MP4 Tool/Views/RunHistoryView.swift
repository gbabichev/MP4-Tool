//
//  RunHistoryView.swift
//  MP4 Tool
//

import SwiftUI
import AppKit

struct RunHistoryView: View {
    @ObservedObject private var history = ProcessingHistoryStore.shared
    @State private var selection: Set<ProcessingHistoryEntry.ID> = []
    @State private var showingClearConfirmation = false
    @State private var detailEntry: ProcessingHistoryEntry?

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

                    TableColumn("Runtime") { entry in
                        Text(formattedRuntime(entry.runtimeSeconds))
                            .monospacedDigit()
                    }
                    .width(min: 75, ideal: 90)

                    TableColumn("Started") { entry in
                        if let startedAt = entry.startedAt {
                            Text(startedAt, format: .dateTime.year().month().day().hour().minute())
                        } else {
                            Text("—")
                        }
                    }
                    .width(min: 145, ideal: 170)

                    TableColumn("Completed") { entry in
                        Text(entry.processedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                    .width(min: 145, ideal: 170)
                }
                .onTapGesture(count: 2) {
                    showSelectedDetails()
                }
                .contextMenu(forSelectionType: ProcessingHistoryEntry.ID.self) { selectedIDs in
                    Button("Show Details") {
                        showDetails(for: selectedIDs)
                    }
                    .disabled(selectedIDs.count != 1)

                    Divider()

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
                Button {
                    showSelectedDetails()
                } label: {
                    Label("Show Details", systemImage: "info.circle")
                }
                .disabled(selection.count != 1)

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
        .sheet(item: $detailEntry) { entry in
            ProcessingHistoryDetailView(entry: entry)
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formattedRuntime(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        return ProcessingHistoryDetailView.formattedDuration(seconds)
    }

    private func showSelectedDetails() {
        showDetails(for: selection)
    }

    private func showDetails(for ids: Set<ProcessingHistoryEntry.ID>) {
        guard ids.count == 1,
              let id = ids.first,
              let entry = history.entries.first(where: { $0.id == id }) else {
            return
        }
        detailEntry = entry
    }

    private func delete(_ ids: Set<ProcessingHistoryEntry.ID>) {
        guard !ids.isEmpty else { return }
        history.remove(ids: ids)
        selection.subtract(ids)
    }
}

private struct ProcessingHistoryDetailView: View {
    let entry: ProcessingHistoryEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryHeader
                    metricsGrid

                    if let details = entry.details {
                        fileSection(details)
                        processingSection(details)
                        settingsSection(details)
                        commandSection(details.ffmpegCommands)
                    } else {
                        legacyEntryNotice
                    }
                }
                .padding(16)
            }
            .navigationTitle("Run Details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 560)
    }

    private var summaryHeader: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.fileName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(summaryDateRange)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(entry.details == nil ? "Legacy Entry" : "Completed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.details == nil ? Color.secondary : Color.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    (entry.details == nil ? Color.secondary : Color.green).opacity(0.12),
                    in: Capsule()
                )
        }
        .padding(16)
        .cardBackground()
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
            metricCard("Original", formattedBytes(entry.originalBytes), systemImage: "doc")
            metricCard("Output", formattedBytes(entry.outputBytes), systemImage: "doc.fill")
            metricCard(
                "Space Saved",
                "\(formattedBytes(entry.savedBytes)) · \(entry.savedPercentage.formatted(.number.precision(.fractionLength(1))))%",
                systemImage: "arrow.down.circle"
            )
            metricCard(
                "Runtime",
                entry.runtimeSeconds.map(Self.formattedDuration) ?? "—",
                systemImage: "clock"
            )
        }
    }

    private func metricCard(_ title: String, _ value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .padding(12)
        .cardBackground()
    }

    private func fileSection(_ details: ProcessingHistoryDetails) -> some View {
        detailCard("Files", systemImage: "folder") {
            VStack(spacing: 0) {
                detailRow("Input", details.inputPath)
                Divider()
                detailRow("Output", details.outputPath)
            }
        }
    }

    private func processingSection(_ details: ProcessingHistoryDetails) -> some View {
        detailCard("Processing", systemImage: "gearshape.2") {
            VStack(spacing: 0) {
                if let startedAt = entry.startedAt {
                    detailRow("Started", startedAt.formatted(date: .abbreviated, time: .standard))
                    Divider()
                }
                detailRow("Completed", entry.processedAt.formatted(date: .abbreviated, time: .standard))
                Divider()
                detailRow("Runtime", entry.runtimeSeconds.map(Self.formattedDuration) ?? "Not recorded")
                Divider()
                detailRow("Mode", details.mode)
                if let duration = details.sourceDurationSeconds {
                    Divider()
                    detailRow("Source Duration", Self.formattedDuration(duration))
                }
                Divider()
                detailRow("Run ID", details.runID)
                Divider()
                detailRow("FFmpeg", "\(details.ffmpegSource) · \(details.ffmpegVersion)")
                Divider()
                detailRow("MP4 Tool", "\(details.appVersion) (\(details.appBuild))")
            }
        }
    }

    private func settingsSection(_ details: ProcessingHistoryDetails) -> some View {
        detailCard("Settings", systemImage: "slider.horizontal.3") {
            VStack(spacing: 0) {
                detailRow(
                    "Video",
                    details.crfValue.map { details.encodeVideo ? "Encode · CRF \($0)" : "Copy" }
                        ?? (details.encodeVideo ? "Encode" : "Copy")
                )
                Divider()
                detailRow("Audio", details.encodeAudio ? "Encode" : "Copy")
                if let resolution = details.resolution {
                    Divider()
                    detailRow("Resolution", resolution)
                }
                if let preset = details.encoderPreset {
                    Divider()
                    detailRow("Encoder Preset", preset)
                }
                Divider()
                detailRow("Create Subfolders", yesNo(details.createSubfolders))
                Divider()
                detailRow("Automatic Rename", yesNo(details.automaticRename))
                Divider()
                detailRow("Delete Original", yesNo(details.deleteOriginal))
                Divider()
                detailRow("English Audio", details.keepAllEnglishAudioTracks ? "Keep all English tracks" : details.keepEnglishAudioOnly ? "Keep preferred English track only" : "Keep other languages")
                Divider()
                detailRow("English Subtitles", details.keepAllEnglishSubtitleTracks ? "Keep all English tracks" : details.keepEnglishSubtitlesOnly ? "Keep preferred English track only" : "Keep other languages")
            }
        }
    }

    private func commandSection(_ commands: [String]) -> some View {
        detailCard("FFmpeg Commands", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 12) {
                if commands.isEmpty {
                    Text("No FFmpeg command was recorded for this run.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(commands.enumerated()), id: \.offset) { index, command in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(commands.count == 1 ? "Command" : "Command \(index + 1)")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button {
                                    copyToPasteboard(command)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .labelStyle(.iconOnly)
                                .help("Copy command")
                            }

                            Text(command)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }

    private var legacyEntryNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Detailed diagnostics unavailable")
                    .font(.headline)
                Text("This run was saved before runtime, settings, paths, and FFmpeg commands were added to Run History. New processing runs will include the complete details.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardBackground()
    }

    private func detailCard<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                if title == "FFmpeg Commands",
                   let commands = entry.details?.ffmpegCommands,
                   commands.count > 1 {
                    Button("Copy All") {
                        copyToPasteboard(commands.joined(separator: "\n\n"))
                    }
                    .controlSize(.small)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardBackground()
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 125, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var summaryDateRange: String {
        let completed = entry.processedAt.formatted(date: .abbreviated, time: .shortened)
        guard let startedAt = entry.startedAt else {
            return "Completed \(completed)"
        }
        let started = startedAt.formatted(date: .abbreviated, time: .shortened)
        return "Started \(started) · Completed \(completed)"
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "Yes" : "No"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func formattedDuration(_ seconds: TimeInterval) -> String {
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(remainingSeconds)s"
        }
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        return "\(remainingSeconds)s"
    }
}

private extension View {
    func cardBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}
