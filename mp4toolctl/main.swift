//
//  main.swift
//  mp4toolctl
//
//  User-facing controller for the running MP4 Tool app.

import Foundation
import Darwin

private struct MP4ToolCLICommand: Codable {
    let command: String
    let paths: [String]?
    let start: Bool?
    let preset: String?
    let outputFolder: String?
}

private struct MP4ToolCLIPreset: Codable {
    let name: String
    let isBuiltIn: Bool
    let isSelected: Bool
}

private struct MP4ToolCLIQueueItem: Codable {
    let index: Int
    let fileName: String
    let filePath: String
    let status: String
}

private struct MP4ToolCLIStatus: Codable, Equatable {
    let isProcessing: Bool
    let queueCount: Int
    let currentFileIndex: Int
    let totalFiles: Int
    let currentFile: String
    let currentFileETASeconds: Int?
    let totalETASeconds: Int?
    let outputFolder: String
    let ffmpegAvailable: Bool
    let processingHadError: Bool
    let selectedPreset: String?
    let activeMode: String?
    let currentFileProgress: Double
    let overallProgress: Double
    let elapsedSeconds: Int
    let pendingCount: Int
    let completedCount: Int
    let skippedCount: Int
    let failedCount: Int
    let stopAfterCurrentFileRequested: Bool
}

private struct MP4ToolCLIResponse: Codable {
    let success: Bool
    let message: String
    let status: MP4ToolCLIStatus?
    let presets: [MP4ToolCLIPreset]?
    let queue: [MP4ToolCLIQueueItem]?
}

private enum LocalAction {
    case send(MP4ToolCLICommand)
    case watch
    case wait
}

private struct Invocation {
    let action: LocalAction
    let json: Bool
    let displayKind: String
}

private enum CLIError: LocalizedError {
    case usage(String)
    case emptyResponse
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .usage(let message): return message
        case .emptyResponse: return "MP4 Tool returned an empty response."
        case .messageTooLarge: return "MP4 Tool response was too large."
        }
    }
}

private struct POSIXError: LocalizedError {
    let code: Int32
    let operation: String

    init(_ code: Int32, operation: String) {
        self.code = code
        self.operation = operation
    }

    var errorDescription: String? {
        "\(operation) failed: \(String(cString: strerror(code)))"
    }
}

nonisolated private var socketPath: String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MP4 Tool/mp4tool.sock")
        .path
}

private func printUsage() {
    print(
        """
        Usage:
          mp4toolctl presets [--json]
          mp4toolctl use <preset-name> [--json]
          mp4toolctl add [--start] <file-or-folder> [...] [--json]
          mp4toolctl run [--preset <name>] [--output <folder>] <file-or-folder> [...] [--json]
          mp4toolctl queue [--json]
          mp4toolctl status [--watch] [--json]
          mp4toolctl start [--json]
          mp4toolctl stop [--after-current] [--json]
          mp4toolctl resume [--json]
          mp4toolctl wait [--json]
          mp4toolctl clear [--json]

        Notes:
          MP4 Tool must be running in the same macOS user session.
          Commands control the app's shared queue and settings; encoding remains in the app.
          run uses the current preset and output folder unless they are supplied explicitly.
          resume cancels a pending "stop after current file" request.
        """
    )
}

