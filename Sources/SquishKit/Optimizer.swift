import Foundation
import os
import UniformTypeIdentifiers

public enum SquishError: Error, Equatable, Sendable, LocalizedError {
    case missingTool(String)
    case toolFailed(tool: String, status: Int32, message: String)
    case unsupported(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .missingTool(let name): "\(name) is missing from the app. Reinstall Squish."
        case .toolFailed(let tool, let status, let message):
            "\(tool) stopped with code \(status)" + (message.isEmpty ? "." : ": \(message)")
        case .unsupported(let type): "Squish can't optimize \(type) files yet."
        case .io(let message): message
        }
    }
}

public struct OptimizationResult: Identifiable, Sendable {
    public let id = UUID()
    public let file: URL
    public let originalSize: Int
    public let newSize: Int
    public let duration: Duration
    public let error: SquishError?
    /// Set when the original was replaced. Pass to `BackupStore.restore`.
    public private(set) var backup: URL?
    public let date = Date.now

    public init(file: URL, originalSize: Int, newSize: Int, duration: Duration, error: SquishError? = nil, backup: URL? = nil) {
        self.file = file
        self.originalSize = originalSize
        self.newSize = newSize
        self.duration = duration
        self.error = error
        self.backup = backup
    }

    public func with(backup: URL?) -> OptimizationResult {
        var copy = self
        copy.backup = backup
        return copy
    }

    /// True when a smaller version was produced.
    public var improved: Bool { error == nil && newSize < originalSize }
    public var saved: Int { originalSize - newSize }
    public var savedFraction: Double { originalSize > 0 ? Double(saved) / Double(originalSize) : 0 }
}

/// One implementation per format. Reads `input`, writes `output`, never touches `input`.
public protocol Optimizer: Sendable {
    var types: [UTType] { get }
    func options(in formats: FormatSettings) -> FormatOptions
    func optimize(_ input: URL, to output: URL, options: FormatOptions, tools: ToolLocator) async throws
}

public struct OptimizerRegistry: Sendable {
    public let optimizers: [any Optimizer]

    public init(_ optimizers: [any Optimizer]) {
        self.optimizers = optimizers
    }

    public static let standard = OptimizerRegistry([
        PNGOptimizer(), JPEGOptimizer(), GIFOptimizer(), WebPOptimizer(), ImageIOOptimizer(),
        VideoOptimizer(), AudioOptimizer(), PDFOptimizer(),
    ])

    public func optimizer(for type: UTType) -> (any Optimizer)? {
        optimizers.first { $0.types.contains { type.conforms(to: $0) } }
    }
}

extension Logger {
    /// One subsystem per module, as `<bundle-id>.<module>`.
    public static func squish(_ module: String) -> Logger {
        Logger(subsystem: "\(AppIdentity.bundleID).\(module)", category: module)
    }
}
