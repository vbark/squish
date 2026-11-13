import Foundation
import Testing
@testable import SquishKit

struct SettingsFileTests {
    @Test func `round trip keeps every value`() throws {
        var settings = Settings()
        settings.formats.png = FormatOptions(lossy: true, quality: 65)
        settings.folders.append(WatchedFolder(path: "~/Library/CloudStorage/OneDrive-Personal/Icons"))
        settings.svgNaming = .dimensions
        let envelope = SettingsEnvelope(modified: Date(timeIntervalSince1970: 1_800_000_000), device: "Mac", settings: settings)

        let decoded = try SettingsCodec.decode(SettingsCodec.encode(envelope))
        #expect(decoded == envelope)
    }

    @Test func `missing keys fall back to defaults`() throws {
        let json = #"""
        {"modified":"2026-11-13T10:00:00Z","device":"Old Mac",
         "settings":{"sounds":true,"formats":{"jpeg":{"lossy":true}},
                     "folders":[{"path":"~/Pictures"}]}}
        """#
        let decoded = try SettingsCodec.decode(Data(json.utf8))
        #expect(decoded.settings.sounds)
        #expect(decoded.settings.formats.jpeg == FormatOptions(lossy: true, quality: 80))
        #expect(decoded.settings.formats.png == FormatOptions())
        #expect(decoded.settings.clipboardEnabled)
        #expect(decoded.settings.folders.map(\.path) == ["~/Pictures"])
        #expect(decoded.settings.folders[0].kinds == [.image])
    }

    @Test func `unknown keys from newer versions are ignored`() throws {
        let json = #"{"modified":"2026-11-13T10:00:00Z","device":"New Mac","settings":{"futureThing":42}}"#
        let decoded = try SettingsCodec.decode(Data(json.utf8)).settings
        var expected = Settings()
        expected.folders = decoded.folders // default folders get fresh ids
        #expect(decoded == expected)
    }

    @Test func `file write then read`() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SettingsFile(folder: folder)
        #expect(try file.read() == nil)

        let envelope = SettingsEnvelope(modified: Date(timeIntervalSince1970: 1_800_000_000), device: "A", settings: Settings())
        try file.write(envelope)
        #expect(try file.read() == envelope)
        #expect(file.modificationDate != nil)
    }

    @Test func `folder paths stay home relative`() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = WatchedFolder(url: home.appending(path: "Desktop"))
        #expect(folder.path == "~/Desktop")
        #expect(folder.url.path == home.appending(path: "Desktop").path)
    }
}
