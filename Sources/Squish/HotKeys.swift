import AppKit
import Carbon.HIToolbox
import Observation
import SquishKit

/// System-wide shortcuts through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
@Observable
final class HotKeyCenter {
    /// Actions whose shortcut could not be registered, usually because the system or another app owns it.
    private(set) var failed: Set<ShortcutAction> = []
    /// Set while a shortcut is being recorded, so pressing an existing one records it instead of running it.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { apply() } }
    }

    @ObservationIgnored private var shortcuts: [ShortcutAction: KeyShortcut] = [:]
    @ObservationIgnored private var registered: [EventHotKeyRef] = []
    @ObservationIgnored private var actions: [UInt32: ShortcutAction] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private let perform: (ShortcutAction) -> Void

    private static let signature: OSType = 0x5371_7368 // 'Sqsh'

    init(perform: @escaping (ShortcutAction) -> Void) {
        self.perform = perform
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &pressed,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func update(_ shortcuts: [ShortcutAction: KeyShortcut]) {
        guard shortcuts != self.shortcuts else { return }
        self.shortcuts = shortcuts
        apply()
    }

    fileprivate func fire(_ id: UInt32) {
        guard !isSuspended, let action = actions[id] else { return }
        perform(action)
    }

    private func apply() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered = []
        actions = [:]
        guard !isSuspended else { return }
        var failed: Set<ShortcutAction> = []
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let shortcut = shortcuts[action] else { continue }
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered.append(ref)
                actions[id.id] = action
            } else {
                failed.insert(action)
            }
        }
        if failed != self.failed { self.failed = failed }
    }

    private static func carbonModifiers(_ raw: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        return UInt32(carbon)
    }
}

/// Carbon delivers hot key events on the main thread.
nonisolated private func hotKeyHandler(_: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let pointer = Int(bitPattern: userData), hotKey = id.id
    MainActor.assumeIsolated {
        guard let raw = UnsafeMutableRawPointer(bitPattern: pointer) else { return }
        Unmanaged<HotKeyCenter>.fromOpaque(raw).takeUnretainedValue().fire(hotKey)
    }
    return noErr
}

extension KeyShortcut {
    static let allowedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// ⌃⌥⇧⌘ in Apple's order, then the key.
    var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    /// A shortcut from a key press, or nil when it would clash with normal typing
    /// (no Command, Control or Option, unless it is a function key).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.allowedModifiers)
        let name = Self.specialKeys[event.keyCode]
            ?? event.characters(byApplyingModifiers: [])?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return nil }
        let isFunctionKey = name.hasPrefix("F") && name.count > 1 && Int(name.dropFirst()) != nil
        guard isFunctionKey || !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: flags.rawValue, key: name)
    }

    private static let specialKeys: [UInt16: String] = [
        UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "Space", UInt16(kVK_Delete): "⌫",
        UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_DownArrow): "↓", UInt16(kVK_UpArrow): "↑", UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]
}
