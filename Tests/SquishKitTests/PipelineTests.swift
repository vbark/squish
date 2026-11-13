import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SquishKit

/// Runs the real pipeline against fake tools written as shell scripts.
struct PipelineTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "squish-tests-\(UUID().uuidString)")
    var bin: URL { dir.appending(path: "bin") }
    var work: URL { dir.appending(path: "work") }

    init() throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    func fakeTool(_ name: String, keepBytes: Int) throws {
        // Copies the first `keepBytes` bytes of the last argument to the path after --out.
        let script = """
        #!/bin/sh
        while [ $# -gt 1 ]; do [ "$1" = --out ] && out=$2; shift; done
        head -c \(keepBytes) "$1" > "$out"
        """
        let url = bin.appending(path: name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func pipeline() -> Pipeline {
        Pipeline(
            tools: ToolLocator(directories: [bin]),
            backups: BackupStore(root: dir.appending(path: "backups")),
            limiter: Limiter(limit: 2)
        )
    }

    func makeFile(_ name: String, bytes: Int) throws -> URL {
        let url = work.appending(path: name)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    func size(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    @Test func `smaller output replaces the original and keeps a backup`() async throws {
        try fakeTool("oxipng", keepBytes: 10)
        let file = try makeFile("a.png", bytes: 100)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: file.path)
        try (file as NSURL).setResourceValue(["Blue"], forKey: .tagNamesKey)

        let result = await pipeline().optimizeFile(file, formats: FormatSettings())

        #expect(result.error == nil)
        #expect(result.originalSize == 100)
        #expect(result.newSize == 10)
        #expect(try size(file) == 10)
        let backup = try #require(result.backup)
        #expect(try size(backup) == 100)

        let values = try URL(filePath: file.path).resourceValues(forKeys: [.creationDateKey, .tagNamesKey])
        #expect(values.creationDate == created)
        #expect(values.tagNames == ["Blue"])
        #expect(SelfWriteGuard.isMarked(file), "replaced file must carry the marker so folder events skip it")

        try pipeline().backups.restore(backup, to: file)
        #expect(try size(file) == 100)
        #expect(SelfWriteGuard.isMarked(file), "a restored original must not be optimized again")
    }

    @Test func `output that is not smaller leaves the file alone`() async throws {
        try fakeTool("oxipng", keepBytes: 1000)
        let file = try makeFile("b.png", bytes: 100)
        let result = await pipeline().optimizeFile(file, formats: FormatSettings())
        #expect(result.error == nil)
        #expect(result.backup == nil)
        #expect(result.newSize == 100)
        #expect(try size(file) == 100)
    }

    @Test func `missing tool is an error, not a crash`() async throws {
        let file = try makeFile("c.png", bytes: 100)
        let result = await pipeline().optimizeFile(file, formats: FormatSettings())
        #expect(result.error == .missingTool("oxipng"))
        #expect(try size(file) == 100)
    }

    @Test func `unsupported type is reported`() async throws {
        let file = try makeFile("d.txt", bytes: 100)
        let result = await pipeline().optimizeFile(file, formats: FormatSettings())
        #expect(result.error == .unsupported("TXT"))
    }

    @Test func `limiter never exceeds its limit`() async {
        let limiter = Limiter(limit: 2)
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await limiter.acquire()
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(20))
                    await counter.leave()
                    await limiter.release()
                }
            }
        }
        #expect(await counter.peak == 2)
    }

    @Test func `old backups are pruned`() throws {
        let store = BackupStore(root: dir.appending(path: "backups"))
        let file = try makeFile("e.png", bytes: 10)
        let replacement = try makeFile("e2.png", bytes: 5)
        let backup = try store.replace(file, with: replacement)
        store.prune(olderThan: 7, now: .now.addingTimeInterval(8 * 86_400))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }
}

actor Counter {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

/// Uses a real jpegtran when one is installed (Homebrew), to check EXIF orientation survives.
struct JPEGOrientationTests {
    static let systemTools = ToolLocator(directories: [
        URL(filePath: "/opt/homebrew/opt/mozjpeg/bin"), URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin"),
    ])
    static var hasJpegtran: Bool { (try? systemTools.url(for: "jpegtran")) != nil }

    @Test(.enabled(if: hasJpegtran)) func `orientation tag survives lossless optimization`() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appending(path: "in.jpg"), output = dir.appending(path: "out.jpg")

        // 64x32 gradient JPEG tagged "rotate 90° CW" (orientation 6) plus a GPS block that must go.
        let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 32))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(input as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.0, kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))

        try await JPEGOptimizer().optimize(input, to: output, options: FormatOptions(), tools: Self.systemTools)

        #expect(ImageMetadata.orientation(of: output) == 6)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 64)
    }
}
