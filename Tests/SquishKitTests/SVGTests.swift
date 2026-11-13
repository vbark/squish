import Foundation
import ImageIO
import Testing
@testable import SquishKit

struct SVGTests {
    static let fixtures = FixtureTests.fixtures

    @Test func `viewBox without width and height uses the viewBox`() throws {
        #expect(try SVG.intrinsicSize(of: Self.fixtures.appending(path: "gradient.svg")) == CGSize(width: 240, height: 120))
    }

    @Test func `units convert at 96 dpi`() throws {
        let size = try SVG.intrinsicSize(of: Self.fixtures.appending(path: "sized.svg"))
        #expect(abs(size.width - 85.333) < 0.01)
        #expect(abs(size.height - 42.667) < 0.01)
        #expect(SVG.length("1in", relativeTo: nil) == 96)
        #expect(SVG.length("50%", relativeTo: 300) == 150)
        #expect(SVG.length("50%", relativeTo: nil) == nil)
    }

    @Test(arguments: zip([0.5, 1, 2, 3, 1.5], [(120, 60), (240, 120), (480, 240), (720, 360), (360, 180)]))
    func `output dimensions per scale`(scale: Double, expected: (Int, Int)) {
        let pixels = SVG.pixelSize(CGSize(width: 240, height: 120), scale: scale)
        #expect(pixels.width == expected.0 && pixels.height == expected.1)
    }

    @Test func `naming schemes`() {
        let svg = URL(filePath: "/tmp/icon.svg")
        #expect(SVG.outputName(for: svg, scale: 1, naming: .scaleSuffix, pixels: (64, 64)) == "icon.png")
        #expect(SVG.outputName(for: svg, scale: 2, naming: .scaleSuffix, pixels: (128, 128)) == "icon@2x.png")
        #expect(SVG.outputName(for: svg, scale: 0.5, naming: .scaleSuffix, pixels: (32, 32)) == "icon@0.5x.png")
        #expect(SVG.outputName(for: svg, scale: 3, naming: .dimensions, pixels: (192, 96)) == "icon-192x96.png")
    }

    @Test(.enabled(if: FixtureTests.toolsBuilt), arguments: [0.5, 1, 2, 3])
    func `resvg renders at the promised size and never overwrites foreign files`(scale: Double) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "squish-svg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let svg = dir.appending(path: "gradient.svg")
        try FileManager.default.copyItem(at: Self.fixtures.appending(path: "gradient.svg"), to: svg)
        let expected = SVG.pixelSize(CGSize(width: 240, height: 120), scale: scale)

        let png = try await SVG.render(svg, scale: scale, naming: .scaleSuffix, tools: FixtureTests.tools)
        let source = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == expected.width)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == expected.height)
        #expect(SelfWriteGuard.isMarked(png))
        #expect(FileManager.default.fileExists(atPath: svg.path))

        // Rendering again replaces Squish's own PNG...
        #expect(try await SVG.render(svg, scale: scale, naming: .scaleSuffix, tools: FixtureTests.tools) == png)
        // ...but a PNG the user made is kept and the new one gets a numbered name.
        try FileManager.default.removeItem(at: png)
        try Data("mine".utf8).write(to: png)
        let second = try await SVG.render(svg, scale: scale, naming: .scaleSuffix, tools: FixtureTests.tools)
        #expect(second.lastPathComponent.hasSuffix(" 2.png"))
        #expect(try String(contentsOf: png, encoding: .utf8) == "mine")
    }
}
