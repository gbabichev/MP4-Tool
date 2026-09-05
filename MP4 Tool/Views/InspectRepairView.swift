import SwiftUI
import AppKit
import UniformTypeIdentifiers

let inspectRepairResetAllNotification = Notification.Name("MP4Tool.InspectRepair.ResetAll")

private enum InspectRepairSection: String, CaseIterable, Identifiable {
    case compatibility
    case metadata
    case timing
    case subtitles

    var id: Self { self }

    var title: String {
        switch self {
        case .compatibility: "Compatibility"
        case .metadata: "Metadata"
        case .timing: "Timing"
        case .subtitles: "Subtitles"
        }
    }

    var systemImage: String {
        switch self {
        case .compatibility: "checkmark.shield"
        case .metadata: "tag.slash"
        case .timing: "clock.arrow.2.circlepath"
        case .subtitles: "captions.bubble"
        }
    }

    var description: String {
        switch self {
        case .compatibility:
            "Check MP4 files for Apple playback compatibility, audio-track problems, and other issues that may need repair."
        case .metadata:
            "Find release-group names and other unwanted attribution metadata, then safely remove it without changing the media tracks."
        case .timing:
            "Check that playback starts at the beginning of each MP4 and repair timing offsets when a safe remux is possible."
        case .subtitles:
            "Find MP4 files that have no subtitles, or require at least one subtitle track that is explicitly tagged as English."
        }
    }
}

struct InspectRepairView: View {
    @State private var selectedSection: InspectRepairSection = .compatibility
    @State private var sharedInputURL: URL?

    var body: some View {
        ZStack {
            MP4ValidationView(
                isActive: selectedSection == .compatibility,
                navigationContent: AnyView(sharedNavigationContent),
                sharedInputURL: $sharedInputURL
            )
            .opacity(selectedSection == .compatibility ? 1 : 0)
            .allowsHitTesting(selectedSection == .compatibility)
            .accessibilityHidden(selectedSection != .compatibility)

            MetadataCleanerView(
                isActive: selectedSection == .metadata,
                navigationContent: AnyView(sharedNavigationContent),
                sharedInputURL: $sharedInputURL
            )
            .opacity(selectedSection == .metadata ? 1 : 0)
            .allowsHitTesting(selectedSection == .metadata)
            .accessibilityHidden(selectedSection != .metadata)

            OffsetStartCheckerView(
                isActive: selectedSection == .timing,
                navigationContent: AnyView(sharedNavigationContent),
                sharedInputURL: $sharedInputURL
            )
            .opacity(selectedSection == .timing ? 1 : 0)
            .allowsHitTesting(selectedSection == .timing)
            .accessibilityHidden(selectedSection != .timing)

            SubtitleInspectorView(
                isActive: selectedSection == .subtitles,
                navigationContent: AnyView(sharedNavigationContent),
                sharedInputURL: $sharedInputURL
            )
            .opacity(selectedSection == .subtitles ? 1 : 0)
            .allowsHitTesting(selectedSection == .subtitles)
            .accessibilityHidden(selectedSection != .subtitles)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 1_040, minHeight: 640)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleSharedDrop)
        .toolbar {
            ToolbarItem {
                Button(action: resetAll) {
                    Label("Reset All", systemImage: "arrow.counterclockwise")
                }
                .disabled(sharedInputURL == nil)
                .help("Clear the input and results from every Inspect & Repair section")
            }
        }
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedSection.title)
                .font(.title3)
                .fontWeight(.semibold)

            HStack(spacing: 2) {
                ForEach(InspectRepairSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Image(systemName: section.systemImage)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedSection == section ? Color.white : Color.primary)
                    .background {
                        if selectedSection == section {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor)
                        }
                    }
                    .accessibilityLabel(section.title)
                    .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                        .help(section.title)
                }
            }
            .padding(2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .frame(maxWidth: .infinity)

            Text(selectedSection.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sharedNavigationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            modeSelector

            GroupBox("Input") {
                ToolSelectionRow(
                    title: sharedInputTitle,
                    detail: sharedInputURL?.path ?? "Choose one MP4 file or a folder containing MP4 files",
                    isSelected: sharedInputURL != nil,
                    emptySystemImage: "folder.badge.plus",
                    selectedSystemImage: sharedInputIsFolder ? "folder.fill" : "film.stack.fill",
                    chooseLabel: "Choose…",
                    openLabel: sharedInputIsFolder ? "Open" : "Reveal",
                    chooseDisabled: false,
                    compactLayout: true,
                    openAction: revealSharedInput,
                    chooseAction: chooseSharedInput
                )
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sharedInputIsFolder: Bool {
        guard let sharedInputURL else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: sharedInputURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private var sharedInputTitle: String {
        guard sharedInputURL != nil else { return "No Input Selected" }
        return sharedInputIsFolder ? "Input Folder" : "Input MP4 File"
    }

    private func chooseSharedInput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.mpeg4Movie, .folder]
        panel.message = "Choose one MP4 file or a folder containing MP4 files"

        CleanFilePanelPresenter.present(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            sharedInputURL = url
        }
    }

    private func revealSharedInput() {
        guard let sharedInputURL else { return }
        if sharedInputIsFolder {
            NSWorkspace.shared.open(sharedInputURL)
        } else {
            NSWorkspace.shared.selectFile(
                sharedInputURL.path,
                inFileViewerRootedAtPath: sharedInputURL.deletingLastPathComponent().path
            )
        }
    }

    private func resetAll() {
        sharedInputURL = nil
        NotificationCenter.default.post(name: inspectRepairResetAllNotification, object: nil)
    }

    private func handleSharedDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                sharedInputURL = url
            }
        }
        return true
    }
}

struct InspectRepairProgressDetails: View {
    let fraction: Double
    let currentItem: Int
    let totalItems: Int
    let estimatedRemaining: TimeInterval?

    var body: some View {
        if totalItems > 0 {
            VStack(spacing: 6) {
                ProgressView(value: max(0, min(1, fraction)))

                HStack {
                    Text("\(currentItem) of \(totalItems)")
                    Spacer()
                    if let estimatedRemaining {
                        Text("About \(formatDuration(estimatedRemaining)) remaining")
                    } else {
                        Text("Estimating time remaining…")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 360)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        let hours = rounded / 3600
        let minutes = (rounded % 3600) / 60
        let remainingSeconds = rounded % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(remainingSeconds)s" }
        return "\(remainingSeconds)s"
    }
}
