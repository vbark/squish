import Foundation
import os
import UniformTypeIdentifiers

/// Caps how many optimizations run at once across every source.
public actor Limiter {
    private var limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        while running < limit, !waiters.isEmpty {
            running += 1
            waiters.removeFirst().resume()
        }
    }

    // shortcut: a cancelled waiter still holds its place in line; fine while jobs are short.
    public func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        if running <= limit, !waiters.isEmpty {
            waiters.removeFirst().resume() // hand the slot over; `running` is unchanged
        } else {
            running -= 1
        }
    }
}

public struct Pipeline: Sendable {
    public var registry: OptimizerRegistry
    public var tools: ToolLocator
    public var backups: BackupStore
    public let limiter: Limiter

    private static let log = Logger.squish("Pipeline")

    public init(
        registry: OptimizerRegistry = .standard,
        tools: ToolLocator = .standard,
        backups: BackupStore = .standard,
        limiter: Limiter
    ) {
        self.registry = registry
        self.tools = tools
        self.backups = backups
        self.limiter = limiter
    }

    /// Optimizes `file` in place. The original goes to the backup store first unless `backup` is false.
    /// Leaves the file untouched when the result is not smaller or anything fails.
    @concurrent
    public func optimizeFile(_ file: URL, formats: FormatSettings, backup: Bool = true) async -> OptimizationResult {
        do {
            // Same volume as the original, so the final swap is an atomic rename.
            let workDir = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: file, create: true
            )
            defer { try? FileManager.default.removeItem(at: workDir) }
            let output = workDir.appending(path: file.lastPathComponent)
            let result = await optimize(file, to: output, formats: formats)
            guard result.error == nil, result.newSize < result.originalSize else { return result }
            SelfWriteGuard.mark(output)
            let backupURL = backup ? try backups.replace(file, with: output) : try BackupStore.swap(file, with: output)
            return result.with(backup: backupURL)
        } catch {
            return OptimizationResult(file: file, originalSize: Self.size(of: file) ?? 0, newSize: Self.size(of: file) ?? 0,
                                      duration: .zero, error: .io(error.localizedDescription))
        }
    }

    /// Writes an optimized copy of `input` to `output`, only when it is smaller. Never touches `input`.
    @concurrent
    public func optimize(_ input: URL, to output: URL, formats: FormatSettings) async -> OptimizationResult {
        await limiter.acquire()
        let result = await process(input, to: output, formats: formats)
        await limiter.release()

        if let error = result.error {
            Self.log.error("\(input.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        } else {
            Self.log.info("\(input.lastPathComponent, privacy: .public): \(result.originalSize) to \(result.newSize) bytes in \(result.duration)")
        }
        return result
    }

    public func canOptimize(_ type: UTType) -> Bool {
        registry.optimizer(for: type) != nil
    }

    private func process(_ file: URL, to output: URL, formats: FormatSettings) async -> OptimizationResult {
        let start = ContinuousClock.now
        let originalSize = Self.size(of: file) ?? 0
        func result(_ newSize: Int, error: SquishError? = nil) -> OptimizationResult {
            OptimizationResult(file: file, originalSize: originalSize, newSize: newSize, duration: .now - start, error: error)
        }

        do {
            guard let type = try file.resourceValues(forKeys: [.contentTypeKey]).contentType else {
                throw SquishError.unsupported(file.pathExtension.uppercased())
            }
            guard let optimizer = registry.optimizer(for: type) else {
                throw SquishError.unsupported(type.preferredFilenameExtension?.uppercased() ?? type.identifier)
            }
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: output)
            try await optimizer.optimize(file, to: output, options: optimizer.options(in: formats), tools: tools)

            guard let newSize = Self.size(of: output), newSize > 0, newSize < originalSize else {
                try? FileManager.default.removeItem(at: output)
                return result(originalSize)
            }
            return result(newSize)
        } catch let error as SquishError {
            try? FileManager.default.removeItem(at: output)
            return result(originalSize, error: error)
        } catch {
            try? FileManager.default.removeItem(at: output)
            return result(originalSize, error: .io(error.localizedDescription))
        }
    }

    static func size(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }
}
