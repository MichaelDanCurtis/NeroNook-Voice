import Foundation

/// UTF-16 edit planning, adapted from OmniVoice's TextInsertionEdit. The caller
/// must revalidate focus, value and selection before applying this plan.
public struct DictationEdit: Equatable {
    public let before: String
    public let selection: NSRange
    public let insertion: String
    public let after: String
    public var insertedRange: NSRange { NSRange(location: selection.location, length: (insertion as NSString).length) }
    public var caret: NSRange { NSRange(location: insertedRange.location + insertedRange.length, length: 0) }
    public var replacedText: String { (before as NSString).substring(with: selection) }

    public init?(value: String, selection: NSRange, insertion: String) {
        guard value.utf8.count <= 131_072,
              Self.valid(selection, in: value) else { return nil }
        self.before = value; self.selection = selection; self.insertion = insertion
        self.after = (value as NSString).replacingCharacters(in: selection, with: insertion)
    }
    public func matches(value: String, selection: NSRange) -> Bool {
        before == value && self.selection == selection
    }
    public func canUndo(value: String, selection: NSRange) -> Bool {
        after == value && caret == selection
    }
    public static func valid(_ range: NSRange, in text: String) -> Bool {
        let units = Array(text.utf16)
        guard range.location >= 0, range.length >= 0, range.location <= units.count,
              range.length <= units.count - range.location else { return false }
        for offset in [range.location, range.location + range.length] where offset > 0 && offset < units.count {
            if (0xD800...0xDBFF).contains(units[offset - 1]) && (0xDC00...0xDFFF).contains(units[offset]) { return false }
        }
        return true
    }
}

public enum DictationShortcutStyle: String, CaseIterable { case hold = "Hold to talk", toggle = "Press to start / stop" }

/// Release belongs only to a recording started by this shortcut. A second
/// toggle press stops even while the microphone is still preparing.
public struct DictationShortcutState {
    public enum Action: Equatable { case start, stop, none }
    private var ownsRecording = false
    public init() {}
    public mutating func press(style: DictationShortcutStyle, busy: Bool) -> Action {
        if style == .toggle && ownsRecording { ownsRecording = false; return .stop }
        guard !busy else { return .none }
        ownsRecording = true; return .start
    }
    public mutating func release(style: DictationShortcutStyle) -> Action {
        guard style == .hold && ownsRecording else { return .none }
        ownsRecording = false; return .stop
    }
    public mutating func reset() { ownsRecording = false }
}
