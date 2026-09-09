import AppKit

/// Presents AppKit file panels as native sheets on the active app window.
@MainActor
enum CleanFilePanelPresenter {
    static func present(
        _ panel: NSSavePanel,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        guard let hostWindow = activeAppWindow else {
            panel.begin { response in
                Task { @MainActor in
                    completion(response)
                }
            }
            return
        }

        panel.beginSheetModal(for: hostWindow) { response in
            Task { @MainActor in
                completion(response)
            }
        }
    }

    private static var activeAppWindow: NSWindow? {
        if let keyWindow = NSApp.keyWindow,
           keyWindow.isVisible,
           !(keyWindow is NSPanel) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow,
           mainWindow.isVisible,
           !(mainWindow is NSPanel) {
            return mainWindow
        }
        return NSApp.orderedWindows.first {
            $0.isVisible && !($0 is NSPanel)
        }
    }
}
