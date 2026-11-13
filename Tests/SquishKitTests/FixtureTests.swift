import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import SquishKit

/// Runs every fixture in Tests/Fixtures through the real bundled tools in Vendor/bin.
/// Skipped when the tools have not been built (Scripts/build-tools.sh).
struct FixtureTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = root.appending(path: "Fixtures")
    static let tools = ToolLocator(directories: [root.deletingLastPathComponent().appending(path: "Vendor/bin")])
    static var toolsBuilt: Bool { (try? tools.url(for: "oxipng")) != nil }

    let pipeline = Pipeline(tools: FixtureTests.tools, limiter: Limiter(limit: 4))
    let out = FileManager.default.temporaryDirectory.appending(path: "squish-fixtures-\(UUID().uuidString)")

    /// Fixtures that must get smaller with default (lossless) settings.
    @Test(.enabled(if: toolsBuilt), arguments: ["sample.png", "sample.jpg", "sample.tiff", "sample-lossless.webp"])
    func `lossless optimization shrinks and keeps the image`(name: String) async throws {
        let input = Self.fixtures.appending(path: name)
        let output = out.appending(path: name)
        let result = await pipeline.optimize(input, to: output, formats: FormatSettings())
        #expect(result.error == nil)
        #expect(result.improved, "\(name): \(result.originalSize) to \(result.newSize)")
        try expectSameDimensions(input, output)
    }

    /// Video, audio and PDF with default settings.
    @Test(.enabled(if: toolsBuilt), arguments: ["sample.mp4", "sample.m4a", "sample.mp3", "sample.pdf"])
    func `media and PDF get smaller and stay readable`(name: String) async throws {
        let input = Self.fixtures.appending(path: name)
        let output = out.appending(path: name)
        let result = await pipeline.optimize(input, to: output, formats: FormatSettings())
        #expect(result.error == nil)
        #expect(result.improved, "\(name): \(result.originalSize) to \(result.newSize)")
        if name.hasSuffix(".pdf") {
            #expect(CGPDFDocument(output as CFURL)?.numberOfPages == 1)
        } else {
            let asset = AVURLAsset(url: output)
            let duration = try await asset.load(.duration).seconds
            #expect(abs(duration - 3) < 0.2, "\(name) lasts \(duration) s")
        }
    }

    /// Fixtures that may already be minimal: no error, and any output is still a valid image.
    @Test(.enabled(if: toolsBuilt), arguments: ["sample.heic", "sample-lossy.webp", "sample.gif"])
    func `lossless optimization never fails`(name: String) async throws {
        let input = Self.fixtures.appending(path: name)
        let output = out.appending(path: name)
        let result = await pipeline.optimize(input, to: output, formats: FormatSettings())
        #expect(result.error == nil)
        if result.improved { try expectSameDimensions(input, output) }
    }

    @Test(.enabled(if: toolsBuilt), arguments: ["sample.png", "sample.jpg", "sample-lossy.webp", "sample.heic", "sample.gif"])
    func `lossy optimization shrinks further`(name: String) async throws {
        var formats = FormatSettings()
        let lossy = FormatOptions(lossy: true, quality: 60)
        formats.png = lossy; formats.jpeg = lossy; formats.webp = lossy; formats.heic = lossy; formats.gif = lossy
        let input = Self.fixtures.appending(path: name)
        let output = out.appending(path: name)
        let result = await pipeline.optimize(input, to: output, formats: formats)
        #expect(result.error == nil)
        #expect(result.improved, "\(name): \(result.originalSize) to \(result.newSize)")
        try expectSameDimensions(input, output)
    }

    func expectSameDimensions(_ a: URL, _ b: URL) throws {
        func size(_ url: URL) throws -> [Int] {
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            return [properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0]
        }
        #expect(try size(a) == size(b))
    }
}
