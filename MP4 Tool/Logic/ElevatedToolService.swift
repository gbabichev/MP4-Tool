import Foundation

enum ElevatedToolService {
    enum ElevatedToolError: LocalizedError, Sendable {
        case bundledToolMissing(URL)
        case launchFailed(String)
        case operationFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledToolMissing(let url):
                return "The bundled privileged tool was not found at \(url.path)."
            case .launchFailed(let message):
                return message
            case .operationFailed(let message):
                return message
            }
        }
    }

    static func runPrivileged(arguments: [String], prompt: String) async throws {
        let runnerURL = try bundledHelper(named: "MP4ToolElevationRunner")
        let toolURL = try bundledHelper(named: "MP4ToolPrivilegedTool")

        try await Task.detached(priority: .userInitiated) {
            try runBlocking(
                runnerURL: runnerURL,
                toolURL: toolURL,
                arguments: arguments,
                prompt: prompt
            )
        }.value
    }

    private static func bundledHelper(named name: String) throws -> URL {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent(name)

        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ElevatedToolError.bundledToolMissing(url)
        }

        return url
    }

    nonisolated private static func runBlocking(
        runnerURL: URL,
        toolURL: URL,
        arguments: [String],
        prompt: String
    ) throws {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()

        process.executableURL = runnerURL
        process.arguments = ["--prompt", prompt, "--", toolURL.path] + arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw ElevatedToolError.launchFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let output = String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0, output == "OK" else {
            if output.hasPrefix("ERROR\t") {
                throw ElevatedToolError.operationFailed(String(output.dropFirst("ERROR\t".count)))
            }

            let message = output.isEmpty ? errorOutput : output
            throw ElevatedToolError.operationFailed(
                message.isEmpty ? "The privileged operation failed." : message
            )
        }
    }
}
