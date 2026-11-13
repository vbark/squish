import AppKit
import Observation
import os
import SquishKit
import UniformTypeIdentifiers

/// Watches NSPasteboard.general by polling `changeCount` (there is no change notification), optimizes
/// new media, and writes the smaller version back with a marker type so it never processes its own output.
@Observable
final class ClipboardService {
    /// The user chose "Always Deny" for pasteboard access in System Settings (macOS 15.4+).
    private(set) var accessDenied = false

    @ObservationIgnored private let pasteboard = NSPasteboard.general
    @ObservationIgnored private let pipeline: Pipeline
    @ObservationIgnored private let currentSettings: () -> Settings
    @ObservationIgnored private let isActive: () -> Bool
    @ObservationIgnored private let report: ([OptimizationResult], ToastContent) -> Void
    @ObservationIgnored private var lastChange = NSPasteboard.general.changeCount
    @ObservationIgnored private var lastActivity = ContinuousClock.now
    @ObservationIgnored private var loop: Task<Void, Never>?

    private static let log = Logger.squish("Clipboard")

    nonisolated static var workRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: AppIdentity.bundleID).appending(path: "clipboard")
    }

    init(
        pipeline: Pipeline,
        settings: @escaping () -> Settings,
        isActive: @escaping () -> Bool,
        report: @escaping ([OptimizationResult], ToastContent) -> Void
    ) {
        self.pipeline = pipeline
        self.currentSettings = settings
        self.isActive = isActive
        self.report = report
    }

    func start() {
        lastChange = pasteboard.changeCount
        loop = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.tick()
                try? await Task.sleep(for: self.interval)
            }
        }
    }

    /// Reading `changeCount` is cheap and silent; still back off when nothing has been copied for a while.
    private var interval: Duration {
        let idle = ContinuousClock.now - lastActivity
        if idle < .seconds(30) { return .milliseconds(500) }
        if idle < .seconds(300) { return .seconds(1) }
        return .seconds(2)
    }

    private func tick() {
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count
        lastActivity = .now

        let settings = currentSettings()
        guard isActive(), settings.clipboardEnabled else { return }
        if #available(macOS 15.4, *) {
            accessDenied = pasteboard.accessBehavior == .alwaysDeny
            guard !accessDenied else { return }
        }
        let types = pasteboard.types?.map(\.rawValue) ?? []
        switch ClipboardRules.action(for: types, kinds: settings.clipboardKinds) {
        case .ignore: break
        case .image(let type): optimizeImage(type, changeCount: count, settings: settings)
        case .files: optimizeFiles(changeCount: count, settings: settings)
        }
    }

    // MARK: Image data

    private func optimizeImage(_ type: UTType, changeCount: Int, settings: Settings) {
        // This read is what triggers the macOS privacy alert. nil means denied or already gone.
        guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)) else { return }
        let pipeline = pipeline
        Task {
            let (result, output) = await Self.optimize(data, type: type, pipeline: pipeline, formats: settings.formats)
            guard pasteboard.changeCount == changeCount else { return } // the user copied something else meanwhile
            if let output {
                write(output.data, type: output.type)
            }
            let restore: (() -> Void)? = output == nil ? nil : {
                self.write(data, type: type)
            }
            report([result], ToastContent(results: [result], restore: restore))
        }
    }

    /// TIFF (what many apps copy) becomes PNG; everything else keeps its format.
    @concurrent
    private static func optimize(
        _ data: Data, type: UTType, pipeline: Pipeline, formats: FormatSettings
    ) async -> (OptimizationResult, (data: Data, type: UTType)?) {
        var inputType = type
        var inputData = data
        if type.conforms(to: .tiff), let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
            inputType = .png
            inputData = png
        }
        let dir = workRoot.appending(path: UUID().uuidString)
        let name = "Clipboard image.\(inputType.preferredFilenameExtension ?? "img")"
        let input = dir.appending(path: name)
        let output = dir.appending(path: "out").appending(path: name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try inputData.write(to: input)
        } catch {
            return (OptimizationResult(file: input, originalSize: data.count, newSize: data.count, duration: .zero,
                                       error: .io(error.localizedDescription)), nil)
        }
        let result = await pipeline.optimize(input, to: output, formats: formats)
        // A converted TIFF is worth writing back even if the PNG optimizer had nothing to add.
        let best = (try? Data(contentsOf: output)) ?? (inputType != type ? inputData : nil)
        guard let best, best.count < data.count else {
            return (OptimizationResult(file: input, originalSize: data.count, newSize: data.count,
                                       duration: result.duration, error: result.error), nil)
        }
        return (OptimizationResult(file: input, originalSize: data.count, newSize: best.count, duration: result.duration),
                (best, inputType))
    }

    private func write(_ data: Data, type: UTType) {
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        item.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardRules.markerType))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        lastChange = pasteboard.changeCount
    }

    // MARK: Copied files

    /// Copied files are never modified. Optimized copies go to the cache and their URLs replace the originals.
    private func optimizeFiles(changeCount: Int, settings: Settings) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let candidates = urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension), let kind = FileKind(type: type) else { return false }
            return settings.clipboardKinds.contains(kind) && pipeline.canOptimize(type)
        }
        guard !candidates.isEmpty else { return }
        let pipeline = pipeline
        Task {
            var outputs: [URL: URL] = [:]
            let results = await withTaskGroup(of: (URL, OptimizationResult, URL).self) { group in
                for url in candidates {
                    let output = Self.workRoot.appending(path: UUID().uuidString).appending(path: url.lastPathComponent)
                    group.addTask { (url, await pipeline.optimize(url, to: output, formats: settings.formats), output) }
                }
                var results: [OptimizationResult] = []
                for await (url, result, output) in group {
                    results.append(result)
                    if result.improved { outputs[url] = output }
                }
                return results
            }
            guard pasteboard.changeCount == changeCount else { return }
            var restore: (() -> Void)?
            if !outputs.isEmpty {
                writeFiles(urls.map { outputs[$0] ?? $0 })
                restore = { self.writeFiles(urls) }
            }
            report(results, ToastContent(results: results, restore: restore))
        }
    }

    private func writeFiles(_ urls: [URL]) {
        let items = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardRules.markerType))
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        lastChange = pasteboard.changeCount
    }
}
