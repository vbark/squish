import Foundation
import Observation
import os
import SquishKit

/// Owns `Settings`. Persists to UserDefaults and, when a sync folder is set, to `<folder>/settings.json`.
/// Newest `modified` wins; other Macs pick up changes by polling the file's modification date.
@Observable
final class SettingsStore {
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            if !applyingRemote { settingsChanged() }
            onChange?()
        }
    }

    /// Called after every change, local or synced from another Mac.
    @ObservationIgnored var onChange: (() -> Void)?

    private(set) var syncFolder: URL?
    private(set) var syncError: String?
    private(set) var lastSynced: Date?
    /// Set when sync is turned on for a folder that already holds different settings.
    var pendingSync: PendingSync?

    struct PendingSync {
        let folder: URL
        let remote: SettingsEnvelope
    }

    private var modified: Date
    private var applyingRemote = false
    private var lastSeenFileDate: Date?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private static let settingsKey = "settings"
    private static let syncFolderKey = "syncFolder"
    private static let log = Logger.squish("Settings")

    init() {
        let local = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? SettingsCodec.decode($0) }
        settings = local?.settings ?? Settings()
        modified = local?.modified ?? .distantPast
        syncFolder = UserDefaults.standard.string(forKey: Self.syncFolderKey)
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pull()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    // MARK: Sync folder

    static var iCloudFolder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: drive.path) ? drive.appending(path: "Squish") : nil
    }

    /// One entry per OneDrive account (personal, business).
    static var oneDriveFolders: [URL] {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage")
        let entries = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix("OneDrive") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { $0.appending(path: "Squish", directoryHint: .isDirectory) }
    }

    func startSync(in folder: URL) async {
        do {
            let remote = try await Self.read(SettingsFile(folder: folder))
            if let remote, remote.settings != settings {
                pendingSync = PendingSync(folder: folder, remote: remote)
            } else {
                commitSync(folder: folder, useRemote: false)
            }
        } catch {
            syncError = "Couldn't read settings in \(folder.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// `useRemote` adopts the folder's settings; otherwise this Mac's settings overwrite the file.
    func commitSync(folder: URL, useRemote: Bool) {
        let remote = pendingSync?.remote
        pendingSync = nil
        syncFolder = folder
        syncError = nil
        defaults.set(folder.path, forKey: Self.syncFolderKey)
        if useRemote, let remote {
            apply(remote)
            lastSeenFileDate = SettingsFile(folder: folder).modificationDate
            lastSynced = .now
        } else {
            modified = Self.now() // so other Macs treat this copy as newest
            saveLocal()
            scheduleWrite()
        }
    }

    func stopSync() {
        writeTask?.cancel()
        syncFolder = nil
        syncError = nil
        lastSynced = nil
        lastSeenFileDate = nil
        defaults.removeObject(forKey: Self.syncFolderKey)
    }

    // MARK: Persistence

    private var envelope: SettingsEnvelope {
        SettingsEnvelope(modified: modified, device: ProcessInfo.processInfo.hostName, settings: settings)
    }

    private func settingsChanged() {
        modified = Self.now()
        saveLocal()
        scheduleWrite()
    }

    private func saveLocal() {
        defaults.set(try? SettingsCodec.encode(envelope), forKey: Self.settingsKey)
    }

    /// Debounced so dragging a slider writes once.
    private func scheduleWrite() {
        guard let syncFolder else { return }
        writeTask?.cancel()
        let file = SettingsFile(folder: syncFolder)
        let envelope = self.envelope
        writeTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            do {
                try await Self.write(envelope, to: file)
                lastSeenFileDate = file.modificationDate
                lastSynced = .now
                syncError = nil
            } catch {
                syncError = "Couldn't save settings.json: \(error.localizedDescription)"
                Self.log.error("Sync write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func pull() async {
        guard let folder = syncFolder, pendingSync == nil else { return }
        let file = SettingsFile(folder: folder)
        guard let date = file.modificationDate, date != lastSeenFileDate else { return }
        do {
            guard let remote = try await Self.read(file), syncFolder == folder else { return }
            lastSeenFileDate = date
            lastSynced = .now
            syncError = nil
            if remote.modified > modified {
                Self.log.info("Applied settings from \(remote.device, privacy: .public)")
                apply(remote)
            }
        } catch {
            syncError = "Couldn't read settings.json: \(error.localizedDescription)"
        }
    }

    private func apply(_ remote: SettingsEnvelope) {
        applyingRemote = true
        settings = remote.settings
        applyingRemote = false
        modified = remote.modified
        saveLocal()
    }

    private static func now() -> Date {
        Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
    }

    // File coordination can block while iCloud or OneDrive downloads, so keep it off the main actor.
    @concurrent private static func read(_ file: SettingsFile) async throws -> SettingsEnvelope? {
        try file.read()
    }

    @concurrent private static func write(_ envelope: SettingsEnvelope, to file: SettingsFile) async throws {
        try file.write(envelope)
    }
}
