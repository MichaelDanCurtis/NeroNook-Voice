import Foundation

/// Stored physical shortcuts stay independent of the active keyboard layout.
/// The optional trigger field preserves previously saved key-plus-modifier bindings.
public struct DictationShortcut: Codable, Equatable, Sendable {
    public enum Trigger: String, Codable, Sendable { case key, modifiers }
    public let keyCode: UInt32
    public let modifiers: UInt32
    public let keyLabel: String
    public let trigger: Trigger
    public static let fn: UInt32 = 1 << 23
    public static let modifierMask: UInt32 = 4096 | 2048 | 512 | 256 | fn
    public static let standard = DictationShortcut(modifiers: fn)
    public static let optionCommand = DictationShortcut(modifiers: 2048 | 256)
    public static let legacyStandard = DictationShortcut(keyCode: 9, modifiers: 4096 | 2048, keyLabel: "V")
    public static let functionKeys: Set<UInt32> = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
    private static let modifierKeys: Set<UInt32> = [54,55,56,57,58,59,60,61,62,63]
    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel; trigger = .key
    }
    public init(modifiers: UInt32) { keyCode = 0; self.modifiers = modifiers; keyLabel = ""; trigger = .modifiers }
    private enum CodingKeys: String, CodingKey { case keyCode, modifiers, keyLabel, trigger }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decode(UInt32.self, forKey: .keyCode)
        modifiers = try c.decode(UInt32.self, forKey: .modifiers)
        keyLabel = try c.decode(String.self, forKey: .keyLabel)
        trigger = try c.decodeIfPresent(Trigger.self, forKey: .trigger) ?? .key
    }
    public var valid: Bool {
        guard modifiers & ~Self.modifierMask == 0 else { return false }
        if trigger == .modifiers { return modifiers != 0 && keyCode == 0 && keyLabel.isEmpty }
        return keyCode < 128 && !Self.modifierKeys.contains(keyCode) &&
            (modifiers != 0 || Self.functionKeys.contains(keyCode)) &&
            !keyLabel.isEmpty && keyLabel.utf8.count <= 16
    }
    public var displayName: String {
        var parts = modifiers & Self.fn != 0 ? "Fn" : ""
        if modifiers & 4096 != 0 { parts += "⌃" }
        if modifiers & 2048 != 0 { parts += "⌥" }
        if modifiers & 512 != 0 { parts += "⇧" }
        if modifiers & 256 != 0 { parts += "⌘" }
        return parts + (trigger == .key ? keyLabel : "")
    }
    public static func fromLegacy(_ value: String) -> DictationShortcut? {
        switch value {
        case "Off": nil
        case "Fn": .standard
        case "⌃⌥Space": .init(keyCode: 49, modifiers: 4096 | 2048, keyLabel: "Space")
        case "⌃⇧V": .init(keyCode: 9, modifiers: 4096 | 512, keyLabel: "V")
        default: .legacyStandard
        }
    }
}

/// Modifier-only holds are delayed briefly so Fn+arrows/function keys and ordinary
/// app shortcuts do not produce accidental dictation. No typed characters enter it.
public struct ModifierHoldState: Sendable {
    public enum Effect: Equatable { case none, arm, press, release, cancel }
    public private(set) var armed = false
    public private(set) var pressed = false
    private var blocked = false
    private var heldKeys = Set<UInt32>()
    private var current: UInt32 = 0
    public init() {}
    public mutating func flags(_ value: UInt32, target: UInt32) -> Effect {
        current = value & DictationShortcut.modifierMask
        if current == 0 { blocked = false }
        if current == target && !blocked && heldKeys.isEmpty {
            guard !pressed && !armed else { return .none }
            armed = true; return .arm
        }
        armed = false
        if pressed {
            pressed = false
            if current & ~target != 0 { blocked = true; return .cancel }
            blocked = current != 0
            return .release
        }
        return .none
    }
    public mutating func key(_ code: UInt32, down: Bool) -> Effect {
        if down { heldKeys.insert(code); let active = pressed; armed = false; pressed = false; blocked = true; return active ? .cancel : .none }
        heldKeys.remove(code)
        if current == 0 && heldKeys.isEmpty { blocked = false }
        return .none
    }
    public mutating func armCompleted() -> Effect {
        guard armed && !blocked && heldKeys.isEmpty else { return .none }
        armed = false; pressed = true; return .press
    }
    public mutating func reset() { self = Self() }
}
