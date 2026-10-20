import AppKit
import ApplicationServices
import Carbon
import ModuleCore

/// Carbon handles ordinary registered hotkeys. An Accessibility-authorized event
/// tap handles modifier-only/Fn bindings, inspecting codes/flags only, never text.
@MainActor final class PushToTalk {
    var pressed: (() -> Void)?
    var released: (() -> Void)?
    var cancelled: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var arm: Task<Void, Never>?
    private var modifierState = ModifierHoldState()
    private var choice: DictationShortcut?
    private var down = false
    private var generation = UUID()
    func configure(_ choice: DictationShortcut?) throws {
        stop(); guard let choice else { return }
        guard choice.valid else { throw VoiceProblem.message("Choose Fn, modifiers, a modified key or a function key.") }
        self.choice = choice
        if choice.trigger == .modifiers || choice.modifiers & DictationShortcut.fn != 0 { try configureTap(); return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)), EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var keyID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &keyID) == noErr,
                  keyID.signature == 0x4E565043, keyID.id == 1 else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<PushToTalk>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.handle(GetEventKind(event) == UInt32(kEventHotKeyPressed)) }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw VoiceProblem.message("Could not install the shortcut handler.") }
        let result = RegisterEventHotKey(choice.keyCode, choice.modifiers, EventHotKeyID(signature: 0x4E565043, id: 1), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
        guard result == noErr else { stop(); throw VoiceProblem.message("That shortcut is unavailable. Choose another one.") }
    }
    static func modifiers(_ flags: CGEventFlags) -> UInt32 {
        var value: UInt32 = 0
        let mapping: [(CGEventFlags, UInt32)] = [(.maskControl,4096),(.maskAlternate,2048),(.maskShift,512),(.maskCommand,256),(.maskSecondaryFn,DictationShortcut.fn)]
        for (flag, code) in mapping {
            if flags.contains(flag) { value |= code }
        }
        return value
    }
    private func configureTap() throws {
        guard AXIsProcessTrusted() else { throw VoiceProblem.message("Allow Nero Voice in Accessibility for Fn/modifier shortcuts and text insertion.") }
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                Unmanaged<PushToTalk>.fromOpaque(context).takeUnretainedValue().receive(type, event)
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw VoiceProblem.message("macOS could not enable the global shortcut. Check Nero Voice Accessibility access.") }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0); self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            arm?.cancel(); modifierState.reset(); if down { down = false; deferCallback { $0.cancelled?() } }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let choice else { return Unmanaged.passUnretained(event) }
        let flags = Self.modifiers(event.flags), key = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        if choice.trigger == .modifiers {
            let effect = type == .flagsChanged ? modifierState.flags(flags, target: choice.modifiers) : modifierState.key(key, down: type == .keyDown)
            apply(effect)
            // Consume the configured Globe/Fn gesture so its release does not
            // also open Emoji or system dictation. Other typing passes through.
            if type == .flagsChanged && key == 63 && choice.modifiers & DictationShortcut.fn != 0 { return nil }
        } else {
            if type == .keyDown && key == choice.keyCode && flags == choice.modifiers { handle(true); return nil }
            if down && ((type == .keyUp && key == choice.keyCode) || (type == .flagsChanged && flags & choice.modifiers != choice.modifiers)) { handle(false); return type == .keyUp ? nil : Unmanaged.passUnretained(event) }
        }
        return Unmanaged.passUnretained(event)
    }
    private func apply(_ effect: ModifierHoldState.Effect) {
        switch effect {
        case .none: break
        case .arm:
            arm?.cancel(); arm = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self else { return }
                self.apply(self.modifierState.armCompleted())
            }
        case .press: handle(true)
        case .release: arm?.cancel(); handle(false)
        case .cancel: arm?.cancel(); if down { down = false; deferCallback { $0.cancelled?() } }
        }
    }
    private func handle(_ pressed: Bool) {
        if pressed { guard !down else { return }; down = true; deferCallback { $0.pressed?() } }
        else { guard down else { return }; down = false; deferCallback { $0.released?() } }
    }
    private func deferCallback(_ callback: @escaping (PushToTalk) -> Void) {
        let expected = generation
        DispatchQueue.main.async { [weak self] in guard let self, self.generation == expected else { return }; callback(self) }
    }
    func stop() {
        generation = UUID()
        arm?.cancel(); arm = nil; modifierState.reset()
        if let reference { UnregisterEventHotKey(reference) }; reference = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }; tap = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }; source = nil
        choice = nil; down = false
    }
}
