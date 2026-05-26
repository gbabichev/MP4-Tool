//
//  main.swift
//  mp4toolctl
//
//  User-facing CLI for sending queue and processing commands to the running
//  MP4 Tool app over its local Unix-domain socket.

import Foundation
import Darwin

private struct MP4ToolCLICommand: Codable {
    let command: String
    let paths: [String]?
    let start: Bool?
}

private struct MP4ToolCLIStatus: Codable {
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
}

private struct MP4ToolCLIResponse: Codable {
    let success: Bool
    let message: String
    let status: MP4ToolCLIStatus?
}

private enum CLIError: LocalizedError {
    case usage(String)
    case emptyResponse
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .emptyResponse:
            return "MP4 Tool returned an empty response."
        case .messageTooLarge:
            return "MP4 Tool response was too large."
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
          mp4toolctl add [--start] <file-or-folder> [...]
          mp4toolctl start
          mp4toolctl stop
          mp4toolctl clear
          mp4toolctl status

        Notes:
          MP4 Tool must be running in the same macOS user session.
          start uses the current GUI settings and output folder.
        """
    )
}

private func parseCommand(arguments: [String]) throws -> MP4ToolCLICommand {
    guard let subcommand = arguments.first else {
        throw CLIError.usage("Missing command.")
    }

    switch subcommand {
    case "add":
        var shouldStart = false
        var paths: [String] = []

        for argument in arguments.dropFirst() {
            if argument == "--start" {
                shouldStart = true
            } else {
                paths.append(absolutePath(for: argument))
            }
        }

        guard !paths.isEmpty else {
            throw CLIError.usage("add requires at least one file or folder path.")
        }

        return MP4ToolCLICommand(command: "add", paths: paths, start: shouldStart)
    case "start", "stop", "clear", "status":
        guard arguments.count == 1 else {
            throw CLIError.usage("\(subcommand) does not accept additional arguments.")
        }
        return MP4ToolCLICommand(command: subcommand, paths: nil, start: nil)
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

    return URL(fileURLWithPath: expandedPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL
        .path
}

private func send(command: MP4ToolCLICommand) throws -> MP4ToolCLIResponse {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw POSIXError(errno, operation: "socket")
    }
    setNoSigPipe(fd)
    defer { Darwin.close(fd) }

    try connectSocket(fd, to: socketPath)

    var requestData = try JSONEncoder().encode(command)
    requestData.append(0x0A)
    try writeAll(requestData, to: fd)
    Darwin.shutdown(fd, SHUT_WR)

    let responseData = try readResponse(from: fd)
    return try JSONDecoder().decode(MP4ToolCLIResponse.self, from: responseData)
}

private func connectSocket(_ fd: Int32, to socketPath: String) throws {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = Array(socketPath.utf8CString)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= pathCapacity else {
        throw POSIXError(ENAMETOOLONG, operation: "socket path")
    }

    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { pathPointer in
            for index in 0..<pathBytes.count {
                pathPointer[index] = CChar(pathBytes[index])
            }
        }
    }

    let addressLength = socklen_t(
        MemoryLayout.size(ofValue: address.sun_len) +
        MemoryLayout.size(ofValue: address.sun_family) +
        pathBytes.count
    )
    address.sun_len = UInt8(addressLength)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.connect(fd, sockaddrPointer, addressLength)
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

        var bytesWritten = 0
        while bytesWritten < data.count {
            let result = Darwin.write(
                fd,
                baseAddress.advanced(by: bytesWritten),
                data.count - bytesWritten
            )

            if result > 0 {
                bytesWritten += result
            } else if result < 0 && errno == EINTR {
                continue
            } else {
                throw POSIXError(errno, operation: "write")
            }
        }
    }
}

private func readResponse(from fd: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)

    while true {
        let bytesRead = Darwin.read(fd, &buffer, buffer.count)
        if bytesRead > 0 {
            data.append(contentsOf: buffer.prefix(bytesRead))
            if data.contains(0x0A) {
                break
            }
            if data.count > 1_048_576 {
                throw CLIError.messageTooLarge
            }
        } else if bytesRead == 0 {
            break
        } else if errno == EINTR {
            continue
        } else {
            throw POSIXError(errno, operation: "read")
        }
    }

    if let newlineIndex = data.firstIndex(of: 0x0A) {
        data = data[..<newlineIndex]
    }

    guard !data.isEmpty else {
        throw CLIError.emptyResponse
    }

    return data
}

private func setNoSigPipe(_ fd: Int32) {
    var value: Int32 = 1
    _ = withUnsafePointer(to: &value) { pointer in
        Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            pointer,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }
}

do {
    let command = try parseCommand(arguments: Array(CommandLine.arguments.dropFirst()))
    let response = try send(command: command)
    print(response.message)
    exit(response.success ? 0 : 1)
} catch {
    fputs("mp4toolctl: \(error.localizedDescription)\n", stderr)
    printUsage()
    exit(2)
}
