import AppKit
import AVFoundation
import SwiftUI
import Combine
import ModuleCore
import VoiceAudio
import NookPluginSDK

@MainActor final class VoicePlugin: ObservableObject {
    let model = VoiceModel()
    let meetings = MeetingModel()
    private var customViews = false
    let id = "cafe.nero.plugin.voice"
    let hosted = CommandLine.arguments.contains("--neronook-plugin")
    let test = CommandLine.arguments.contains("--protocol-test")
    private let channel = PluginApplicationChannel()
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var lines = PluginLines()
    private var accumulator = PluginCatalogAccumulator()
    private var seen = Set<UUID>()
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    init() {
        model.changed = { [weak self] in self?.publish() }
        meetings.changed = { [weak self] in self?.publish() }
        meetings.canStart = { [weak self] in guard let self else { return false }; return !self.model.session.recording && !self.model.waiting && !self.model.preparingAssets && !self.model.inserting }
        meetings.microphone = { [weak self] in self?.model.microphone ?? "" }
        meetings.locale = { [weak self] in self?.model.locale ?? "en-US" }
        model.meetingActive = { [weak self] in self?.meetings.occupied ?? false }
        model.reveal = { [weak self] in self?.showWindow() }
        if hosted {
            NSApplication.shared.setActivationPolicy(.accessory)
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Serve Nero Voice")
            if let channel {
                channel.start { [weak self] message in Task { @MainActor in guard let self else { return }; guard let message else { self.shutdown(); exit(0) }; self.receive(message) } }
            } else if test {
                FileHandle.standardInput.readabilityHandler = { [weak self] input in
                    let data = input.availableData
                    Task { @MainActor in guard let self else { return }; guard !data.isEmpty else { self.shutdown(); exit(0) }; do { for message in try self.lines.append(data) { self.receive(message) } } catch { self.shutdown(); exit(1) } }
                }
            } else { model.status = "Launch this module through NeroNook 0.14 or newer" }
            model.invoke = { [weak self] request, address, values in self?.bus(.init(.invoke, requestID: request, address: address, values: values)) }
            model.cancelInvocation = { [weak self] request in self?.bus(.init(.cancel, requestID: request)) }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.model.refreshSpeechState(); self?.meetings.tick(); self?.publish() } }; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func shutdown() { meetings.shutdown(); model.shutdown() }
    func showWindow() { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil) }
    private func receive(_ m: PluginMessage) {
        guard m.pluginID == id else { shutdown(); exit(1) }
        if session == nil {
            guard m.type == "hello", m.features?.contains("forms-v1") == true else { shutdown(); exit(1) }
            customViews = m.features?.contains("custom-views-v1") == true
            session = m.session; emit("ready", features: ["panels-v1", "dashboard-v1", "forms-v1", "actions-v1"] + (customViews ? ["custom-views-v1"] : []))
            bus(.init(.register, registration: .init(actions: [VoiceContract.submit]))); bus(.init(.discover)); publish(); return
        }
        guard m.session == session else { shutdown(); exit(1) }
        if m.type == "viewEvent", let event = m.viewEvent {
            do { try meetings.handle(event) } catch { meetings.status = error.localizedDescription }; publish(); return
        }
        if m.type == "action", let action = m.action {
            if action == "configure" { model.settings = true; model.refreshDevices(); showWindow() }
            if action == "record", !test { if model.session.recording { model.stopRecording() } else { model.record() } }
            if action == "cancel" { model.cancel(); meetings.process("cancel"); if meetings.active { meetings.finish(paused: false) } }
            if action == "open_meetings" { showWindow() }
            if action == "restore" { model.restore() }
            if action == "dictionary" { model.applyDictionary() }
            if action == "speak", !test { if model.speaking { model.stopSpeaking() } else { model.speak() } }
            if action == "clear" { model.clear() }
        }
        if let bus = m.bus {
            switch bus.operation {
            case .catalog: if (try? accumulator.receive(bus)) == true { model.updateCatalog(accumulator.entries.filter { $0.address.plugin != id }) }
            case .execute:
                guard !seen.contains(bus.requestID), seen.count < 4096 else { self.bus(.init(.update, requestID: bus.requestID, update: .init(.failed, message: "Duplicate request or session limit reached"))); return }
                seen.insert(bus.requestID)
                do {
                    guard !test, bus.address == PluginActionAddress(id, VoiceContract.submit.id), let values = bus.values else { throw VoiceProblem.message("Invalid transcript request") }
                    try model.submit(values)
                    self.bus(.init(.update, requestID: bus.requestID, update: .init(.succeeded, message: "Reviewed transcript accepted")))
                } catch { self.bus(.init(.update, requestID: bus.requestID, update: .init(.failed, message: String(error.localizedDescription.prefix(450))))) }
            case .update: if let update = bus.update { model.receive(bus.requestID, update: update) }
            case .failure: model.receive(bus.requestID, update: .init(.failed, message: bus.error ?? "Assistant unavailable"))
            default: break
            }
        }
        publish()
    }
    private func publish() {
        guard session != nil else { return }
        var sections: [PluginSection] = []
        if model.session.recording {
            sections = [.init(model.session.phase == .listening ? "Listening on your Mac" : "Preparing / finishing", model.session.transcript.isEmpty ? "Your words appear here. Nothing is sent automatically." : String(model.session.transcript.prefix(1200)))]
        } else if !model.reply.isEmpty { sections = [.init("Reply", String(model.reply.prefix(1200)))] }
        else { sections = [.init("Your words, your choice", "Use your shortcut in another app to dictate at its cursor. Record here to review first. Ask sends only text you choose to your assistant. Choose hold or toggle in Voice settings.")] }
        let form = PluginForm("transcript", title: "Review transcript", revision: model.revision.uuidString, action: VoiceContract.submit, inputs: [
            .init("text", label: "Your words", style: .text, value: .string(model.session.transcript)),
            .init("destination", label: "Use text", style: .choice, value: .string("Copy"), choices: model.assistant == nil ? ["Copy"] : ["Copy", "Ask"]),
            .init("read_reply", label: "Read reply aloud", style: .toggle, value: .boolean(false))
        ], enabled: !model.busy)
        let actions: [PluginAction] = [
            .init("record", model.session.recording ? "Stop dictation" : "Record dictation", enabled: !meetings.occupied && !model.waiting && !model.preparingAssets && model.session.phase != .finishing, symbol: model.session.recording ? "stop.fill" : "mic.fill"),
            .init("cancel", "Cancel", enabled: model.busy || model.speaking, symbol: "xmark"),
            .init("speak", model.speaking ? "Stop speaking" : "Read reply", enabled: !model.busy && !model.reply.isEmpty, symbol: "speaker.wave.2.fill"),
            .init("restore", "Original words", enabled: !model.busy && !model.session.raw.isEmpty, symbol: "arrow.uturn.backward"),
            .init("dictionary", "Apply spellings", enabled: !model.busy && !model.dictionary.isEmpty && !model.session.transcript.isEmpty, symbol: "textformat.abc"),
            .init("clear", "Clear", enabled: !model.busy, symbol: "trash")
        ]
        let status = meetings.occupied ? meetings.status : model.status
        let snapshot = PluginSnapshot(title: "Nero Voice", status: String(status.prefix(200)), activity: String(status.prefix(100)), actions: actions, badge: meetings.active ? "Meeting" : model.session.phase == .listening ? "Recording" : "On-device", panels: [
            .init("voice", "Dictate", sections: sections, forms: model.session.recording ? nil : [form]),
            customViews ? .init("meetings", "Meetings", customView: meetings.definition) : .init("meetings", "Meetings", sections: [.init("Meeting recordings", "Open Nero Voice for meeting recording, bookmarks and playback.")])
        ])
        do { try snapshot.validate(); emit("snapshot", snapshot: snapshot) }
        catch { emit("snapshot", snapshot: PluginSnapshot(title: "Nero Voice", status: "Voice view unavailable. Open settings or stop the current activity.", actions: [.init("cancel", "Stop activity", enabled: true, symbol: "stop.fill")], sections: [.init("Display issue", String(error.localizedDescription.prefix(200)))])) }
    }
    private func bus(_ value: PluginBusMessage) { emit("bus", bus: value) }
    private func emit(_ type: String, features: [String]? = nil, snapshot: PluginSnapshot? = nil, bus: PluginBusMessage? = nil) {
        guard let session else { return }; if type != "ready" { sequence += 1 }
        let message = PluginMessage(type: type, pluginID: id, session: session, sequence: sequence, snapshot: snapshot, features: features, bus: bus)
        do { if let channel { try channel.send(message) } else if test { try FileHandle.standardOutput.write(contentsOf: message.encoded()) } }
        catch { shutdown(); exit(1) }
    }
}

