import AppKit
import Observation
import os
import SquishKit

/// Records every optimization and reads the stats of every Mac sharing the sync folder.
///
/// Each Mac writes only `Stats/<device id>.json`, so two Macs never overwrite each other's numbers
/// (unlike settings, where the newest file wins). Without a sync folder the file lives in Application Support;
/// when sync is turned on it is merged into the sync folder.
///
/// The file on disk is the source of truth for this Mac. Memory only holds events not saved yet, and every
/// save re-reads the file and appends to it, so nothing recorded before the first load is ever lost.
@Observable
final class StatsStore {
    /// Every Mac's file, this one included (with unsaved events).
    private(set) var files: [StatsFile] = []

    @ObservationIgnored private var others: [StatsFile] = []
    @ObservationIgnored private var saved: StatsFile
    @ObservationIgnored private var pending: [StatEvent] = []
    /// Events to drop from the saved file on the next save (originals the user restored).
    @ObservationIgnored private var removals: [StatEvent] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let syncFolder: () -> URL?

    nonisolated private static let log = Logger.squish("Stats")
    nonisolated private static let deviceKey = "statsDeviceID"

    nonisolated static let deviceID: String = {
        if let id = UserDefaults.standard.string(forKey: deviceKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }()

    static var deviceName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    nonisolated static let localFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: AppIdentity.bundleID).appending(path: "Stats")

    init(syncFolder: @escaping () -> URL?) {
        self.syncFolder = syncFolder
        saved = StatsFile(deviceID: Self.deviceID, deviceName: Self.deviceName)
        publish()
        reload()
    }

    var folder: URL { syncFolder()?.appending(path: "Stats") ?? Self.localFolder }

    var report: StatsReport { StatsReport(files: files) }

    // MARK: Recording

    /// Records finished jobs. Failed ones are skipped; files that were already optimal count as such.
    func record(_ results: [OptimizationResult], source: StatSource, kind: StatKind? = nil) {
        let events = results.compactMap { Self.event(for: $0, source: source, kind: kind) }
        guard !events.isEmpty else { return }
        pending += events
        publish()
        scheduleSave()
    }

    /// The user restored the original, so the savings no longer exist.
    func forget(_ result: OptimizationResult) {
        guard let event = Self.event(for: result, source: .manual, kind: nil) else { return }
        if let index = pending.firstIndex(where: { $0.sameFile(as: event) }) {
            pending.remove(at: index)
        } else {
            removals.append(event)
        }
        publish()
        scheduleSave()
    }

    private static func event(for result: OptimizationResult, source: StatSource, kind: StatKind?) -> StatEvent? {
        guard result.error == nil, result.originalSize > 0 else { return nil }
        let ext = result.file.pathExtension.lowercased()
        let parts = result.duration.components
        let ms = Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
        return StatEvent(date: result.date, kind: kind ?? StatKind(fileExtension: ext), format: kind == .svg ? "svg" : ext,
                         source: source, originalSize: result.originalSize, newSize: min(result.newSize, result.originalSize),
                         milliseconds: ms, name: result.file.lastPathComponent)
    }

    /// Clears this Mac's stats. Other Macs keep theirs.
    func resetThisMac() {
        saveTask?.cancel()
        pending = []
        removals = []
        saved = StatsFile(deviceID: Self.deviceID, deviceName: Self.deviceName)
        publish()
        let file = saved, url = folder.appending(path: "\(Self.deviceID).json")
        Task { await Self.overwrite(file, at: url) }
    }

    private func publish() {
        var mine = saved
        mine.deviceName = Self.deviceName
        mine.remove(removals)
        mine.append(pending)
        files = others + [mine]
    }

    private func scheduleSave(delay: Duration = .seconds(2)) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let batch = pending, dropped = removals
            let url = folder.appending(path: "\(Self.deviceID).json")
            guard let written = await Self.append(batch, removing: dropped, to: url, deviceName: Self.deviceName) else { return }
            saved = written
            pending.removeFirst(min(batch.count, pending.count))
            removals.removeFirst(min(dropped.count, removals.count))
            publish()
        }
    }

    /// Re-reads this Mac's file, appends `events` and writes it back.
    @concurrent private static func append(
        _ events: [StatEvent], removing dropped: [StatEvent], to url: URL, deviceName: String
    ) async -> StatsFile? {
        var file = StatsIO.read(url) ?? StatsFile(deviceID: deviceID, deviceName: deviceName)
        file.deviceName = deviceName
        file.remove(dropped)
        file.append(events)
        do {
            try StatsIO.write(file, to: url)
            return file
        } catch {
            log.error("Could not save stats: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @concurrent private static func overwrite(_ file: StatsFile, at url: URL) async {
        try? StatsIO.write(file, to: url)
    }

    // MARK: Loading

    /// Reads every Mac's file. Cheap; called at launch, when the Stats page opens and while it stays open.
    func reload() {
        let folder = folder
        Task {
            let all = await Self.load(folder: folder)
            saved = all.first { $0.deviceID == Self.deviceID } ?? StatsFile(deviceID: Self.deviceID, deviceName: Self.deviceName)
            others = all.filter { $0.deviceID != Self.deviceID }
            publish()
        }
    }

    /// With a sync folder, this Mac's local file (from before sync was on) is merged into the synced one, then removed.
    @concurrent private static func load(folder: URL) async -> [StatsFile] {
        var all = StatsIO.readAll(in: folder)
        let name = "\(deviceID).json"
        let localURL = localFolder.appending(path: name)
        guard folder != localFolder, let local = StatsIO.read(localURL) else { return all }
        var mine = all.first { $0.deviceID == deviceID } ?? StatsFile(deviceID: deviceID, deviceName: local.deviceName)
        mine.merge(local)
        do {
            try StatsIO.write(mine, to: folder.appending(path: name))
            try FileManager.default.removeItem(at: localURL)
        } catch {
            log.error("Could not move stats into the sync folder: \(error.localizedDescription, privacy: .public)")
        }
        all = all.filter { $0.deviceID != deviceID } + [mine]
        return all
    }
}
