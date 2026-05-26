// Privileged installer helper for the MP4 Tool command line tool. It only
// creates or removes /usr/local/bin/mp4toolctl as a symlink to the bundled
// mp4toolctl executable inside this app bundle.

import Darwin
import Foundation

private let commandName = "mp4toolctl"
private let appBundleIdentifier = "com.georgebabichev.MP4-Tool"
private let allowedShellCommandPath = "/usr/local/bin/mp4toolctl"

private enum PrivilegedToolError: LocalizedError {
    case invalidArguments
    case invalidShellCommandPath(String)
    case bundledToolInvalid(String)
    case conflictingCommand(String)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The privileged tool received invalid arguments."
        case .invalidShellCommandPath(let path):
            return "The privileged tool can only manage \(allowedShellCommandPath), not \(path)."
        case .bundledToolInvalid(let path):
            return "The bundled command line tool is missing or invalid: \(path)."
        case .conflictingCommand(let path):
            return "A different command already exists at \(path). It was left unchanged."
        case .fileSystem(let message):
            return message
        }
    }
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        throw PrivilegedToolError.invalidArguments
    }

    switch command {
    case "--install-shell-command":
        guard arguments.count == 3 else { throw PrivilegedToolError.invalidArguments }
        try installShellCommand(
            bundledToolPath: arguments[1],
            installedPath: arguments[2]
        )
    case "--remove-shell-command":
        guard arguments.count == 2 else { throw PrivilegedToolError.invalidArguments }
        try removeShellCommand(installedPath: arguments[1])
    default:
        throw PrivilegedToolError.invalidArguments
    }
}

private func installShellCommand(bundledToolPath: String, installedPath: String) throws {
    guard installedPath == allowedShellCommandPath else {
        throw PrivilegedToolError.invalidShellCommandPath(installedPath)
    }

    let bundledToolURL = URL(fileURLWithPath: bundledToolPath).standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: bundledToolURL.path),
          isCurrentAppCommandLineTool(bundledToolURL) else {
        throw PrivilegedToolError.bundledToolInvalid(bundledToolPath)
    }

    let installedURL = URL(fileURLWithPath: installedPath)
    let directoryURL = installedURL.deletingLastPathComponent()

    do {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: installedURL.path) {
            let resolvedDestination = resolvedSymlinkDestination(destination, relativeTo: installedURL)
            guard isMP4ToolHelperCommandLineTool(resolvedDestination) else {
                throw PrivilegedToolError.conflictingCommand(installedURL.path)
            }
            try FileManager.default.removeItem(at: installedURL)
        } else if FileManager.default.fileExists(atPath: installedURL.path) {
            throw PrivilegedToolError.conflictingCommand(installedURL.path)
        }

        try FileManager.default.createSymbolicLink(at: installedURL, withDestinationURL: bundledToolURL)
    } catch let error as PrivilegedToolError {
        throw error
    } catch {
        throw PrivilegedToolError.fileSystem(error.localizedDescription)
    }
}

private func removeShellCommand(installedPath: String) throws {
    guard installedPath == allowedShellCommandPath else {
        throw PrivilegedToolError.invalidShellCommandPath(installedPath)
    }

    let installedURL = URL(fileURLWithPath: installedPath)
    guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: installedURL.path) else {
        if FileManager.default.fileExists(atPath: installedURL.path) {
            throw PrivilegedToolError.conflictingCommand(installedURL.path)
        }
        return
    }

    let resolvedDestination = resolvedSymlinkDestination(destination, relativeTo: installedURL)
    guard isMP4ToolHelperCommandLineTool(resolvedDestination) else {
        throw PrivilegedToolError.conflictingCommand(installedURL.path)
    }

    do {
        try FileManager.default.removeItem(at: installedURL)
    } catch {
        throw PrivilegedToolError.fileSystem(error.localizedDescription)
    }
}

private func isCurrentAppCommandLineTool(_ url: URL) -> Bool {
    guard isMP4ToolHelperCommandLineTool(url),
          let helperAppURL = containingAppBundle(for: url),
          let currentAppURL = currentExecutableAppBundle() else {
        return false
    }

    return helperAppURL.standardizedFileURL.resolvingSymlinksInPath() == currentAppURL.standardizedFileURL.resolvingSymlinksInPath()
}

private func isMP4ToolHelperCommandLineTool(_ url: URL) -> Bool {
    guard url.lastPathComponent == commandName,
          url.pathComponents.contains("Helpers"),
          let appURL = containingAppBundle(for: url) else {
        return false
    }

    return bundleIdentifier(for: appURL) == appBundleIdentifier
}

private func currentExecutableAppBundle() -> URL? {
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .standardizedFileURL
        .resolvingSymlinksInPath()
    return containingAppBundle(for: executableURL)
}

private func containingAppBundle(for url: URL) -> URL? {
    var cursor = url.deletingLastPathComponent()
    while cursor.path != "/" {
        if cursor.pathExtension == "app" {
            return cursor
        }
        cursor.deleteLastPathComponent()
    }
    return nil
}

private func resolvedSymlinkDestination(_ destination: String, relativeTo installedURL: URL) -> URL {
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

private func bundleIdentifier(for appURL: URL) -> String? {
    let infoPlistURL = appURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Info.plist")
    return NSDictionary(contentsOf: infoPlistURL)?["CFBundleIdentifier"] as? String
}

do {
    try run()
    print("OK")
    exit(EXIT_SUCCESS)
} catch {
    print("ERROR\t\(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
