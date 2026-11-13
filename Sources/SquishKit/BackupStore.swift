import Foundation

/// Originals kept in ~/Library/Caches/<bundle-id>/backups/<uuid>/<name> so the user can restore them.
public struct BackupStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var standard: BackupStore {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return BackupStore(root: caches.appending(path: AppIdentity.bundleID).appending(path: "backups"))
    }

    /// Copies `file` into the store, then atomically swaps `replacement` into its place.
    /// `replaceItemAt` keeps the original's creation date, permissions and Finder tags.
    public func replace(_ file: URL, with replacement: URL) throws -> URL {
        let backup = root.appending(path: UUID().uuidString).appending(path: file.lastPathComponent)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: backup)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        return backup
    }

    /// Atomically swaps `replacement` into `file`'s place without keeping a backup. Returns nil.
    static func swap(_ file: URL, with replacement: URL) throws -> URL? {
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        return nil
    }

    /// Puts the original back. The restored file is marked so folder watching leaves it alone.
    public func restore(_ backup: URL, to file: URL) throws {
        let workDir = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: file, create: true
        )
        defer { try? FileManager.default.removeItem(at: workDir) }
        let copy = workDir.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: backup, to: copy)
        SelfWriteGuard.mark(copy)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: copy)
    }

    /// Deletes backups older than `days`.
    public func prune(olderThan days: Int, now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }
}
