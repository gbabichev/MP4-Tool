import AppKit
import Foundation

@MainActor
enum CommandLineToolInstaller {
    private static let commandName = "mp4toolctl"
    private static let installURL = URL(fileURLWithPath: "/usr/local/bin/mp4toolctl")

    enum InstallResult {
        case installed(URL)
        case updated(URL)
        case alreadyInstalled(URL)

        var title: String {
            switch self {
            case .installed:
                return "Command Line Tool Installed"
            case .updated:
                return "Command Line Tool Updated"
            case .alreadyInstalled:
                return "Command Line Tool Already Installed"
            }
        }

        var message: String {
            "You can now run `mp4toolctl status` or `mp4toolctl add --start file.mkv` from Terminal.\n\nInstalled at \(installedURL.path)."
        }

        private var installedURL: URL {
            switch self {
            case .installed(let url), .updated(let url), .alreadyInstalled(let url):
                return url
            }
        }
    }

    enum RemovalResult {
        case removed(URL)
        case notInstalled

        var title: String {
            switch self {
            case .removed:
                return "Command Line Tool Removed"
            case .notInstalled:
                return "Command Line Tool Not Installed"
            }
        }

        var message: String {
            switch self {
            case .removed(let url):
                return "`mp4toolctl` was removed from \(url.deletingLastPathComponent().path)."
            case .notInstalled:
                return "No MP4 Tool command line tool is installed."
            }
        }
    }

    enum InstallError: LocalizedError {
        case bundledToolMissing(URL)
        case conflictingCommand(URL)
        case authorizationCancelled
        case privilegedInstallFailed(String)
        case fileSystem(URL, String)

        var errorDescription: String? {
            switch self {
            case .bundledToolMissing(let url):
                return "The bundled command line tool was not found at \(url.path)."
            case .conflictingCommand(let url):
                return "A different command already exists at \(url.path). It was left unchanged."
            case .authorizationCancelled:
                return "The command line tool was not changed because authorization was cancelled."
            case .privilegedInstallFailed(let message):
                return message
            case .fileSystem(let url, let message):
                return "Could not update \(url.path): \(message)"
            }
        }
    }

    static var canRemoveInstalledTool: Bool {
        guard let bundledToolURL = try? bundledTool(),
              let state = try? existingCommandState(bundledToolURL: bundledToolURL) else {
            return false
        }

        switch state {
        case .current, .replaceable:
            return true
        case .absent, .conflict:
            return false
        }
    }

