import Foundation
import Testing
@testable import SquishKit

struct FileStabilityTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "squish-stability-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @Test func `a finished file is stable`() async throws {
        let file = dir.appending(path: "done.png")
        try Data(count: 100).write(to: file)
        #expect(await FileState.waitUntilStable(file, interval: .milliseconds(50), timeout: .seconds(2)))
    }

    @Test func `a freshly saved file settles after half a second, not a full second`() async throws {
        let file = dir.appending(path: "Screenshot.png")
        try Data(count: 100).write(to: file)
        let start = ContinuousClock.now
        #expect(await FileState.waitUntilStable(file))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(450) && elapsed < .milliseconds(900), "took \(elapsed)")
    }

    @Test func `a file moved in with an old date settles at the first check`() async throws {
        let file = dir.appending(path: "moved.png")
        try Data(count: 100).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
        let start = ContinuousClock.now
        #expect(await FileState.waitUntilStable(file))
        #expect(ContinuousClock.now - start < .milliseconds(450))
    }

    @Test func `a growing file is not stable until it stops growing`() async throws {
        let file = dir.appending(path: "growing.png")
        try Data(count: 10).write(to: file)
        let writer = Task {
            let handle = try FileHandle(forWritingTo: file)
            for _ in 0..<6 {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(count: 10))
                try await Task.sleep(for: .milliseconds(40))
            }
            try handle.close()
        }
        let start = ContinuousClock.now
        #expect(await FileState.waitUntilStable(file, interval: .milliseconds(60), timeout: .seconds(5)))
        try await writer.value
        #expect(ContinuousClock.now - start >= .milliseconds(200), "returned before the writer finished")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int == 70)
    }

    @Test func `a file that disappears is not stable`() async throws {
        let file = dir.appending(path: "gone.png")
        try Data(count: 10).write(to: file)
        let remover = Task {
            try? await Task.sleep(for: .milliseconds(20))
            try? FileManager.default.removeItem(at: file)
        }
        #expect(!(await FileState.waitUntilStable(file, interval: .milliseconds(80), timeout: .seconds(2))))
        await remover.value
    }

    @Test func `a regular local file is not a placeholder`() throws {
        let file = dir.appending(path: "local.png")
        try Data(count: 10).write(to: file)
        #expect(!FileState.isDataless(file))
        #expect(FileState.isRegularFile(file))
        #expect(!FileState.isRegularFile(dir))
    }
}

struct FolderRulesTests {
    let desktop = WatchedFolder(path: "/Users/test/Desktop")
    let icons: WatchedFolder = {
        var folder = WatchedFolder(path: "/Users/test/OneDrive/Icons")
        folder.recursive = true
        folder.kinds = [.image, .pdf]
        return folder
    }()

    @Test(arguments: ["shot.png.download", "movie.mp4.crdownload", "a.png.part", "x.tmp", ".hidden.png", "~$draft.png"])
    func `partial downloads and hidden files are ignored`(name: String) {
        #expect(!FolderRules.shouldConsider("/Users/test/Desktop/\(name)", folder: desktop))
    }

    @Test func `only enabled kinds are considered`() {
        #expect(FolderRules.shouldConsider("/Users/test/Desktop/a.png", folder: desktop))
        #expect(!FolderRules.shouldConsider("/Users/test/Desktop/a.pdf", folder: desktop))
        #expect(!FolderRules.shouldConsider("/Users/test/Desktop/notes.txt", folder: desktop))
        #expect(FolderRules.shouldConsider("/Users/test/OneDrive/Icons/a.pdf", folder: icons))
    }

    @Test func `non-recursive folders ignore subfolders`() {
        #expect(FolderRules.folder(for: "/Users/test/Desktop/a.png", in: [desktop])?.id == desktop.id)
        #expect(FolderRules.folder(for: "/Users/test/Desktop/sub/a.png", in: [desktop]) == nil)
    }

    @Test func `recursive folders include subfolders, innermost wins`() {
        var parent = WatchedFolder(path: "/Users/test/OneDrive")
        parent.recursive = true
        let folders = [parent, icons]
        #expect(FolderRules.folder(for: "/Users/test/OneDrive/Icons/deep/a.png", in: folders)?.id == icons.id)
        #expect(FolderRules.folder(for: "/Users/test/OneDrive/other/a.png", in: folders)?.id == parent.id)
        #expect(FolderRules.folder(for: "/Users/test/OneDriveX/a.png", in: folders) == nil)
    }

    @Test func `disabled folders are ignored`() {
        var off = desktop
        off.enabled = false
        #expect(FolderRules.folder(for: "/Users/test/Desktop/a.png", in: [off]) == nil)
    }
}

struct SelfWriteGuardTests {
    @Test func `marker round trip`() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "squish-mark-\(UUID().uuidString).png")
        try Data(count: 4).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!SelfWriteGuard.isMarked(file))
        SelfWriteGuard.mark(file)
        #expect(SelfWriteGuard.isMarked(file))
    }

    @Test func `ledger remembers hashes across launches and stays capped`() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "squish-ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = HashLedger(url: url, limit: 3)
        for hash in ["a", "b", "c", "d"] { await ledger.insert(hash) }
        #expect(!(await ledger.contains("a")))
        #expect(await ledger.contains("d"))

        let reloaded = HashLedger(url: url, limit: 3)
        #expect(await reloaded.contains("b"))
        #expect(!(await reloaded.contains("a")))
    }

    @Test func `folder events stream new files only`() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "squish-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 1).write(to: dir.appending(path: "existing.png"))
        try await Task.sleep(for: .milliseconds(300))

        let stream = FolderEventStream(paths: [dir.resolvingSymlinksInPath().path], latency: 0.05)
        defer { stream.stop() }
        try await Task.sleep(for: .milliseconds(200))
        try Data(count: 1).write(to: dir.appending(path: "new.png"))

        var seen: [String] = []
        for await event in stream.events {
            seen.append(URL(filePath: event.path).lastPathComponent)
            if seen.contains("new.png") { break }
        }
        #expect(!seen.contains("existing.png"))
    }
}