private func parseInvocation(arguments: [String]) throws -> Invocation {
    let json = arguments.contains("--json")
    let filtered = arguments.filter { $0 != "--json" }
    guard let subcommand = filtered.first else { throw CLIError.usage("Missing command.") }
    let rest = Array(filtered.dropFirst())

    func command(
        _ name: String,
        paths: [String]? = nil,
        start: Bool? = nil,
        preset: String? = nil,
        outputFolder: String? = nil
    ) -> MP4ToolCLICommand {
        MP4ToolCLICommand(
            command: name,
            paths: paths,
            start: start,
            preset: preset,
            outputFolder: outputFolder
        )
    }

    switch subcommand {
    case "presets", "queue", "start", "resume", "clear":
        guard rest.isEmpty else { throw CLIError.usage("\(subcommand) does not accept additional arguments.") }
        return Invocation(action: .send(command(subcommand)), json: json, displayKind: subcommand)

    case "use":
        guard !rest.isEmpty else { throw CLIError.usage("use requires a preset name.") }
        return Invocation(
            action: .send(command("use", preset: rest.joined(separator: " "))),
            json: json,
            displayKind: "use"
        )

    case "add":
        let shouldStart = rest.contains("--start")
        let paths = rest.filter { $0 != "--start" }.map(absolutePath)
        guard !paths.isEmpty else { throw CLIError.usage("add requires at least one file or folder path.") }
        return Invocation(
            action: .send(command("add", paths: paths, start: shouldStart)),
            json: json,
            displayKind: "add"
        )

    case "run":
        var preset: String?
        var outputFolder: String?
        var paths: [String] = []
        var index = 0
        while index < rest.count {
            switch rest[index] {
            case "--preset":
                index += 1
                guard index < rest.count else { throw CLIError.usage("--preset requires a name.") }
                preset = rest[index]
            case "--output":
                index += 1
                guard index < rest.count else { throw CLIError.usage("--output requires a folder.") }
                outputFolder = absolutePath(for: rest[index])
            default:
                paths.append(absolutePath(for: rest[index]))
            }
            index += 1
        }
        guard !paths.isEmpty else { throw CLIError.usage("run requires at least one file or folder path.") }
        return Invocation(
            action: .send(command("run", paths: paths, preset: preset, outputFolder: outputFolder)),
            json: json,
            displayKind: "run"
        )

    case "stop":
        guard rest.isEmpty || rest == ["--after-current"] else {
            throw CLIError.usage("stop accepts only --after-current.")
        }
        let name = rest.isEmpty ? "stop" : "stopAfterCurrent"
        return Invocation(action: .send(command(name)), json: json, displayKind: "stop")

    case "status":
        guard rest.isEmpty || rest == ["--watch"] else {
            throw CLIError.usage("status accepts only --watch.")
        }
        return Invocation(action: rest.isEmpty ? .send(command("status")) : .watch, json: json, displayKind: "status")

    case "wait":
        guard rest.isEmpty else { throw CLIError.usage("wait does not accept additional arguments.") }
        return Invocation(action: .wait, json: json, displayKind: "wait")

    case "help", "--help", "-h":
        printUsage()
        exit(0)
    default:
        throw CLIError.usage("Unknown command: \(subcommand)")
    }
}

private func absolutePath(for argument: String) -> String {
    let expandedPath = (argument as NSString).expandingTildeInPath
    if expandedPath.hasPrefix("/") {
        return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
    }
    return URL(
        fileURLWithPath: expandedPath,
        relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ).standardizedFileURL.path
}

private func statusCommand() -> MP4ToolCLICommand {
    MP4ToolCLICommand(command: "status", paths: nil, start: nil, preset: nil, outputFolder: nil)
}

private func printResponse(_ response: MP4ToolCLIResponse, kind: String, json: Bool, compactJSON: Bool = false) throws {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = compactJSON ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        print(String(decoding: data, as: UTF8.self))
    } else if kind == "status", let status = response.status {
        print(formatStatus(status))
    } else {
        print(response.message)
    }
}

private func formatStatus(_ status: MP4ToolCLIStatus) -> String {
    var lines: [String] = []
    if status.isProcessing {
        let percent = Int((status.overallProgress * 100).rounded())
        lines.append("Processing \(status.currentFileIndex)/\(status.totalFiles) · \(percent)%")
        if !status.currentFile.isEmpty { lines.append("Current: \(status.currentFile)") }
        if let mode = status.activeMode { lines.append("Mode: \(mode)") }
        lines.append("Elapsed: \(formatDuration(status.elapsedSeconds))")
        lines.append("ETA: \(status.totalETASeconds.map(formatDuration) ?? "calculating")")
        if status.stopAfterCurrentFileRequested { lines.append("Stop after current file: requested") }
    } else {
        lines.append(status.processingHadError ? "Idle · last run needs attention" : "Idle")
    }
    lines.append("Queue: \(status.queueCount) (\(status.pendingCount) pending, \(status.completedCount) completed, \(status.skippedCount) skipped, \(status.failedCount) failed)")
    lines.append("Preset: \(status.selectedPreset ?? "Custom Settings")")
    lines.append("Output: \(status.outputFolder.isEmpty ? "not selected" : status.outputFolder)")
    lines.append("FFmpeg: \(status.ffmpegAvailable ? "available" : "not available")")
    return lines.joined(separator: "\n")
}

