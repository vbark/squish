import CoreServices
import Foundation
import UniformTypeIdentifiers

/// File-level FSEvents for a set of folders, starting now (files already there are never reported).
public final class FolderEventStream: @unchecked Sendable {
    public struct Event: Sendable {
        public let path: String
        public let flags: FSEventStreamEventFlags

        public var isFile: Bool { flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 }
    }

    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    // Only touched from init and stop(), both called on the owner's actor.
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: TimeInterval = 0.3) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(10_000))
        guard !paths.isEmpty else {
            continuation.finish()
            return
        }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let me = Unmanaged<FolderEventStream>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self)
            for index in 0..<count {
                guard let path = paths[index] as? String else { continue }
                me.continuation.yield(Event(path: path, flags: eventFlags[index]))
            }
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags)
        ) else {
            continuation.finish()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "\(AppIdentity.bundleID).fsevents"))
        FSEventStreamStart(stream)
    }

    /// Must be called before the last reference goes away; the C callback holds an unretained pointer.
    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        continuation.finish()
    }
}

public enum FolderRules {
    /// In-progress downloads and temp files. The final rename produces its own event.
    static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload", "filepart"]

    /// The watched folder an event belongs to, honoring each folder's recursive setting.
    public static func folder(for path: String, in folders: [WatchedFolder]) -> WatchedFolder? {
        let file = URL(filePath: path)
        let parent = file.deletingLastPathComponent().standardizedFileURL.path
        return folders
            .filter(\.enabled)
            .sorted { $0.url.path.count > $1.url.path.count } // innermost folder wins
            .first { folder in
                let root = folder.url.standardizedFileURL.path
                return parent == root || (folder.recursive && parent.hasPrefix(root + "/"))
            }
    }

    /// Cheap checks on the name alone, before touching the file.
    public static func shouldConsider(_ path: String, folder: WatchedFolder) -> Bool {
        let url = URL(filePath: path)
        let name = url.lastPathComponent
        if name.hasPrefix(".") || name.hasPrefix("~$") { return false }
        let ext = url.pathExtension.lowercased()
        if partialExtensions.contains(ext) { return false }
        guard let type = UTType(filenameExtension: ext), let kind = FileKind(type: type) else { return false }
        return folder.kinds.contains(kind)
    }
}

public enum FileState {
    /// A cloud placeholder (iCloud, OneDrive) whose content is not on disk. Checked with lstat,
    /// which does not trigger a download.
    public static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & 0x4000_0000 != 0 // SF_DATALESS
    }

    public static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// Waits until size and modification date are unchanged across two checks `interval` apart.
    /// Returns false if the file disappears or never settles within `timeout`.
    public static func waitUntilStable(
        _ url: URL, interval: Duration = .seconds(1), timeout: Duration = .seconds(600)
    ) async -> Bool {
        func snapshot() -> [AnyHashable]? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int, size > 0,
                  let modified = attributes[.modificationDate] as? Date
            else { return nil }
            return [size, modified]
        }
        let deadline = ContinuousClock.now + timeout
        var previous = snapshot()
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return false }
            let current = snapshot()
            if let current, current == previous { return true }
            if current == nil, !FileManager.default.fileExists(atPath: url.path) { return false }
            previous = current
        }
        return false
    }
}
