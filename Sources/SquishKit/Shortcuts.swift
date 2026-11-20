import Foundation

/// Things a global keyboard shortcut can do.
public enum ShortcutAction: String, Codable, CaseIterable, Sendable {
    /// Optimize the files selected in Finder.
    case optimizeSelection
    /// Convert the SVGs selected in Finder to PNG.
    case convertSelection
    /// Open the file picker to optimize files.
    case chooseFiles
    /// Pause or resume automatic optimization.
    case togglePause
}

/// A key plus modifiers, recorded in Settings.
public struct KeyShortcut: Codable, Hashable, Sendable {
    /// Virtual key code: the physical key, independent of the keyboard layout.
    public var keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, limited to Control, Option, Shift and Command.
    public var modifiers: UInt
    /// What the key showed when it was recorded, such as "O" or "F5".
    public var key: String

    public init(keyCode: UInt16, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// Shortcut per action. Stored as a JSON object keyed by action name; names this version doesn't know
/// (from a newer version, via settings sync) are skipped instead of failing the whole settings file.
public struct ShortcutMap: Codable, Equatable, Sendable {
    public private(set) var all: [ShortcutAction: KeyShortcut] = [:]

    public init(_ all: [ShortcutAction: KeyShortcut] = [:]) {
        self.all = all
    }

    public subscript(action: ShortcutAction) -> KeyShortcut? {
        get { all[action] }
        set { all[action] = newValue }
    }

    public var isEmpty: Bool { all.isEmpty }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: KeyShortcut].self)
        for (name, shortcut) in raw {
            if let action = ShortcutAction(rawValue: name) { all[action] = shortcut }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: all.map { ($0.key.rawValue, $0.value) }))
    }
}
