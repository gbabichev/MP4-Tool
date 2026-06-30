//
//  WindowCommandRegistry.swift
//  MP4 Tool
//

@preconcurrency import SwiftUI
@preconcurrency import AppKit
import Combine

struct WindowCommandActions {
    let openInputFolder: () -> Void
    let selectOutputFolder: () -> Void
    let clearFolders: () -> Void
    let startProcessing: () -> Void
    let exportLog: () -> Void
    let showTutorial: () -> Void
    let showAbout: () -> Void
    let toggleFFmpegSource: () -> Void
}

struct WindowCommandAvailability: Equatable {
    var canStartProcessing = false
    var isProcessing = false
    var canClearFolders = false
    var canExportLog = false
    var canToggleFFmpeg = false
}

@MainActor
final class WindowCommandRegistry: ObservableObject {
    private struct Entry {
        var actions: WindowCommandActions
        var availability: WindowCommandAvailability
    }

    @Published private(set) var activeWindowID: UUID?
    @Published private(set) var activeAvailability = WindowCommandAvailability()
    @Published private(set) var hasActiveWindow = false

    private var entries: [UUID: Entry] = [:]

    var activeActions: WindowCommandActions? {
        guard let activeWindowID else { return nil }
        return entries[activeWindowID]?.actions
    }

    func register(
        windowID: UUID,
        actions: WindowCommandActions,
        availability: WindowCommandAvailability
    ) {
        entries[windowID] = Entry(actions: actions, availability: availability)
        if activeWindowID == nil {
            setActiveWindow(windowID)
        } else if activeWindowID == windowID {
            publishActiveState()
        }
    }

    func updateAvailability(_ availability: WindowCommandAvailability, for windowID: UUID) {
        guard var entry = entries[windowID] else { return }
        entry.availability = availability
        entries[windowID] = entry
        if activeWindowID == windowID {
            publishActiveState()
        }
    }

    func setActiveWindow(_ windowID: UUID) {
        guard entries[windowID] != nil else { return }
        activeWindowID = windowID
        publishActiveState()
    }

    func unregister(windowID: UUID) {
        entries.removeValue(forKey: windowID)

        if activeWindowID == windowID {
            activeWindowID = entries.keys.first
        }

        publishActiveState()
    }

    private func publishActiveState() {
        if let activeWindowID, let entry = entries[activeWindowID] {
            activeAvailability = entry.availability
            hasActiveWindow = true
        } else {
            activeAvailability = WindowCommandAvailability()
            hasActiveWindow = false
        }
    }
}

struct WindowActivationObserver: NSViewRepresentable {
    let windowID: UUID
    @ObservedObject var registry: WindowCommandRegistry

    func makeCoordinator() -> Coordinator {
        Coordinator(windowID: windowID, registry: registry)
    }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindowChange = { window in
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        context.coordinator.registry = registry
        context.coordinator.attach(to: nsView.window)
    }

    final class Coordinator {
        let windowID: UUID
        var registry: WindowCommandRegistry
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(windowID: UUID, registry: WindowCommandRegistry) {
            self.windowID = windowID
            self.registry = registry
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            window = newWindow

            guard let newWindow else { return }
            if newWindow.isKeyWindow || newWindow.isMainWindow {
                registry.setActiveWindow(windowID)
            }

            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: newWindow,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        self.registry.setActiveWindow(self.windowID)
                    }
                }
            )
            observers.append(
                center.addObserver(
                    forName: NSWindow.didBecomeMainNotification,
                    object: newWindow,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        self.registry.setActiveWindow(self.windowID)
                    }
                }
            )
        }
    }
}

final class WindowProbeView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.onWindowChange?(self?.window)
        }
    }
}
