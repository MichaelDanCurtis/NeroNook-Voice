import SwiftUI
import NookPluginSDK
import AppKit
import ModuleCore

/// A temporary local recorder; no characters are stored or monitored after it closes.
struct ShortcutRecorder: View {
    @ObservedObject var model: VoiceModel
    @State private var recording = false
    @State private var monitor: Any?
    @State private var pendingModifiers: UInt32 = 0
    @State private var hint = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Dictation shortcut"); Spacer()
                Text(recording ? "Press and release your shortcut" : model.shortcutName).font(.system(.body, design: .monospaced))
                Button(recording ? "Cancel" : "Record…") { if recording { stop(restore: true) } else { start() } }
                Button("Off") { stop(restore: false); model.chooseShortcut(nil) }.disabled(model.shortcut == nil && !recording)
            }
            HStack {
                Button("Fn · default") { stop(restore: false); model.chooseShortcut(.standard) }
                Button("⌥⌘") { stop(restore: false); model.chooseShortcut(.optionCommand) }
                Text(recording ? hint : "Fn, modifiers, key combinations or F-keys.").font(.caption).pluginSecondaryText()
            }
        }.disabled(model.busy)
        .onDisappear { if recording { stop(restore: true) } }
    }
    private func start() {
        model.pauseShortcutForRecording(); recording = true; pendingModifiers = 0
        hint = "Release all modifiers to save a modifier-only hold. Escape cancels."
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard recording else { return event }
            let modifiers = PushToTalk.modifiers(event.cgEvent?.flags ?? [])
            if event.type == .flagsChanged {
                if modifiers != 0 { if modifiers.nonzeroBitCount >= pendingModifiers.nonzeroBitCount { pendingModifiers = modifiers } }
                else if pendingModifiers != 0 { commit(.init(modifiers: pendingModifiers)) }
                return nil
            }
            if event.keyCode == 53 && modifiers == 0 { stop(restore: true); return nil }
            let label: String
            let fkeys: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
            if let index = fkeys.firstIndex(of: event.keyCode) { label = "F\(index + 1)" }
            else { switch event.keyCode {
                case 49: label = "Space"
                case 36: label = "Return"
                case 48: label = "Tab"
                case 51: label = "Delete"
                case 53: label = "Esc"
                default: label = event.charactersIgnoringModifiers?.uppercased() ?? ""
            } }
            commit(.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label))
            return nil
        }
    }
    private func commit(_ candidate: DictationShortcut) {
        guard candidate.valid else { hint = "Use Fn, modifiers, a key combination or an F-key."; return }
        stop(restore: false); model.chooseShortcut(candidate)
    }
    private func stop(restore: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; recording = false; pendingModifiers = 0; hint = ""
        if restore { model.resumeShortcutAfterRecording() }
    }
}
