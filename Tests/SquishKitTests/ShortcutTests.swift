import Foundation
import Testing
@testable import SquishKit

struct ShortcutTests {
    @Test func `shortcuts round trip as a keyed object`() throws {
        var settings = Settings()
        settings.shortcuts[.optimizeSelection] = KeyShortcut(keyCode: 31, modifiers: 0x1C_0000, key: "O")
        settings.shortcuts[.convertSelection] = KeyShortcut(keyCode: 96, modifiers: 0, key: "F5")
        let envelope = SettingsEnvelope(modified: Date(timeIntervalSince1970: 1_800_000_000), device: "Mac", settings: settings)
        let data = try SettingsCodec.encode(envelope)
        #expect(String(decoding: data, as: UTF8.self).contains(#""optimizeSelection""#))
        #expect(try SettingsCodec.decode(data) == envelope)
    }

    @Test func `older files have no shortcuts, and a cleared shortcut stays cleared`() throws {
        let old = #"{"modified":"2026-11-13T10:00:00Z","device":"Old Mac","settings":{}}"#
        #expect(try SettingsCodec.decode(Data(old.utf8)).settings.shortcuts.isEmpty)

        let one = #"{"modified":"2026-11-13T10:00:00Z","device":"Mac","settings":{"shortcuts":{"togglePause":{"keyCode":35,"modifiers":1572864,"key":"P"}}}}"#
        let shortcuts = try SettingsCodec.decode(Data(one.utf8)).settings.shortcuts
        #expect(shortcuts.all.count == 1 && shortcuts[.togglePause]?.key == "P")
    }

    @Test func `unknown actions from newer versions fail soft`() throws {
        let newer = #"{"modified":"2026-11-13T10:00:00Z","device":"New Mac","settings":{"shortcuts":{"somethingNew":{"keyCode":1,"modifiers":0,"key":"S"}}}}"#
        // A newer action name must not wipe the whole settings file.
        let decoded = try SettingsCodec.decode(Data(newer.utf8))
        #expect(decoded.settings.shortcuts.isEmpty)
    }
}
