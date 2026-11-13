import Foundation

/// Finds bundled command-line tools. Never falls back to $PATH, so the app only runs what it ships.
public struct ToolLocator: Sendable {
    public var directories: [URL]

    public init(directories: [URL]) {
        self.directories = directories
    }

    /// `$SQUISH_BIN_DIR` (development) first, then `Contents/Resources/bin`.
    public static var standard: ToolLocator {
        var directories: [URL] = []
        if let dir = ProcessInfo.processInfo.environment["SQUISH_BIN_DIR"] {
            directories.append(URL(filePath: dir, directoryHint: .isDirectory))
        }
        if let resources = Bundle.main.resourceURL {
            directories.append(resources.appending(path: "bin", directoryHint: .isDirectory))
        }
        return ToolLocator(directories: directories)
    }

    public func url(for tool: String) throws(SquishError) -> URL {
        for directory in directories {
            let url = directory.appending(path: tool)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw .missingTool(tool)
    }
}

public enum ToolRunner {
    /// Runs `tool` to completion. Throws `toolFailed` with the tail of stderr on a non-zero exit.
    public static func run(_ tool: URL, _ arguments: [String]) async throws {
        // stderr goes to a file: a pipe nobody drains deadlocks once it fills.
        let stderrURL = FileManager.default.temporaryDirectory.appending(path: "squish-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }

        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()

        guard status == 0 else {
            let message = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            throw SquishError.toolFailed(
                tool: tool.lastPathComponent,
                status: status,
                // First line only: tools put the useful part there and the rest is noise in a toast.
                message: String(message.split(whereSeparator: \.isNewline).first?.prefix(160) ?? "")
            )
        }
    }
}
