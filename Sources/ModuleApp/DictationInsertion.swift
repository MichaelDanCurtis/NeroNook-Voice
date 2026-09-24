import AppKit
import ApplicationServices
import ModuleCore

/// Plugin-owned insertion. Inspired by OmniVoice's captured target and transient
/// pasteboard, with strict revalidation and no fallback to a different field.
@MainActor final class DictationInsertion {
    struct Target {
        let element: AXUIElement
        let pid: pid_t
        let name: String
        let value: String
        let selection: NSRange
    }
    private var undo: (Target, DictationEdit)?
    private var restoreClipboard: (() -> Void)?
    var canUndo: Bool { undo != nil }
    var permitted: Bool { AXIsProcessTrusted() }
    func shutdown() { restoreClipboard?(); restoreClipboard = nil }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    func capture() throws -> Target {
        guard permitted else { throw problem("Enable Accessibility for Nero Voice in Voice settings to dictate into other apps.") }
        guard let element = focused() else {
            throw problem("macOS did not expose a focused text field. Click inside the destination editor, then try again.")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else {
            throw problem("Place the cursor in another app, then use your dictation shortcut.")
        }
        let state = try textState(element)
        return Target(element: element, pid: app.processIdentifier, name: app.localizedName ?? "your app", value: state.0, selection: state.1)
    }
    func insert(_ text: String, into target: Target) async throws {
        undo = nil
        try VoiceSession.validate(text)
        let current = try validate(target)
        guard let edit = DictationEdit(value: target.value, selection: target.selection, insertion: text),
              edit.matches(value: current.0, selection: current.1) else {
            throw problem("The text or cursor changed. Your transcript is kept in Nero Voice.")
        }
        try await paste(text, target: target)
        let result = try validate(target)
        guard result.0 == edit.after else {
            throw problem("Paste was sent, but this app did not confirm the result. Check it before pasting again; your transcript is kept.")
        }
        undo = (target, edit)
    }
    func undoLast() async throws {
        guard let (target, edit) = undo else { throw problem("No confirmed insertion to undo.") }
        let current = try validate(target)
        guard edit.canUndo(value: current.0, selection: current.1) else {
            throw problem("The text or cursor changed after dictation. Use that app’s Undo instead.")
        }
        var range = CFRange(location: edit.insertedRange.location, length: edit.insertedRange.length)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, value) == .success else {
            throw problem("This app cannot select the insertion. Use its own Undo instead.")
        }
        let selected = try validate(target)
        guard selected.0 == edit.after, selected.1 == edit.insertedRange else {
            throw problem("Could not confirm the inserted selection. Use the app’s Undo instead.")
        }
        undo = nil // A sent paste is never retried automatically.
        try await paste(edit.replacedText, target: target)
        guard try validate(target).0 == edit.before else { throw problem("Undo was sent but could not be confirmed. Check the destination app.") }
    }
    private func validate(_ target: Target) throws -> (String, NSRange) {
        guard permitted, let live = focused(), CFEqual(live, target.element) else {
            throw problem("Focus changed. Your transcript is kept in Nero Voice; nothing is pasted into the new app.")
        }
        return try textState(live)
    }
    private func focused() -> AXUIElement? {
        // Nonactivating panels and accessory apps can have a different active
        // application from the actual keyboard focus. As in OmniVoice, ask the
        // system-wide accessibility element for the authoritative focused field.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        guard let result = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
    private func textState(_ element: AXUIElement) throws -> (String, NSRange) {
        AXUIElementSetMessagingTimeout(element, 0.5)
        // Check the role before reading the value of any possible secure field.
        guard let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              (attribute(element, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole,
              (attribute(element, "AXProtectedContent") as? Bool) != true,
              (attribute(element, kAXEnabledAttribute) as? Bool) != false else {
            throw problem("Choose an editable, non-password text field. Your transcript stays in Nero Voice.")
        }
        guard let text = attribute(element, kAXValueAttribute) as? String, text.utf8.count <= 131_072,
              let rangeValue = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            throw problem("This editor doesn’t expose a readable cursor. Record here, then use Copy.")
        }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
              DictationEdit.valid(NSRange(location: range.location, length: range.length), in: text) else {
            throw problem("This editor’s cursor could not be read. Use Copy for this field.")
        }
        return (text, NSRange(location: range.location, length: range.length))
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func paste(_ text: String, target: Target) async throws {
        try Task.checkCancellation()
        _ = try validate(target)
        // Undoing insertion at an empty caret restores an empty selection using
        // Delete, since many editors ignore an empty-string paste.
        if text.isEmpty {
            guard let source = CGEventSource(stateID: .privateState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) else { throw problem("Could not prepare undo.") }
            let state = try validate(target)
            guard state.1.length > 0 else { throw problem("Nothing is selected to undo.") }
            down.flags = []; up.flags = []
            down.postToPid(target.pid); up.postToPid(target.pid)
            await withCheckedContinuation { continuation in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { continuation.resume() } }
            try Task.checkCancellation(); return
        }
        let board = NSPasteboard.general
        // Eagerly retain all offered formats, bounded to avoid copying huge files.
        var bytes = 0
        let previous: [NSPasteboardItem] = try (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else { throw problem("Clipboard contents could not be preserved. Use Copy when ready.") }
                bytes += data.count
                guard bytes <= 16_777_216 else { throw problem("Clipboard is too large to preserve for dictation. Use Copy when ready.") }
                copy.setData(data, forType: type)
            }
            return copy
        }
        let state = try validate(target)
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw problem("Could not prepare paste. Your transcript is kept.") }
        board.clearContents()
        var lease = board.changeCount
        restoreClipboard = {
            if board.changeCount == lease {
                board.clearContents()
                if !previous.isEmpty { board.writeObjects(previous) }
            }
        }
        defer { restoreClipboard?(); restoreClipboard = nil }
        let wrote = board.setString(text, forType: .string); lease = board.changeCount
        guard wrote else { throw problem("Could not prepare the clipboard.") }
        board.setString("", forType: .init("org.nspasteboard.TransientType")); lease = board.changeCount
        let last = try validate(target)
        guard last.0 == state.0, last.1 == state.1 else { throw problem("The destination changed before paste. Your transcript is kept.") }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(target.pid); up.postToPid(target.pid)
        // Keep the lease alive even on cancellation, since the target may consume
        // a queued paste shortly after it was sent. Never press Return/Send.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { continuation.resume() }
        }
        try Task.checkCancellation()
    }
    private func problem(_ message: String) -> VoiceProblem { .message(message) }
}
