import Foundation
import os
import SquishKit

/// Watches the enabled folders with FSEvents. Optimizes new or changed files in place, and gives
/// new or changed SVGs in SVG folders a PNG copy.
final class FolderService {
    private let pipeline: Pipeline
    private let ledger = HashLedger.standard
    private let currentSettings: () -> Settings
    private let isActive: () -> Bool
    private let report: ([OptimizationResult]) -> Void
    private let reportSVG: ([OptimizationResult]) -> Void
    /// Starts the "Squishing…" feedback for a file; returns the call that ends it.
    private let beginWork: (String) -> () -> Void

    private var stream: FolderEventStream?
    private var consumer: Task<Void, Never>?
    private var watchedPaths: [String] = []
    /// Paths with a job in flight, so a burst of events for one file starts one job.
    private var inFlight: Set<String> = []
    /// SVG path to what it looked like when last converted, so attribute-only events
    /// (tags, quarantine, sync bookkeeping) don't render it again.
    private var converted: [String: String] = [:]

    private static let log = Logger.squish("Folders")

    init(
        pipeline: Pipeline,
        settings: @escaping () -> Settings,
        isActive: @escaping () -> Bool,
        report: @escaping ([OptimizationResult]) -> Void,
        reportSVG: @escaping ([OptimizationResult]) -> Void,
        beginWork: @escaping (String) -> () -> Void
    ) {
        self.beginWork = beginWork
        self.pipeline = pipeline
        self.currentSettings = settings
        self.isActive = isActive
        self.report = report
        self.reportSVG = reportSVG
    }

    /// Call whenever settings or pause state change. Restarts the stream only if the folder list changed.
    func update() {
        let settings = currentSettings()
        var candidates = settings.svgFolders.filter(\.enabled).map(\.url.path)
        if settings.foldersEnabled {
            candidates += settings.folders.filter(\.enabled).map(\.url.path)
        }
        let paths = isActive()
            ? FolderRules.outermost(candidates.filter { FileManager.default.fileExists(atPath: $0) })
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
        guard event.isFile, !inFlight.contains(event.path), isActive() else { return }
        let settings = currentSettings()
        if FolderRules.isSVG(event.path) {
            handleSVG(event.path, settings: settings)
            return
        }
        guard settings.foldersEnabled,
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
            guard await Self.isReady(url, ledger: ledger) else { return }
            let endWork = beginWork(url.lastPathComponent)
            defer { endWork() }
            let result = await Self.optimize(url, pipeline: pipeline, ledger: ledger, formats: settings.formats)
            report([result])
        }
    }

    private func handleSVG(_ path: String, settings: Settings) {
        guard let folder = FolderRules.folder(for: path, in: settings.svgFolders) else { return }
        inFlight.insert(path)
        let pipeline = pipeline, known = converted[path]
        Task {
            defer { inFlight.remove(path) }
            guard let (results, fingerprint) = await Self.convert(
                URL(filePath: path), scales: folder.scales, settings: settings, pipeline: pipeline, known: known
            ) else { return }
            converted[path] = fingerprint
            if !results.isEmpty { reportSVG(results) }
        }
    }

    /// nil means the SVG was skipped on purpose (gone, placeholder, still changing, or unchanged since last time).
    @concurrent
    private static func convert(
        _ svg: URL, scales: [Double], settings: Settings, pipeline: Pipeline, known: String?
    ) async -> ([OptimizationResult], String)? {
        guard FileState.isRegularFile(svg), !FileState.isDataless(svg) else { return nil }
        guard await FileState.waitUntilStable(svg), !FileState.isDataless(svg),
              let attributes = try? FileManager.default.attributesOfItem(atPath: svg.path)
        else { return nil }
        let fingerprint = [
            "\(attributes[.size] as? Int ?? 0)",
            "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)",
            scales.map { "\($0)" }.joined(separator: ","),
            settings.svgNaming.rawValue,
        ].joined(separator: "|")
        guard fingerprint != known else { return nil }
        // All sizes at once; the pipeline's limiter caps how many run together.
        let results = await withTaskGroup(of: OptimizationResult?.self) { group in
            for scale in scales {
                group.addTask {
                    await SVG.convert(svg, scale: scale, naming: settings.svgNaming, formats: settings.formats,
                                      pipeline: pipeline, conflict: .skip)
                }
            }
            var results: [OptimizationResult] = []
            for await result in group { if let result { results.append(result) } }
            return results
        }
        return (results, fingerprint)
    }

    /// False means the file is skipped on purpose (gone, placeholder, still changing, or Squish's own output).
    @concurrent
    private static func isReady(_ url: URL, ledger: HashLedger) async -> Bool {
        // Placeholders first: waiting on them would never finish, and reading them would force a download.
        guard FileState.isRegularFile(url), !FileState.isDataless(url) else { return false }
        guard await FileState.waitUntilStable(url), !FileState.isDataless(url) else { return false }
        if SelfWriteGuard.isMarked(url) { return false }
        if let hash = SelfWriteGuard.hash(of: url), await ledger.contains(hash) {
            SelfWriteGuard.mark(url) // the sync provider dropped our attribute; put it back
            return false
        }
        return true
    }

    @concurrent
    private static func optimize(_ url: URL, pipeline: Pipeline, ledger: HashLedger, formats: FormatSettings) async -> OptimizationResult {
        let result = await pipeline.optimizeFile(url, formats: formats)
        if result.improved, let hash = SelfWriteGuard.hash(of: url) {
            await ledger.insert(hash)
        }
        return result
    }
}
