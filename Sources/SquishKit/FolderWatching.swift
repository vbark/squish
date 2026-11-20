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
    public static func folder<Folder: WatchedLocation>(for path: String, in folders: [Folder]) -> Folder? {
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
        guard isCandidate(url) else { return false }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()), let kind = FileKind(type: type) else { return false }
        return folder.kinds.contains(kind)
    }

    /// A visible, finished `.svg` file, judged by its name alone.
    public static func isSVG(_ path: String) -> Bool {
        let url = URL(filePath: path)
        return isCandidate(url) && url.pathExtension.lowercased() == "svg"
    }

    /// Not hidden, not an Office lock file, not a download in progress.
    static func isCandidate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") || name.hasPrefix("~$") { return false }
        return !partialExtensions.contains(url.pathExtension.lowercased())
    }

    /// Drops paths inside another path in the list. FSEvents always watches whole trees,
    /// so nested paths would only report the same event twice.
    public static func outermost(_ paths: [String]) -> [String] {
        let unique = Array(Set(paths.map { URL(filePath: $0).standardizedFileURL.path }))
        return unique.filter { path in !unique.contains { $0 != path && path.hasPrefix($0 + "/") } }.sorted()
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

    /// Waits until the file has stopped changing: size and modification date unchanged for `quiet`,
    /// checked every `interval`. Returns false if the file disappears or never settles within `timeout`.
    ///
    /// Files saved with an atomic rename (screenshots, most apps) are complete when they appear, so they
    /// settle after `quiet`. A file still being written keeps changing and is never handed over half done.
    public static func waitUntilStable(
        _ url: URL, interval: Duration = .milliseconds(250), quiet: Duration = .milliseconds(500),
        timeout: Duration = .seconds(600)
    ) async -> Bool {
        func snapshot() -> (size: Int, modified: Date)? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int, size > 0,
                  let modified = attributes[.modificationDate] as? Date
            else { return nil }
            return (size, modified)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var previous = snapshot()
        var unchangedSince = clock.now
        let quietSeconds = Double(quiet.components.seconds) + Double(quiet.components.attoseconds) / 1e18
        while clock.now < deadline {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return false }
            let current = snapshot()
            guard let current else {
                if !FileManager.default.fileExists(atPath: url.path) { return false }
                previous = nil
                unchangedSince = clock.now
                continue
            }
            guard let last = previous, last.size == current.size, last.modified == current.modified else {
                previous = current
                unchangedSince = clock.now
                continue
            }
            // Unchanged since the last check. Settled once nothing has touched it for `quiet`,
            // judged by our own observation or by the file's own date (a file moved in keeps its old date).
            if clock.now - unchangedSince >= quiet || -current.modified.timeIntervalSinceNow >= quietSeconds {
                return true
            }
        }
        return false
    }
}
