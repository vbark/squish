import AppKit
import Observation
import SquishKit
import UniformTypeIdentifiers

@Observable
final class AppModel {
    let settings = SettingsStore()
    let toast = ToastPresenter()

    /// Device-only, so it does not sync.
    var isPaused = UserDefaults.standard.bool(forKey: "paused") {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: "paused")
            folders.update()
        }
    }

    /// Files replaced in place, newest first, at most 20.
    private(set) var recents: [OptimizationResult] = []
    private(set) var activeJobs = 0

    @ObservationIgnored private let pipeline: Pipeline
    @ObservationIgnored private(set) var clipboard: ClipboardService!
    @ObservationIgnored private var folders: FolderService!

    @ObservationIgnored private let svgPanel = SVGPanelController()

    static let supportedTypes: [UTType] = OptimizerRegistry.standard.optimizers.flatMap(\.types)

    init() {
        let settings = settings.settings
        pipeline = Pipeline(limiter: Limiter(limit: settings.effectiveConcurrency))
        Task { await Self.prune(pipeline.backups, days: settings.backupDays) }

        clipboard = ClipboardService(
            pipeline: pipeline,
            settings: { [unowned self] in self.settings.settings },
            isActive: { [unowned self] in !self.isPaused },
            report: { [unowned self] results, content in self.show(results, content, automatic: true) }
        )
        clipboard.start()

        folders = FolderService(
            pipeline: pipeline,
            settings: { [unowned self] in self.settings.settings },
            isActive: { [unowned self] in !self.isPaused },
            report: { [unowned self] results in self.show(results, automatic: true) }
        )
        folders.update()
        self.settings.onChange = { [unowned self] in self.folders.update() }
    }

    @concurrent private static func prune(_ backups: BackupStore, days: Int) async {
        backups.prune(olderThan: days)
        BackupStore(root: ClipboardService.workRoot).prune(olderThan: days)
    }

    var backupsFolder: URL { pipeline.backups.root }

    func chooseFilesToOptimize() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.supportedTypes
        panel.message = "Squish replaces each file with a smaller copy. Originals are kept for \(settings.settings.backupDays) days."
        panel.prompt = "Optimize"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        optimize(panel.urls)
    }

    func optimize(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let settings = settings.settings
        let pipeline = pipeline
        activeJobs += urls.count
        Task {
            await pipeline.limiter.setLimit(settings.effectiveConcurrency)
            let results = await withTaskGroup(of: OptimizationResult.self) { group in
                for url in urls {
                    group.addTask { await pipeline.optimizeFile(url, formats: settings.formats) }
                }
                var results: [OptimizationResult] = []
                for await result in group { results.append(result) }
                return results
            }
            activeJobs -= urls.count
            show(results)
        }
    }

    /// Records files replaced in place and shows the toast. Automatic sources stay quiet
    /// when nothing changed and nothing failed.
    func show(_ results: [OptimizationResult], _ content: ToastContent? = nil, automatic: Bool = false) {
        if automatic, !results.contains(where: { $0.improved || $0.error != nil }) { return }
        let replaced = results.filter { $0.backup != nil }
        let restore: (() -> Void)? = replaced.count == 1 ? { [weak self] in self?.restore(replaced[0]) } : nil
        let content = content ?? ToastContent(results: results, restore: restore)
        recents = Array((replaced.sorted { $0.saved > $1.saved } + recents).prefix(20))
        let settings = settings.settings
        if settings.sounds, results.contains(where: \.improved) { NSSound(named: "Pop")?.play() }
        toast.show(content, style: settings.toastStyle)
    }

    func chooseSVGsToConvert() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.svg]
        panel.prompt = "Choose"
        panel.message = "Choose SVG files to convert to PNG."
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        convertSVGs(panel.urls)
    }

    /// Asks for a scale, renders each SVG next to itself, then runs the PNG through the normal pipeline.
    func convertSVGs(_ urls: [URL]) {
        let svgs = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .svg) == true }
        guard !svgs.isEmpty else { return }
        let settings = settings.settings
        svgPanel.present(svgs, defaultScale: settings.svgScale, naming: settings.svgNaming) { [weak self] scale in
            self?.render(svgs, scale: scale, settings: settings)
        }
    }

    private func render(_ svgs: [URL], scale: Double, settings: Settings) {
        let pipeline = pipeline
        activeJobs += svgs.count
        Task {
            let results = await withTaskGroup(of: OptimizationResult.self) { group in
                for svg in svgs {
                    group.addTask { await Self.convert(svg, scale: scale, settings: settings, pipeline: pipeline) }
                }
                var results: [OptimizationResult] = []
                for await result in group { results.append(result) }
                return results
            }
            activeJobs -= svgs.count
            recents = Array((results.filter { $0.error == nil } + recents).prefix(20))
            let content = ToastContent(svgResults: results)
            toast.show(content, style: settings.toastStyle)
        }
    }

    @concurrent
    private static func convert(_ svg: URL, scale: Double, settings: Settings, pipeline: Pipeline) async -> OptimizationResult {
        do {
            let png = try await SVG.render(svg, scale: scale, naming: settings.svgNaming, tools: pipeline.tools)
            return await pipeline.optimizeFile(png, formats: settings.formats, backup: false)
        } catch {
            let squishError = error as? SquishError ?? .io(error.localizedDescription)
            return OptimizationResult(file: svg, originalSize: 0, newSize: 0, duration: .zero, error: squishError)
        }
    }

    func restore(_ result: OptimizationResult) {
        guard let backup = result.backup else { return }
        do {
            try pipeline.backups.restore(backup, to: result.file)
            recents.removeAll { $0.id == result.id }
            toast.show(ToastContent(title: result.file.lastPathComponent, body: .message("Original restored.")),
                       style: settings.settings.toastStyle)
        } catch {
            toast.show(ToastContent(title: result.file.lastPathComponent, body: .failure(error.localizedDescription)),
                       style: settings.settings.toastStyle)
        }
    }
}