struct VoiceView: View {
    @ObservedObject var model: VoiceModel
    @State private var destination = "Copy"
    @State private var read = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("Nero Voice", systemImage: "waveform").font(.title2.bold()); Spacer(); Text(model.session.phase == .listening ? "● Recording" : "On-device speech").font(.caption).foregroundStyle(model.session.phase == .listening ? .red : .secondary); Button { model.settings = true; model.refreshDevices() } label: { Image(systemName: "gearshape") } }
            HStack(spacing: 12) {
                Image(systemName: "cursorarrow.and.square.on.square.dashed").font(.title2).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.dictateAtCursor ? "Dictate where you work" : "Record, then review").font(.headline)
                    Text(model.shortcut == "Off" ? "Choose a shortcut in settings to dictate into another app." : "\(model.shortcut) · \(model.shortcutStyle.rawValue) · \(model.dictateAtCursor ? "insert at cursor" : "review in Nero Voice")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.dictateAtCursor && !model.accessibilityAllowed {
                    Button("Set up insertion") { model.settings = true }
                }
            }.padding(12).background(.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            TextEditor(text: Binding(get: { model.session.transcript }, set: model.edit)).font(.body).scrollContentBackground(.hidden).padding(10).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12)).disabled(model.busy)
            if !model.reply.isEmpty { ScrollView { Text(model.reply).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 90) }
            HStack {
                Button(model.session.recording ? "Stop recording" : "Record", systemImage: model.session.recording ? "stop.fill" : "mic.fill") { if model.session.recording { model.stopRecording() } else { model.record() } }.disabled(model.waiting || model.preparingAssets || model.session.phase == .finishing)
                Button("Cancel") { model.cancel() }.disabled(!model.busy && !model.speaking)
                Button("Insert draft…") { model.insertDraft() }.disabled(model.busy || model.session.transcript.isEmpty).help("Five seconds to click the destination text field")
                Spacer()
                Picker("Use text", selection: $destination) { Text("Copy").tag("Copy"); if model.assistant != nil { Text("Ask").tag("Ask") } }.labelsHidden().frame(width: 100)
                Toggle("Read reply", isOn: $read).toggleStyle(.checkbox)
                Button(destination == "Ask" ? "Ask assistant" : "Copy text") {
                    do { try model.submit(["text": .string(model.session.transcript), "destination": .string(destination), "read_reply": .boolean(read)]) } catch { model.status = error.localizedDescription }
                }.disabled(model.busy || model.session.transcript.isEmpty)
            }
            HStack { Button("Original words") { model.restore() }.disabled(model.busy || model.session.raw.isEmpty); Button("Apply spellings") { model.applyDictionary() }.disabled(model.busy || model.dictionary.isEmpty); Spacer(); Button(model.speaking ? "Stop speaking" : "Read reply") { if model.speaking { model.stopSpeaking() } else { model.speak() } }.disabled(model.busy || model.reply.isEmpty) }.font(.caption)
        }.padding(20).frame(width: 720, height: 480).preferredColorScheme(.dark).tint(.mint)
            .onExitCommand { model.cancel() }
            .sheet(isPresented: $model.settings) { VoiceSettings(model: model) }
    }
}
struct VoiceSettings: View {
    @ObservedObject var model: VoiceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Voice settings").font(.title2.bold()); Spacer(); Button("Done") { model.settings = false } }
            ScrollView { VStack(alignment: .leading, spacing: 14) {
                Picker("Microphone", selection: $model.microphone) { Text("System default").tag(""); ForEach(model.microphones) { Text($0.displayName).tag($0.id) } }
                Picker("Language", selection: $model.locale) { ForEach(Array(Set(model.languages + [model.locale])).sorted(), id: \.self) { Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0) } }
                HStack { Text("Apple Speech · on this Mac"); Spacer(); Button("Prepare language") { model.prepareAssets() }.disabled(model.busy) }
                Text("Language assets are managed by macOS. Prepare may download the selected language; audio is transcribed locally.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Shortcut", selection: $model.shortcut) { ForEach(PushToTalk.choices, id: \.self) { Text($0).tag($0) } }
                Picker("Shortcut behavior", selection: $model.shortcutStyle) { ForEach(DictationShortcutStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Toggle("Insert shortcut dictation at the original cursor", isOn: $model.dictateAtCursor)
                Text("Record in this window always keeps a draft for review. Shortcut dictation pastes locally after you finish; it never presses Send. If the destination changes, your words stay here.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Label(model.accessibilityAllowed ? "Text insertion allowed" : "Accessibility needed for insertion", systemImage: model.accessibilityAllowed ? "checkmark.circle" : "cursorarrow")
                    Spacer()
                    Button("Allow text insertion…") { model.requestInsertionPermission() }
                }
                Text("macOS Accessibility lets Nero Voice check the focused text field and paste your dictation. Audio and field context stay on this Mac.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Recording cue", isOn: $model.sounds)
                Picker("Text assistant", selection: $model.selectedKey) {
                    Text("None · dictation only").tag("")
                    ForEach(model.catalog, id: \.address.key) { Text($0.action!.title).tag($0.address.key) }
                    if !model.selectedKey.isEmpty && !model.catalog.contains(where: { $0.address.key == model.selectedKey }) { Text("Saved assistant unavailable").tag(model.selectedKey) }
                }
                Text("Allow Nero Voice to use an assistant in NeroNook Settings → Modules → Actions and connections. Only text you choose to Ask is sent.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Spoken reply", selection: $model.voiceID) { Text("Language default").tag(""); ForEach(AVSpeechSynthesisVoice.speechVoices(), id: \.identifier) { Text("\($0.name) · \($0.language)").tag($0.identifier) } }
                Text("Personal spellings · one per line")
                TextEditor(text: $model.dictionary).frame(height: 64)
                Text("Use Apply spellings to preview canonical capitalization. Original words remain available.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading).disabled(model.busy) }.frame(height: 490)
            Text(model.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.preparingAssets { Button("Cancel preparation") { model.cancel() } }
        }.padding(24).frame(width: 640, height: 620).fixedSize().preferredColorScheme(.dark)
    }
}
@main struct NeroVoiceApp: App {
    @StateObject private var plugin: VoicePlugin
    init() { _plugin = StateObject(wrappedValue: VoicePlugin()) }
    var body: some Scene { WindowGroup { VoiceRootView(plugin: plugin).onAppear { if plugin.hosted { NSApp.windows.first { $0.canBecomeKey }?.orderOut(nil) } } }.windowResizability(.contentSize) }
}