private func formatDuration(_ seconds: Int) -> String {
    let seconds = max(seconds, 0)
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainder = seconds % 60
    if hours > 0 { return "\(hours)h \(minutes)m \(remainder)s" }
    if minutes > 0 { return "\(minutes)m \(remainder)s" }
    return "\(remainder)s"
}

private func watchStatus(json: Bool) throws -> Never {
    var previous: MP4ToolCLIStatus?
    while true {
        let response = try send(command: statusCommand())
        if let status = response.status, status != previous {
            if json {
                try printResponse(response, kind: "status", json: true, compactJSON: true)
            } else {
                if isatty(STDOUT_FILENO) != 0 { print("\u{001B}[2J\u{001B}[H", terminator: "") }
                print(formatStatus(status))
            }
            fflush(stdout)
            previous = status
        }
        Thread.sleep(forTimeInterval: 1)
    }
}

private func waitForCompletion(json: Bool) throws -> Int32 {
    var sawProcessing = false
    var idlePolls = 0
    var lastResponse: MP4ToolCLIResponse?

    while true {
        let response = try send(command: statusCommand())
        lastResponse = response
        guard let status = response.status else { break }
        if status.isProcessing {
            sawProcessing = true
            idlePolls = 0
        } else if sawProcessing {
            break
        } else {
            idlePolls += 1
            if idlePolls >= 4 { break }
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    guard let response = lastResponse else { throw CLIError.emptyResponse }
    try printResponse(response, kind: "status", json: json)
    return response.status?.processingHadError == true ? 1 : 0
}

private func send(command: MP4ToolCLICommand) throws -> MP4ToolCLIResponse {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(errno, operation: "socket") }
    setNoSigPipe(fd)
    defer { Darwin.close(fd) }

    try connectSocket(fd, to: socketPath)
    var requestData = try JSONEncoder().encode(command)
    requestData.append(0x0A)
    try writeAll(requestData, to: fd)
    Darwin.shutdown(fd, SHUT_WR)
    return try JSONDecoder().decode(MP4ToolCLIResponse.self, from: readResponse(from: fd))
}

private func connectSocket(_ fd: Int32, to socketPath: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= pathCapacity else { throw POSIXError(ENAMETOOLONG, operation: "socket path") }

    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { pathPointer in
            for index in 0..<pathBytes.count { pathPointer[index] = CChar(pathBytes[index]) }
        }
    }

    let addressLength = socklen_t(
        MemoryLayout.size(ofValue: address.sun_len) +
        MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count
    )
    address.sun_len = UInt8(addressLength)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, addressLength)
        }
    }
    guard result == 0 else {
        if errno == ENOENT || errno == ECONNREFUSED {
            throw CLIError.usage("MP4 Tool is not running or the CLI server is unavailable.")
        }
        throw POSIXError(errno, operation: "connect")
    }
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var written = 0
        while written < data.count {
            let result = Darwin.write(fd, baseAddress.advanced(by: written), data.count - written)
            if result > 0 { written += result }
            else if result < 0 && errno == EINTR { continue }
            else { throw POSIXError(errno, operation: "write") }
        }
    }
}

private func readResponse(from fd: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
            data.append(contentsOf: buffer.prefix(count))
            if data.contains(0x0A) { break }
            if data.count > 1_048_576 { throw CLIError.messageTooLarge }
        } else if count == 0 { break }
        else if errno == EINTR { continue }
        else { throw POSIXError(errno, operation: "read") }
    }
    if let newline = data.firstIndex(of: 0x0A) { data = data[..<newline] }
    guard !data.isEmpty else { throw CLIError.emptyResponse }
    return data
}

private func setNoSigPipe(_ fd: Int32) {
    var value: Int32 = 1
    _ = withUnsafePointer(to: &value) {
        Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
    }
}

do {
    let invocation = try parseInvocation(arguments: Array(CommandLine.arguments.dropFirst()))
    switch invocation.action {
    case .send(let command):
        let response = try send(command: command)
        try printResponse(response, kind: invocation.displayKind, json: invocation.json)
        exit(response.success ? 0 : 1)
    case .watch:
        try watchStatus(json: invocation.json)
    case .wait:
        exit(try waitForCompletion(json: invocation.json))
    }
} catch {
    fputs("mp4toolctl: \(error.localizedDescription)\n", stderr)
    exit(2)
}
