import AppKit
import Carbon
import ModuleCore

/// Narrow key registration adapted from OmniVoice. No global event tap or
/// keystroke monitoring; duplicate/conflicting shortcuts fail visibly.
@MainActor final class PushToTalk {
    var pressed: (() -> Void)?
    var released: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var down = false
    static let choices = ["Off", "⌃⌥V", "⌃⌥Space", "⌃⇧V"]
    func configure(_ choice: String) throws {
        stop(); guard choice != "Off" else { return }
        guard Self.choices.contains(choice) else { throw VoiceProblem.message("Choose a supported shortcut.") }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var keyID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &keyID) == noErr,
                  keyID.signature == 0x4E565043, keyID.id == 1 else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<PushToTalk>.fromOpaque(context).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            MainActor.assumeIsolated { controller.handle(pressed) }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw VoiceProblem.message("Could not install the shortcut handler.") }
        let key = choice == "⌃⌥Space" ? kVK_Space : kVK_ANSI_V
        let modifiers = controlKey | (choice == "⌃⇧V" ? shiftKey : optionKey)
        let registration = RegisterEventHotKey(UInt32(key), UInt32(modifiers), EventHotKeyID(signature: 0x4E565043, id: 1), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
        guard registration == noErr else { stop(); throw VoiceProblem.message("That shortcut is unavailable. Choose another one.") }
    }
    private func handle(_ pressed: Bool) {
        if pressed { guard !down else { return }; down = true; self.pressed?() }
        else { guard down else { return }; down = false; released?() }
    }
    func stop() { if let reference { UnregisterEventHotKey(reference) }; reference = nil; if let handler { RemoveEventHandler(handler) }; handler = nil; down = false }
}
