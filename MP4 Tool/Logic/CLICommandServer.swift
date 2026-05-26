//
//  CLICommandServer.swift
//  MP4 Tool
//

import Foundation
import Darwin

nonisolated struct MP4ToolCLICommand: Codable, Sendable {
    let command: String
    let paths: [String]?
    let start: Bool?
}

nonisolated struct MP4ToolCLIStatus: Codable, Sendable {
    let isProcessing: Bool
    let queueCount: Int
    let currentFileIndex: Int
    let totalFiles: Int
    let currentFile: String
    let outputFolder: String
    let ffmpegAvailable: Bool
    let processingHadError: Bool
}

nonisolated struct MP4ToolCLIResponse: Codable, Sendable {
    let success: Bool
    let message: String
    let status: MP4ToolCLIStatus?

    static func success(_ message: String, status: MP4ToolCLIStatus? = nil) -> MP4ToolCLIResponse {
        MP4ToolCLIResponse(success: true, message: message, status: status)
    }

    static func failure(_ message: String, status: MP4ToolCLIStatus? = nil) -> MP4ToolCLIResponse {
        MP4ToolCLIResponse(success: false, message: message, status: status)
    }
}

@MainActor
struct MP4ToolCLIHandler {
    let addFiles: ([String], Bool) -> MP4ToolCLIResponse
    let startProcessing: () -> MP4ToolCLIResponse
    let stopProcessing: () -> MP4ToolCLIResponse
    let clearQueue: () -> MP4ToolCLIResponse
    let status: () -> MP4ToolCLIResponse
}

@MainActor
final class CLICommandCenter {
    static let shared = CLICommandCenter()

    private var handler: MP4ToolCLIHandler?

    private init() {}

    func register(handler: MP4ToolCLIHandler) {
        self.handler = handler
    }

    func unregister() {
        handler = nil
    }

    func handle(_ command: MP4ToolCLICommand) -> MP4ToolCLIResponse {
        guard let handler else {
            return .failure("MP4 Tool main window is not ready.")
        }

        switch command.command {
        case "add":
            let paths = command.paths ?? []
            return handler.addFiles(paths, command.start ?? false)
        case "start":
            return handler.startProcessing()
        case "stop":
            return handler.stopProcessing()
        case "clear":
            return handler.clearQueue()
        case "status":
            return handler.status()
        default:
            return .failure("Unknown command: \(command.command)")
        }
    }
}

@MainActor
final class CLICommandServer {
    static let shared = CLICommandServer()

    private var listenSocket: Int32 = -1
    private var isRunning = false

    private init() {}

    func start() throws {
        guard !isRunning else { return }

        let socketPath = Self.socketPath
        try Self.ensureSocketDirectoryExists(socketPath: socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(errno, operation: "socket")
        }
        Self.setNoSigPipe(fd)

        do {
            try Self.bindSocket(fd, to: socketPath)
            guard Darwin.listen(fd, 16) == 0 else {
                throw POSIXError(errno, operation: "listen")
            }
        } catch {
            Darwin.close(fd)
            throw error
        }

        listenSocket = fd
        isRunning = true

        DispatchQueue.global(qos: .utility).async {
            Self.acceptLoop(listenSocket: fd)
        }
    }

    deinit {
        if listenSocket >= 0 {
            Darwin.close(listenSocket)
        }
    }

    nonisolated static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MP4 Tool/mp4tool.sock")
            .path
    }

    nonisolated private static func ensureSocketDirectoryExists(socketPath: String) throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated private static func bindSocket(_ fd: Int32, to socketPath: String) throws {
        try? FileManager.default.removeItem(atPath: socketPath)

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
                Darwin.bind(fd, sockaddrPointer, addressLength)
            }
        }

        guard result == 0 else {
            throw POSIXError(errno, operation: "bind")
        }
    }

    nonisolated private static func acceptLoop(listenSocket: Int32) {
        while true {
            let client = Darwin.accept(listenSocket, nil, nil)
            if client < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }
            setNoSigPipe(client)

            DispatchQueue.global(qos: .utility).async {
                Self.handleConnection(client)
            }
        }
    }

    nonisolated private static func handleConnection(_ client: Int32) {
        do {
            let command = try readCommand(from: client)
            Task.detached(priority: .utility) {
                let response = await CLICommandCenter.shared.handle(command)
                do {
                    try Self.writeResponse(response, to: client)
                } catch {
                    let message = "Failed to write CLI response: \(error.localizedDescription)"
                    await MainActor.run {
                        AppUpdateCenter.debugLog(message)
                    }
                }
                Darwin.close(client)
            }
        } catch {
            let response = MP4ToolCLIResponse.failure(error.localizedDescription)
            try? Self.writeResponse(response, to: client)
            Darwin.close(client)
        }
    }

    nonisolated private static func readCommand(from client: Int32) throws -> MP4ToolCLICommand {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = Darwin.read(client, &buffer, buffer.count)
            if bytesRead > 0 {
                data.append(contentsOf: buffer.prefix(bytesRead))
                if data.contains(0x0A) {
                    break
                }
                if data.count > 1_048_576 {
                    throw CLICommandServerError.messageTooLarge
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
            throw CLICommandServerError.emptyCommand
        }

        return try JSONDecoder().decode(MP4ToolCLICommand.self, from: data)
    }

    nonisolated private static func writeResponse(_ response: MP4ToolCLIResponse, to client: Int32) throws {
        var data = try JSONEncoder().encode(response)
        data.append(0x0A)

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }

            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(
                    client,
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

    nonisolated private static func setNoSigPipe(_ fd: Int32) {
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
}

nonisolated private struct POSIXError: LocalizedError {
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

nonisolated private enum CLICommandServerError: LocalizedError {
    case emptyCommand
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Empty CLI command"
        case .messageTooLarge:
            return "CLI command is too large"
        }
    }
}
