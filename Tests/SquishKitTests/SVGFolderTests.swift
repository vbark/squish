import Foundation
import Testing
@testable import SquishKit

struct SVGFolderTests {
    @Test func `only finished, visible SVGs count`() {
        #expect(FolderRules.isSVG("/Users/test/Icons/logo.svg"))
        #expect(FolderRules.isSVG("/Users/test/Icons/LOGO.SVG"))
        #expect(!FolderRules.isSVG("/Users/test/Icons/logo.png"))
        #expect(!FolderRules.isSVG("/Users/test/Icons/.logo.svg"))
        #expect(!FolderRules.isSVG("/Users/test/Icons/logo.svg.download"))
    }

    @Test func `SVG folders match like watched folders`() {
        let icons = SVGFolder(path: "/Users/test/Icons", scales: [1, 2])
        var assets = SVGFolder(path: "/Users/test/app/assets")
        assets.recursive = true
        #expect(FolderRules.folder(for: "/Users/test/Icons/a.svg", in: [icons, assets])?.id == icons.id)
        #expect(FolderRules.folder(for: "/Users/test/Icons/sub/a.svg", in: [icons, assets]) == nil)
        #expect(FolderRules.folder(for: "/Users/test/app/assets/svg/a.svg", in: [icons, assets])?.id == assets.id)
    }

    @Test func `scales are sorted, unique and never empty`() {
        var folder = SVGFolder(path: "~/Icons", scales: [3, 1, 3])
        #expect(folder.scales == [1, 3])
        folder.scales = []
        #expect(folder.scales == [1])
        folder.scales.append(0.5)
        #expect(folder.scales == [0.5, 1])
    }

    @Test func `nested watch paths collapse to the outermost`() {
        let paths = FolderRules.outermost(["/Users/test/Desktop", "/Users/test/Desktop/Icons", "/Users/test/Downloads", "/Users/test/Desktop"])
        #expect(paths == ["/Users/test/Desktop", "/Users/test/Downloads"])
        #expect(FolderRules.outermost(["/Users/test/Desk", "/Users/test/Desktop"]) == ["/Users/test/Desk", "/Users/test/Desktop"])
    }

    @Test func `settings without SVG folders still load, partial entries get defaults`() throws {
        let old = #"{"modified":"2026-11-13T10:00:00Z","device":"Old Mac","settings":{"sounds":true}}"#
        #expect(try SettingsCodec.decode(Data(old.utf8)).settings.svgFolders.isEmpty)

        let partial = #"{"modified":"2026-11-13T10:00:00Z","device":"Mac","settings":{"svgFolders":[{"path":"~/Icons"}]}}"#
        let folder = try #require(try SettingsCodec.decode(Data(partial.utf8)).settings.svgFolders.first)
        #expect(folder.path == "~/Icons" && folder.enabled && folder.scales == [1] && !folder.recursive)
    }

    @Test func `round trip keeps SVG folders`() throws {
        var settings = Settings()
        var folder = SVGFolder(path: "~/Icons", scales: [1, 2])
        folder.recursive = true
        settings.svgFolders = [folder]
        let envelope = SettingsEnvelope(modified: Date(timeIntervalSince1970: 1_800_000_000), device: "Mac", settings: settings)
        #expect(try SettingsCodec.decode(SettingsCodec.encode(envelope)) == envelope)
    }

    @Test func `listing finds SVGs, honoring subfolders`() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "squish-svglist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appending(path: "sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.svg", "b.png", ".hidden.svg", "sub/c.svg"] {
            try Data("<svg/>".utf8).write(to: dir.appending(path: name))
        }
        #expect(SVG.files(in: dir, recursive: false).map(\.lastPathComponent) == ["a.svg"])
        #expect(SVG.files(in: dir, recursive: true).map(\.lastPathComponent).sorted() == ["a.svg", "c.svg"])
    }

    @Test(.enabled(if: FixtureTests.toolsBuilt))
    func `automatic conversion makes each size and leaves a PNG the user made alone`() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "squish-svgauto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let svg = dir.appending(path: "gradient.svg")
        try FileManager.default.copyItem(at: FixtureTests.fixtures.appending(path: "gradient.svg"), to: svg)
        let pipeline = Pipeline(tools: FixtureTests.tools, backups: BackupStore(root: dir.appending(path: ".backups")), limiter: Limiter(limit: 2))

        for scale in [1.0, 2.0] {
            let result = try #require(await SVG.convert(svg, scale: scale, naming: .scaleSuffix, formats: FormatSettings(),
                                                        pipeline: pipeline, conflict: .skip))
            #expect(result.error == nil)
        }
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "gradient.png").path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "gradient@2x.png").path))

        // Squish's own PNG is replaced on the next run...
        #expect(await SVG.convert(svg, scale: 1, naming: .scaleSuffix, formats: FormatSettings(), pipeline: pipeline, conflict: .skip) != nil)
        // ...a PNG the user made is skipped, with no numbered copy.
        let mine = dir.appending(path: "gradient@2x.png")
        try FileManager.default.removeItem(at: mine)
        try Data("mine".utf8).write(to: mine)
        #expect(await SVG.convert(svg, scale: 2, naming: .scaleSuffix, formats: FormatSettings(), pipeline: pipeline, conflict: .skip) == nil)
        #expect(try String(contentsOf: mine, encoding: .utf8) == "mine")
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "gradient@2x 2.png").path))
    }
}
