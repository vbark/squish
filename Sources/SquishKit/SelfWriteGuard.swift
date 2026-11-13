import CryptoKit
import Foundation

/// Recognizes files Squish wrote, so it never re-optimizes its own output or loops on its own write events.
/// Two layers: an extended attribute on the file, and a ledger of output hashes for cloud providers
/// that drop extended attributes on sync.
public enum SelfWriteGuard {
    public static let attribute = "\(AppIdentity.bundleID).optimized"

    public static func mark(_ url: URL) {
        _ = url.withUnsafeFileSystemRepresentation { path in
            setxattr(path, attribute, "1", 1, 0, 0)
        }
    }

    public static func isMarked(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            getxattr(path, attribute, nil, 0, 0, 0) >= 0
        }
    }

    public static func hash(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Hashes of files Squish produced, persisted between launches. Capped so it never grows unbounded.
public actor HashLedger {
    private let url: URL
    private var hashes: [String]
    private var lookup: Set<String>
    private let limit: Int

    public init(url: URL, limit: Int = 5000) {
        self.url = url
        self.limit = limit
        let stored = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: url))) ?? []
        hashes = stored
        lookup = Set(stored)
    }

    public static var standard: HashLedger {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return HashLedger(url: support.appending(path: AppIdentity.bundleID).appending(path: "optimized-hashes.json"))
    }

    public func contains(_ hash: String) -> Bool { lookup.contains(hash) }

    public func insert(_ hash: String) {
        guard lookup.insert(hash).inserted else { return }
        hashes.append(hash)
        if hashes.count > limit {
            let dropped = hashes.prefix(hashes.count - limit)
            lookup.subtract(dropped)
            hashes.removeFirst(dropped.count)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(hashes).write(to: url, options: .atomic)
    }
}
