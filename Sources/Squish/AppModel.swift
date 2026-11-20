import AppKit
import Observation
import SquishKit
import UniformTypeIdentifiers

@Observable
final class AppModel {
    let settings = SettingsStore()
    /// Lifetime stats, one file per Mac in the sync folder.
    @ObservationIgnored private(set) lazy var stats = StatsStore { [unowned self] in self.settings.syncFolder }
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
    /// Global keyboard shortcuts. Observable so Settings can show which ones failed to register.
    @ObservationIgnored private(set) var hotKeys: HotKeyCenter!

    static let supportedTypes: [UTType] = OptimizerRegistry.standard.optimizers.flatMap(\.types)

    init() {
        let settings = settings.settings
        pipeline = Pipeline(limiter: Limiter(limit: settings.effectiveConcurrency))
        Task { await Self.prune(pipeline.backups, days: settings.backupDays) }

        clipboard = ClipboardService(
            pipeline: pipeline,
            settings: { [unowned self] in self.settings.settings },
            isActive: { [unowned self] in !self.isPaused },
            report: { [unowned self] results, content in self.show(results, content, automatic: true, source: .clipboard) },
            beginWork: { [unowned self] title in self.beginWork(title) }
        )
        clipboard.start()

        folders = FolderService(
            pipeline: pipeline,
            settings: { [unowned self] in self.settings.settings },
            isActive: { [unowned self] in !self.isPaused },
            report: { [unowned self] results in self.show(results, automatic: true, source: .folder) },
            reportSVG: { [unowned self] results in self.showSVG(results, source: .folder) },
            beginWork: { [unowned self] title in self.beginWork(title) }
        )
        folders.update()

        hotKeys = HotKeyCenter { [unowned self] action in self.perform(action) }
        hotKeys.update(settings.shortcuts.all)
        _ = stats // load at launch, so the menu shows today's total right away
        self.settings.onChange = { [unowned self] in
            self.folders.update()
            self.hotKeys.update(self.settings.settings.shortcuts.all)
        }
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

    func optimize(_ urls: [URL], source: StatSource = .manual) {
        guard !urls.isEmpty else { return }
        let settings = settings.settings
        let pipeline = pipeline
        activeJobs += urls.count
        let endWork = beginWork(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
        Task {
            defer { endWork() }
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
            show(results, source: source)
        }
    }

    /// Shows "Squishing…" if the job takes more than a moment. Call the returned closure when it is done.
    func beginWork(_ title: String) -> () -> Void {
        let id = toast.beginWork(title, style: settings.settings.toastStyle)
        return { [weak self] in self?.toast.endWork(id) }
    }

    /// Records files replaced in place and shows the toast. Automatic sources stay quiet
    /// when nothing changed and nothing failed.
    func show(_ results: [OptimizationResult], _ content: ToastContent? = nil, automatic: Bool = false, source: StatSource) {
        stats.record(results, source: source)
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
            self?.render(svgs, scales: [scale], settings: settings)
        }
    }

    /// PNG copies of every SVG already in `folder`, at the folder's scales. New SVGs are handled by the watcher.
    func convertExisting(in folder: SVGFolder) {
        let settings = settings.settings
        Task {
            let svgs = await Self.svgs(in: folder)
            guard !svgs.isEmpty else {
                toast.show(ToastContent(title: (folder.path as NSString).lastPathComponent, body: .message("No SVG files in this folder.")),
                           style: settings.toastStyle)
                return
            }
            render(svgs, scales: folder.scales, settings: settings, conflict: .skip)
        }
    }

    @concurrent private static func svgs(in folder: SVGFolder) async -> [URL] {
        SVG.files(in: folder.url, recursive: folder.recursive)
    }

    private func render(_ svgs: [URL], scales: [Double], settings: Settings, conflict: SVG.Conflict = .rename) {
        let pipeline = pipeline
        let jobs = svgs.flatMap { svg in scales.map { (svg, $0) } }
        activeJobs += jobs.count
        Task {
            let results = await withTaskGroup(of: OptimizationResult?.self) { group in
                for (svg, scale) in jobs {
                    group.addTask {
                        await SVG.convert(svg, scale: scale, naming: settings.svgNaming, formats: settings.formats,
                                          pipeline: pipeline, conflict: conflict)
                    }
                }
                var results: [OptimizationResult] = []
                for await result in group { if let result { results.append(result) } }
                return results
            }
            activeJobs -= jobs.count
            if results.isEmpty {
                toast.show(ToastContent(title: "SVG to PNG", body: .message("Every SVG already has a PNG. Nothing to do.")),
                           style: settings.toastStyle)
            } else {
                showSVG(results, source: .manual)
            }
        }
    }

    /// Records the PNGs made from SVGs and shows the toast.
    func showSVG(_ results: [OptimizationResult], source: StatSource) {
        stats.record(results, source: source, kind: .svg)
        recents = Array((results.filter { $0.error == nil } + recents).prefix(20))
        toast.show(ToastContent(svgResults: results), style: settings.settings.toastStyle)
    }

    // MARK: Shortcuts

    func perform(_ action: ShortcutAction) {
        switch action {
        case .optimizeSelection:
            withFinderSelection(title: "Optimize Selected Files") { urls in
                let files = urls.filter(Self.canOptimize)
                guard !files.isEmpty else { return "None of the selected files can be optimized." }
                optimize(files, source: .shortcut)
                return nil
            }
        case .convertSelection:
            withFinderSelection(title: "Convert to PNG") { urls in
                let svgs = urls.filter { $0.pathExtension.lowercased() == "svg" }
                guard !svgs.isEmpty else { return "Select one or more SVG files." }
                convertSVGs(svgs)
                return nil
            }
        case .chooseFiles:
            chooseFilesToOptimize()
        case .togglePause:
            isPaused.toggle()
            notify("Squish", isPaused ? "Automatic optimization paused." : "Automatic optimization resumed.")
        }
    }

    /// Runs `body` with the Finder selection. `body` returns a message to show when there is nothing to do.
    private func withFinderSelection(title: String, _ body: ([URL]) -> String?) {
        switch FinderSelection.current() {
        case .success(let urls) where urls.isEmpty:
            notify(title, "Nothing is selected in Finder.")
        case .success(let urls):
            if let message = body(urls) { notify(title, message) }
        case .failure(.finderNotInFront):
            notify(title, "Select files in Finder, then press the shortcut.")
        case .failure(.notPermitted):
            toast.show(ToastContent(title: title, body: .failure("Squish isn't allowed to see your Finder selection. Turn on Finder for Squish in Privacy & Security › Automation.")),
                       style: settings.settings.toastStyle)
            FinderSelection.openAutomationSettings()
        case .failure(.scriptError(let message)):
            toast.show(ToastContent(title: title, body: .failure(message)), style: settings.settings.toastStyle)
        }
    }

    private func notify(_ title: String, _ message: String) {
        toast.show(ToastContent(title: title, body: .message(message)), style: settings.settings.toastStyle)
    }

    private static func canOptimize(_ url: URL) -> Bool {
        guard FileState.isRegularFile(url),
              let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        else { return false }
        return supportedTypes.contains { type.conforms(to: $0) }
    }

    func restore(_ result: OptimizationResult) {
        guard let backup = result.backup else { return }
        do {
            try pipeline.backups.restore(backup, to: result.file)
            stats.forget(result)
            recents.removeAll { $0.id == result.id }
            toast.show(ToastContent(title: result.file.lastPathComponent, body: .message("Original restored.")),
                       style: settings.settings.toastStyle)
        } catch {
            toast.show(ToastContent(title: result.file.lastPathComponent, body: .failure(error.localizedDescription)),
                       style: settings.settings.toastStyle)
        }
    }
}
