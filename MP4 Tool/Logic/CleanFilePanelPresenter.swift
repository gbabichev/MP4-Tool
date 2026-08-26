import AppKit

/// Presents AppKit file panels with native sheet styling without exposing a
/// separate title bar or traffic-light controls behind the panel.
@MainActor
enum CleanFilePanelPresenter {
    private static var hostWindows: [ObjectIdentifier: NSWindow] = [:]

    static func present(
        _ panel: NSSavePanel,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        let key = ObjectIdentifier(panel)
        let hostWindow = makeHostWindow()
        hostWindows[key] = hostWindow
        hostWindow.makeKeyAndOrderFront(nil)

        panel.beginSheetModal(for: hostWindow) { response in
            Task { @MainActor in
                defer {
                    hostWindow.orderOut(nil)
                    hostWindows.removeValue(forKey: key)
                }
                completion(response)
            }
        }
    }

    private static func makeHostWindow() -> NSWindow {
        let size = NSSize(width: 640, height: 480)
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovable = false
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        return window
    }
}