    static func installFromMenu() async {
        do {
            let result = try await install()
            showAlert(title: result.title, message: result.message, style: .informational)
        } catch {
            showAlert(
                title: "Could Not Install Command Line Tool",
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    static func removeFromMenu() async {
        do {
            let result = try await remove()
            showAlert(title: result.title, message: result.message, style: .informational)
        } catch {
            showAlert(
                title: "Could Not Remove Command Line Tool",
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    @discardableResult
    static func install() async throws -> InstallResult {
        let bundledToolURL = try bundledTool()

        switch try existingCommandState(bundledToolURL: bundledToolURL) {
        case .current:
            return .alreadyInstalled(installURL)
        case .conflict:
            throw InstallError.conflictingCommand(installURL)
        case .absent:
            try await installSymlink(to: bundledToolURL, replacingExistingItem: false)
            return .installed(installURL)
        case .replaceable:
            try await installSymlink(to: bundledToolURL, replacingExistingItem: true)
            return .updated(installURL)
        }
    }

    @discardableResult
    static func remove() async throws -> RemovalResult {
        let bundledToolURL = try bundledTool()

        switch try existingCommandState(bundledToolURL: bundledToolURL) {
        case .absent:
            return .notInstalled
        case .conflict:
            throw InstallError.conflictingCommand(installURL)
        case .current, .replaceable:
            try await removeInstalledSymlink()
            return .removed(installURL)
        }
    }

    private enum ExistingCommandState {
        case absent
        case current
        case replaceable
        case conflict
    }

    private static func bundledTool() throws -> URL {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent(commandName)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw InstallError.bundledToolMissing(url)
        }
        return url
    }

    private static func existingCommandState(bundledToolURL: URL) throws -> ExistingCommandState {
        let fileManager = FileManager.default
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: installURL.path) {
            let resolvedDestination = resolvedSymlinkDestination(destination, relativeTo: installURL)
            if resolvedDestination == bundledToolURL.resolvingSymlinksInPath() {
                return .current
            }
            return isMP4ToolHelperSymlinkTarget(resolvedDestination) ? .replaceable : .conflict
        }

        if fileManager.fileExists(atPath: installURL.path) {
            return .conflict
        }

        return .absent
    }

    private static func installSymlink(
        to bundledToolURL: URL,
        replacingExistingItem: Bool
    ) async throws {
        do {
            try installSymlinkWithoutPrivileges(
                to: bundledToolURL,
                replacingExistingItem: replacingExistingItem
            )
        } catch {
            guard confirmPrivilegedInstall(replacingExistingItem: replacingExistingItem) else {
                throw InstallError.authorizationCancelled
            }
            try await installSymlinkWithPrivileges(to: bundledToolURL)
        }
    }

    private static func installSymlinkWithoutPrivileges(
        to bundledToolURL: URL,
        replacingExistingItem: Bool
    ) throws {
        do {
            let fileManager = FileManager.default
            let directoryURL = installURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if replacingExistingItem {
                try fileManager.removeItem(at: installURL)
            }
            try fileManager.createSymbolicLink(at: installURL, withDestinationURL: bundledToolURL)
        } catch {
            throw InstallError.fileSystem(installURL, error.localizedDescription)
        }
    }

    private static func installSymlinkWithPrivileges(to bundledToolURL: URL) async throws {
        do {
            try await ElevatedToolService.runPrivileged(
                arguments: ["--install-shell-command", bundledToolURL.path, installURL.path],
                prompt: "MP4 Tool needs administrator permission to install /usr/local/bin/mp4toolctl."
            )
        } catch {
            throw InstallError.privilegedInstallFailed(error.localizedDescription)
        }
    }

    private static func removeInstalledSymlink() async throws {
        do {
            try FileManager.default.removeItem(at: installURL)
        } catch {
            guard confirmPrivilegedRemoval() else {
                throw InstallError.authorizationCancelled
            }
            try await removeInstalledSymlinkWithPrivileges()
        }
    }

    private static func removeInstalledSymlinkWithPrivileges() async throws {
        do {
            try await ElevatedToolService.runPrivileged(
                arguments: ["--remove-shell-command", installURL.path],
                prompt: "MP4 Tool needs administrator permission to remove /usr/local/bin/mp4toolctl."
            )
        } catch {
            throw InstallError.privilegedInstallFailed(error.localizedDescription)
        }
    }

    private static func resolvedSymlinkDestination(_ destination: String, relativeTo installedURL: URL) -> URL {
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = installedURL
                .deletingLastPathComponent()
                .appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isMP4ToolHelperSymlinkTarget(_ url: URL) -> Bool {
        guard url.lastPathComponent == commandName,
              url.pathComponents.contains("Helpers"),
              let appURL = containingAppBundle(for: url) else {
            return false
        }

        return bundleIdentifier(for: appURL) == Bundle.main.bundleIdentifier
    }

    private static func containingAppBundle(for url: URL) -> URL? {
        var cursor = url.deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.pathExtension == "app" {
                return cursor
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    private static func bundleIdentifier(for appURL: URL) -> String? {
        let infoPlistURL = appURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
        return NSDictionary(contentsOf: infoPlistURL)?["CFBundleIdentifier"] as? String
    }

    private static func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func confirmPrivilegedInstall(replacingExistingItem: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = replacingExistingItem
            ? "Update Command Line Tool?"
            : "Install Command Line Tool?"
        alert.informativeText = """
        MP4 Tool needs administrator permission to \(replacingExistingItem ? "update" : "install") /usr/local/bin/mp4toolctl.

        MP4 Tool will only create a symbolic link to the command line tool inside this app.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: replacingExistingItem ? "Update" : "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func confirmPrivilegedRemoval() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Remove Command Line Tool?"
        alert.informativeText = "MP4 Tool needs administrator permission to remove /usr/local/bin/mp4toolctl."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
