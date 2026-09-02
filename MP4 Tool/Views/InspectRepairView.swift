import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
        .frame(minWidth: 860, minHeight: 640)
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleSharedDrop)
    }

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Inspect & Repair", systemImage: "stethoscope")
                .font(.headline)

            Picker("Inspection Type", selection: $selectedSection) {
                ForEach(InspectRepairSection.allCases) { section in
                    Text(section.title)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
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
