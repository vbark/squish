import Foundation
import os
import SquishKit

/// Watches the enabled folders with FSEvents and optimizes new or changed files in place.
final class FolderService {
    private let pipeline: Pipeline
    private let ledger = HashLedger.standard
    private let currentSettings: () -> Settings
    private let isActive: () -> Bool
    private let report: ([OptimizationResult]) -> Void

    private var stream: FolderEventStream?
    private var consumer: Task<Void, Never>?
    private var watchedPaths: [String] = []
    /// Paths with a job in flight, so a burst of events for one file starts one job.
    private var inFlight: Set<String> = []

    private static let log = Logger.squish("Folders")

    init(
        pipeline: Pipeline,
        settings: @escaping () -> Settings,
        isActive: @escaping () -> Bool,
        report: @escaping ([OptimizationResult]) -> Void
    ) {
        self.pipeline = pipeline
        self.currentSettings = settings
        self.isActive = isActive
        self.report = report
    }

    /// Call whenever settings or pause state change. Restarts the stream only if the folder list changed.
    func update() {
        let settings = currentSettings()
        let paths = isActive() && settings.foldersEnabled
            ? settings.folders.filter(\.enabled).map(\.url.path).filter { FileManager.default.fileExists(atPath: $0) }
            : []
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        consumer?.cancel()
        stream?.stop()
        stream = nil
        guard !paths.isEmpty else { return }

        let stream = FolderEventStream(paths: paths)
        self.stream = stream
        Self.log.info("Watching \(paths.count) folders")
        consumer = Task { [weak self] in
            for await event in stream.events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: FolderEventStream.Event) {
        guard event.isFile, !inFlight.contains(event.path) else { return }
        let settings = currentSettings()
        guard isActive(), settings.foldersEnabled,
              let folder = FolderRules.folder(for: event.path, in: settings.folders),
              FolderRules.shouldConsider(event.path, folder: folder)
        else { return }
        let url = URL(filePath: event.path)
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType ?? nil,
              pipeline.canOptimize(type)
        else { return }

        inFlight.insert(event.path)
        let pipeline = pipeline, ledger = ledger
        Task {
            defer { inFlight.remove(event.path) }
            guard let result = await Self.process(url, pipeline: pipeline, ledger: ledger, formats: settings.formats) else { return }
            report([result])
        }
    }

    /// nil means the file was skipped on purpose (gone, placeholder, still changing, or Squish's own output).
    @concurrent
    private static func process(_ url: URL, pipeline: Pipeline, ledger: HashLedger, formats: FormatSettings) async -> OptimizationResult? {
        // Placeholders first: waiting on them would never finish, and reading them would force a download.
        guard FileState.isRegularFile(url), !FileState.isDataless(url) else { return nil }
        guard await FileState.waitUntilStable(url), !FileState.isDataless(url) else { return nil }
        if SelfWriteGuard.isMarked(url) { return nil }
        if let hash = SelfWriteGuard.hash(of: url), await ledger.contains(hash) {
            SelfWriteGuard.mark(url) // the sync provider dropped our attribute; put it back
            return nil
        }
        let result = await pipeline.optimizeFile(url, formats: formats)
        if result.improved, let hash = SelfWriteGuard.hash(of: url) {
            await ledger.insert(hash)
        }
        return result
    }
}
