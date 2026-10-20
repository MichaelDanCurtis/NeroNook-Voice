import AppKit
import ApplicationServices
import ModuleCore

/// Pastes a finished transcript into the app that owned the keyboard focus
/// when the shortcut started. Editors do not need to expose their text through
/// Accessibility. If the user switches apps while speaking, keep the draft.
@MainActor final class DictationInsertion {
    struct Target {
        let pid: pid_t
        let appID: String
        let name: String
        let displayNumber: UInt32?
        let window: AXUIElement?
    }

    private var restoreClipboard: (() -> Void)?
    var permitted: Bool { AXIsProcessTrusted() }

    func shutdown() { restoreClipboard?(); restoreClipboard = nil }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func capture() throws -> Target {
        guard permitted else {
            throw problem("Enable Accessibility for Nero Voice in Voice settings to paste into other apps.")
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw problem("Click the app where you want the words, then use the dictation shortcut.")
        }
        let window = focusedWindow(of: app.processIdentifier)
        let displayNumber = display(of: window) ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }).flatMap(screenNumber)
        let target = Target(pid: app.processIdentifier, appID: app.bundleIdentifier ?? "", name: app.localizedName ?? "your app", displayNumber: displayNumber, window: window)
        try validate(target)
        return target
    }

    func insert(_ text: String, into target: Target) async throws {
        try VoiceSession.validate(text)
        // A modifier-only hold can end as the first modifier is released. Wait
        // for the rest before sending Cmd–V, without changing the target app.
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        for _ in 0..<60 {
            try Task.checkCancellation()
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else { throw problem("Release the shortcut keys. Your words are kept in Nero Voice.") }
        try validate(target)

        let board = NSPasteboard.general
        var bytes = 0
        let previous: [NSPasteboardItem] = try (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw problem("Clipboard contents could not be preserved. Use Copy draft when ready.")
                }
                bytes += data.count
                guard bytes <= 16_777_216 else {
                    throw problem("Clipboard is too large to preserve. Use Copy draft when ready.")
                }
                copy.setData(data, forType: type)
            }
            return copy
        }

        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw problem("Could not prepare paste. Your transcript is kept.")
        }

        board.clearContents()
        var lease = board.changeCount
        restoreClipboard = {
            guard board.changeCount == lease else { return }
            board.clearContents()
            if !previous.isEmpty { board.writeObjects(previous) }
        }
        defer { restoreClipboard?(); restoreClipboard = nil }

        guard board.setString(text, forType: .string) else {
            throw problem("Could not prepare the clipboard. Your transcript is kept.")
        }
        lease = board.changeCount
        try validate(target)
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(target.pid)
        up.postToPid(target.pid)

        // Allow the destination to consume the queued paste before restoring
        // the clipboard. Never press Return or Send.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { continuation.resume() }
        }
        try Task.checkCancellation()
    }

    private func validate(_ target: Target) throws {
        guard permitted, NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            throw problem("The active app changed. Your transcript is kept in Nero Voice.")
        }
        if let original = target.window, let current = focusedWindow(of: target.pid), !CFEqual(original, current) {
            throw problem("The active window changed. Your transcript is kept in Nero Voice.")
        }
        // Refuse known password fields without requiring every editor to
        // expose its text, selection, or caret position.
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
        let element = focused as! AXUIElement
        var subrole: CFTypeRef?
        var protected: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        _ = AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &protected)
        if (subrole as? String) == kAXSecureTextFieldSubrole || (protected as? Bool) == true {
            throw problem("Choose a non-password field. Your transcript is kept in Nero Voice.")
        }
    }

    private func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func display(of window: AXUIElement?) -> UInt32? {
        guard let window else { return nil }
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        let center = CGPoint(x: origin.x + dimensions.width / 2, y: origin.y + dimensions.height / 2)
        for screen in NSScreen.screens {
            guard let number = screenNumber(screen) else { continue }
            if CGDisplayBounds(number).contains(center) { return number }
        }
        return nil
    }

    private func screenNumber(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func problem(_ message: String) -> VoiceProblem { .message(message) }
}
