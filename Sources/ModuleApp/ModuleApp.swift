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
    let conversation = ConversationProvider()
    private var conversationStreaming = false
    @Published var page = "Dictate"
    private var customViews = false
    private var lastCaption: PluginTransientCaption?
    private var lastCaptionAt = Date.distantPast
    private var lastMeterSnapshotAt = Date.distantPast
    let id = "cafe.nero.plugin.voice"
    let hosted = CommandLine.arguments.contains("--neronook-plugin")
    let test = CommandLine.arguments.contains("--protocol-test")
    private let windows = PluginWindows()
    private let channel = PluginApplicationChannel()
    private lazy var output = VoiceOutput(pluginID: id, channel: channel, test: test)
    private var session: UUID?
    private var shuttingDown = false
    private var lines = PluginLines()
    private var accumulator = PluginCatalogAccumulator()
    private var meetingReads: [UUID: Task<Void, Never>] = [:]
    private var spokenRequest: UUID?
    private var speechMeter:Task<Void,Never>?
    private var seen = Set<UUID>()
    private var timer: Timer?
    private var qwenCloseObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?
    init() {
        if Bundle.main.object(forInfoDictionaryKey: "NeroLiveFixtureAudio") != nil {
            page = "Meetings"
        }
        model.speechPhaseChanged = { [weak self] phase, error in
            guard let self, let id = self.spokenRequest else { return }
            let update: PluginRunUpdate
            if let error { update = .init(.failed, message: String(error.prefix(280))); self.spokenRequest = nil }
            else if phase == .finished { update = .init(.succeeded, message: "Reading finished", values: ["spoken": .boolean(true)]); self.spokenRequest = nil }
            else if phase == .idle { update = .init(.cancelled, message: "Reading stopped"); self.spokenRequest = nil }
            else { update = .init(.running, message: phase == .preparing ? "Preparing local speech" : "Reading aloud") }
            self.bus(.init(.update, requestID: id, update: update))
            if update.phase.terminal {self.speechMeter?.cancel();self.speechMeter=nil}
        }
        conversation.send = { [weak self] in self?.bus($0) }
        conversation.changed = { [weak self] in guard let self else{return};self.model.status=self.conversation.status;self.publish() }
        model.changed = { [weak self] in self?.publish() }
        model.captionChanged = { [weak self] in
            guard let self else { return }
            self.publishCaption()
            // Bound meter-only snapshots; the renderer retains its editor DOM.
            if self.customViews, self.model.session.recording,
               Date().timeIntervalSince(self.lastMeterSnapshotAt) >= 0.2 {
                self.lastMeterSnapshotAt = Date(); self.publish()
            }
        }
        meetings.changed = { [weak self] in self?.publish() }
        meetings.canStart = { [weak self] in guard let self else { return false }; return !self.model.rewrite.active && !self.conversation.active && !self.model.session.recording && !self.model.waiting && !self.model.preparingAssets && !self.model.inserting && !self.model.polishing && !self.model.speaking }
        meetings.microphone = { [weak self] in self?.model.microphone ?? "" }
        meetings.locale = { [weak self] in self?.model.locale ?? "en-US" }
        if !test { meetings.startCallDetection() }
        model.meetingActive = { [weak self] in
            guard let self else { return false }
            return self.conversation.active || self.meetings.occupied || self.meetings.playing
        }
        model.stopMeetingPlayback = { [weak self] in self?.meetings.stopPlayback() }
        qwenCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window.title == "Qwen Voice Studio" else { return }; Task { @MainActor in self?.model.cancelReference() }
        }
        model.showQwenStudio = { [weak self] in self?.showQwenWindow() }
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
            meetings.invokeCalendar = { [weak self] request, address, values in self?.bus(.init(.invoke, requestID: request, address: address, values: values)) }
            meetings.cancelCalendarInvocation = { [weak self] request in self?.bus(.init(.cancel, requestID: request)) }
            meetings.invokeQuestion = { [weak self] request, address, values in self?.bus(.init(.invoke, requestID: request, address: address, values: values)) }
            meetings.cancelQuestionInvocation = { [weak self] request in self?.bus(.init(.cancel, requestID: request)) }
            model.cancelInvocation = { [weak self] request in self?.bus(.init(.cancel, requestID: request)) }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.model.refreshSpeechState(); self?.meetings.tick(); self?.publish() } }; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        for task in meetingReads.values { task.cancel() }; meetingReads = [:]
        session = nil
        model.changed = nil; model.captionChanged = nil
        meetings.changed = nil
        if let qwenCloseObserver { NotificationCenter.default.removeObserver(qwenCloseObserver) }; qwenCloseObserver = nil
        windows.closeAll()
        output.stop()
        conversation.stop(); meetings.shutdown()
        model.shutdown()
    }
    func showQwenWindow() { model.qwenProfiles = (try? QwenVoiceLibrary().list()) ?? []; windows.show("qwen", title: "Qwen Voice Studio", size: CGSize(width: 850, height: 720)) { QwenStudio(model: model) } }
    func showWindow() { windows.show("voice", title: "Nero Voice", size: CGSize(width: 820, height: 550)) { VoiceRootView(plugin: self) } }
    func showMicrophoneWindow() {
        model.refreshDevices()
        windows.show("microphone", title: "Microphone & Voice · Nero Voice", size: CGSize(width: 500, height: 440)) {
            MicrophoneChoiceView(model: self.model, settings: { self.showWindow(); self.model.settings = true })
        }
    }
    private func receive(_ m: PluginMessage) {
        guard m.pluginID == id else { shutdown(); exit(1) }
        if session == nil {
            guard m.type == "hello", m.features?.contains("forms-v1") == true else { shutdown(); exit(1) }
            conversationStreaming = m.features?.contains("action-stream-v1") == true && m.features?.contains("actions-long-running-v1") == true
            customViews = m.features?.contains("custom-views-v1") == true
            model.hostCaptionAvailable = m.features?.contains("transient-caption-v1") == true
            model.enhancedCaptionAvailable = m.features?.contains("transient-caption-v2") == true
            session = m.session; output.begin(m.session); PluginAppearanceStore.shared.beginSession(pluginID:id,session:m.session)
            emit("ready", features: ["appearance-v1", "panels-v1", "dashboard-v1", "forms-v1", "actions-v1"] + (conversationStreaming ? ["action-stream-v1", "actions-long-running-v1"] : []) + (customViews ? ["custom-views-v1"] : []) + (model.hostCaptionAvailable ? ["transient-caption-v1"] : []) + (model.enhancedCaptionAvailable ? ["transient-caption-v2"] : []))
            bus(.init(.register, registration: .init(actions: [VoiceContract.submit, PluginSpeechContract.speak, MeetingReadContract.search, MeetingReadContract.read] + (conversationStreaming ? [PluginSpeechConversation.action] : [])))); bus(.init(.discover)); publish(); return
        }
        guard m.session == session else { shutdown(); exit(1) }
        if m.type == "appearance" { _ = PluginAppearanceStore.shared.receive(m); return }
        if m.type == "viewEvent", let event = m.viewEvent {
            do { if event.panelID == "voice" { try model.handleVoice(event) } else { try meetings.handle(event) } } catch { model.status = error.localizedDescription }; publish(); return
        }
        if m.type == "action", let action = m.action {
            if action == "configure" {
                model.refreshDevices()
                showWindow()
                // The hosted window starts hidden. Present its sheet only after
                // AppKit has brought that window forward.
                DispatchQueue.main.async { [weak self] in self?.model.settings = true }
            }
            if action == "record", !test { if model.session.recording { model.stopRecording() } else { model.record() } }
            if action == "cancel" { conversation.stop(); model.cancel(); meetings.process("cancel"); if meetings.active { meetings.finish(paused: false) } }
            if action == "open_meetings" { showWindow() }
            if action == "restore" { model.restore() }
            if action == "dictionary" { model.applyDictionary() }
            if action == "speak", !test { if model.speaking { model.stopSpeaking() } else { model.speak() } }
            if action == "clear" { model.clear() }
        }
        if let bus = m.bus {
            switch bus.operation {
            case .catalog: if (try? accumulator.receive(bus)) == true { model.updateCatalog(accumulator.entries.filter { $0.address.plugin != id }); meetings.questionCatalog(accumulator.entries.filter { $0.address.plugin != id }); meetings.calendarCatalog(accumulator.entries.filter { $0.address.plugin != id }) }
            case .stream:
                do { try conversation.receive(bus) } catch { conversation.stop(error.localizedDescription, failed: true) }
            case .execute:
                guard !seen.contains(bus.requestID), seen.count < 4096 else { self.bus(.init(.update, requestID: bus.requestID, update: .init(.failed, message: "Duplicate request or session limit reached"))); return }
                seen.insert(bus.requestID)
                do {
                    if bus.address == PluginActionAddress(id,PluginSpeechConversation.action.id),conversationStreaming,let values=bus.values {
                        if values["settings"] == .boolean(true) {
                            conversation.stop();showMicrophoneWindow()
                            self.bus(.init(.update,requestID:bus.requestID,update:.init(.succeeded,message:"Voice settings opened")));return
                        }
                        model.stopReaction()
                        try conversation.start(bus.requestID,values:values,preferences:model,available:!model.busy && !model.speaking && !meetings.occupied)
                        return
                    }
                    if let address = bus.address, address.plugin == id, [MeetingReadContract.search.id, MeetingReadContract.read.id].contains(address.name), let values = bus.values, !test {
                        guard meetingReads.count < 4 else { throw VoiceProblem.message("Too many meeting reads") }
                        meetingReads[bus.requestID] = Task { [weak self] in
                            guard let self else { return }; defer { self.meetingReads[bus.requestID] = nil }
                            do { let values = try await self.meetings.readTool(address.name, values: values); try Task.checkCancellation(); self.bus(.init(.update, requestID: bus.requestID, update: .init(.succeeded, message: "Saved local meeting text", values: values))) }
                            catch { self.bus(.init(.update, requestID: bus.requestID, update: .init(error is CancellationError ? .cancelled : .failed, message: String(error.localizedDescription.prefix(280))))) }
                        }; return
                    }
                    if bus.address == PluginActionAddress(id, PluginSpeechContract.speak.id), let values = bus.values {
                        guard !conversation.active else { throw VoiceProblem.message("Finish the voice conversation before reading other text.") }
                        let text = try PluginSpeechContract.validate(values)
                        // Attach ownership after the renderer's synchronous stop/start,
                        // so its previous session cannot finish this new request.
                        try model.speakShared(text); spokenRequest = bus.requestID
                        if model.avatarPlayback != nil {
                            let id=bus.requestID
                            speechMeter?.cancel()
                            speechMeter=Task{[weak self] in while !Task.isCancelled {
                                try? await Task.sleep(for:.milliseconds(100))
                                guard !Task.isCancelled,let self,self.spokenRequest==id else{return}
                                self.bus(.init(.update,requestID:id,update:.init(.running,message:"Character reaction",speech:self.model.speechPresentation)))
                            }}
                        }
                        self.bus(.init(.update, requestID: bus.requestID, update: .init(.running, message: "Preparing local speech")))
                        return
                    }
                    guard !test, bus.address == PluginActionAddress(id, VoiceContract.submit.id), let values = bus.values else { throw VoiceProblem.message("Invalid transcript request") }
                    try model.submit(values)
                    self.bus(.init(.update, requestID: bus.requestID, update: .init(.succeeded, message: "Reviewed transcript accepted")))
                } catch { self.bus(.init(.update, requestID: bus.requestID, update: .init(.failed, message: String(error.localizedDescription.prefix(450))))) }
            case .cancel:
                conversation.cancel(bus.requestID)
                meetingReads[bus.requestID]?.cancel()
                if spokenRequest == bus.requestID { model.stopSpeaking() }
            case .update: if let update = bus.update { model.receive(bus.requestID, update: update); meetings.receiveQuestion(bus.requestID, update: update); meetings.receiveCalendar(bus.requestID, update: update) }
            case .failure: conversation.cancel(bus.requestID); model.receive(bus.requestID, update: .init(.failed, message: bus.error ?? "Assistant unavailable")); meetings.receiveQuestion(bus.requestID, update: .init(.failed, message: bus.error ?? "Assistant unavailable")); meetings.receiveCalendar(bus.requestID, update: .init(.failed, message: bus.error ?? "Calendar unavailable"))
            default: break
            }
        }
        publish()
    }
    private func publish() {
        guard !shuttingDown, session != nil else { return }
        output.noteMainProgress()
        var sections: [PluginSection] = []
        if model.session.recording {
            sections = [.init(model.session.phase == .listening ? "Listening on your Mac" : "Preparing / finishing", model.session.transcript.isEmpty ? "Your words appear here. Nothing is sent automatically." : String(model.session.transcript.prefix(1200)))]
        } else if !model.reply.isEmpty { sections = [.init("Reply", String(model.reply.prefix(1200)))] }
        else { sections = [.init("Dictate into the active app", "Use \(model.shortcutName) to dictate at the cursor. Record here keeps a reviewable draft.")] }
        let form = PluginForm("transcript", title: "Review transcript", revision: model.revision.uuidString, action: VoiceContract.submit, inputs: [
            .init("text", label: "Your words", style: .text, value: .string(model.session.transcript)),
            .init("destination", label: "Use text", style: .choice, value: .string("Copy"), choices: ["Copy"]),
            .init("read_reply", label: "Read reply aloud", style: .toggle, value: .boolean(false))
        ], enabled: !model.busy)
        let actions: [PluginAction] = [
            .init("record", model.session.recording ? "Stop dictation" : "Record dictation", enabled: !meetings.occupied && !model.waiting && !model.preparingAssets && model.session.phase != .finishing, symbol: model.session.recording ? "stop.fill" : "mic.fill"),
            .init("cancel", "Cancel", enabled: model.busy || model.speaking, symbol: "xmark"),
            .init("clear", "Clear", enabled: !model.busy, symbol: "trash")
        ]
        let status = meetings.occupied ? meetings.status : model.status
        // Custom panels already expose their own recording and stop controls.
        // Keep the host action row only for the older declarative fallback.
        var snapshot = PluginSnapshot(title: "Nero Voice", status: String(status.prefix(200)), activity: String(status.prefix(100)), actions: customViews ? [] : actions, badge: meetings.active ? "Meeting" : model.session.phase == .listening ? "Recording" : "On-device", panels: [
            customViews ? .init("voice", "Dictate", customView: model.voiceDefinition) : .init("voice", "Dictate", sections: sections, forms: model.session.recording ? nil : [form]),
            customViews ? .init("meetings", "Meetings", customView: meetings.definition) : .init("meetings", "Meetings", sections: [.init("Meeting recordings", "Open Nero Voice for meeting recording, bookmarks and playback.")])
        ])
        snapshot.avatarInteractionBusy = model.busy || (model.speaking && model.avatarPlayback == nil) || conversation.active || meetings.occupied || meetings.playing
        do { try snapshot.validate(); emit("snapshot", snapshot: snapshot) }
        catch { emit("snapshot", snapshot: PluginSnapshot(title: "Nero Voice", status: "Voice view unavailable. Open settings or stop the current activity.", actions: [.init("cancel", "Stop activity", enabled: true, symbol: "stop.fill")], sections: [.init("Display issue", String(error.localizedDescription.prefix(200)))])) }
        publishCaption()
    }
    private func publishCaption() {
        guard !shuttingDown, session != nil else { return }
        if model.hostCaptionAvailable {
            let current = model.transientCaption
            if current != lastCaption || (current?.phase == .active && Date().timeIntervalSince(lastCaptionAt) >= 2) {
                emit("caption", caption: current ?? PluginTransientCaption(.dismiss))
                lastCaption = current; lastCaptionAt = Date()
            }
        }
    }
    private func bus(_ value: PluginBusMessage) { emit("bus", bus: value) }
    private func emit(_ type: String, features: [String]? = nil, snapshot: PluginSnapshot? = nil, bus: PluginBusMessage? = nil, caption: PluginTransientCaption? = nil) {
        guard !shuttingDown, session != nil else { return }
        do { try output.emit(type, features: features, snapshot: snapshot, bus: bus, caption: caption) }
        catch { shutdown(); exit(1) }
    }
}

struct VoiceView: View {
    @ObservedObject var model: VoiceModel
    var body: some View {
        PluginWebSurface(root: Bundle.main.resourceURL!.appendingPathComponent("Views"), panelID: "voice", definition: model.voiceDefinition) { event in
            do { try model.handleVoice(event) } catch { model.status = error.localizedDescription }
        }.frame(width: 820, height: 510).onExitCommand { model.cancel() }
    }
}
struct MicrophoneChoiceView: View {
    @ObservedObject var model: VoiceModel
    var settings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Microphone & voice").font(.title2.weight(.medium))
            Text("Shared by dictation, Nero and Ember.").font(.subheadline).pluginSecondaryText()
            Picker("Microphone", selection: $model.microphone) {
                Text("System default").tag("")
                ForEach(model.microphones) { Text($0.displayName).tag($0.id) }
            }.disabled(model.busy)
            Picker("Speech to text", selection: Binding(get: { model.dictationASR }, set: model.chooseASR)) {
                ForEach(VoiceASRProvider.allCases, id: \.self) { Text($0.title).tag($0) }
            }.disabled(model.busy)
            InterruptionSensitivityView(value: $model.interruptionSensitivity)
            HStack { Button("Refresh devices") { model.refreshDevices() }; Spacer(); Button("All voice settings…", action: settings) }
            Text("Changing input never starts recording. Start Talk again when you’re ready.").font(.caption).pluginSecondaryText()
        }.padding(26).frame(width: 500, height: 440).pluginThemed()
    }
}
struct VoiceSettings: View {
    @ObservedObject var model: VoiceModel
    var body: some View {
        PluginSettingsPage("Nero Voice", subtitle: "Choose your microphone, dictation shortcut and speaking voice.", symbol: "waveform", width: 720, height: 690, done: { model.settings=false }) {
                inputSettings.disabled(model.busy)
                PluginSettingsSection("Conversation interruptions") { InterruptionSensitivityView(value: $model.interruptionSensitivity) }
                dictationSettings.disabled(model.busy)
                PluginSettingsSection("Selected-text editing") {
                    ShortcutRecorder(model: model, rewrite: true)
                    Text("Highlight text in an editable field, then use this shortcut. Review a local rewrite before Replace; Cancel changes nothing. Exact Undo is available while the text and cursor are unchanged. Unsupported fields keep a copyable draft. No audio or cloud provider is used.").font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
                }.disabled(model.busy)
                outputSettings.disabled(model.busy)
                PluginAdvancedSection(detail: "Conversation timing and model preparation affect Talk. Hold-to-dictate still ends when you release the shortcut.") {
                HStack {
                    Button("Prepare conversation") { model.prepareConversation() }.disabled(model.busy || model.speaking || !model.selectedModelReady || model.preloader.ready)
                    if model.preloader.ready || model.preloader.preparing { Button("Release prepared model") { model.releasePreparedSpeech() } }
                }
                Text(model.preloader.status).font(.caption).pluginSecondaryText()
                Picker("Conversation pause", selection: $model.conversationPace) {
                    ForEach(ConversationPace.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Talk only. Choose More pause time if you pause between phrases. Shortcut dictation still ends when you release the key.").font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
                }.disabled(model.busy)
        } footer: {
            Text(model.status).font(.caption).pluginSecondaryText().fixedSize(horizontal:false,vertical:true)
            if model.preparingAssets { Button("Cancel preparation") { model.cancel() } }
        }
    }
    private var inputSettings: some View {
            PluginSettingsSection("Microphone & recognition") { VStack(alignment:.leading,spacing:14) {
                Picker("Microphone", selection: $model.microphone) { Text("System default").tag(""); ForEach(model.microphones) { Text($0.displayName).tag($0.id) } }
                Picker("Language", selection: $model.locale) { ForEach(Array(Set(model.languages + [model.locale])).sorted(), id: \.self) { Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0) } }
                Picker("Dictation model", selection: Binding(get: { model.dictationASR }, set: model.chooseASR)) {
                    ForEach(VoiceASRProvider.allCases, id: \.self) { provider in Text(provider.title).tag(provider) }
                }
                if model.dictationASR == .apple {
                    HStack { Text("Apple Speech · on this Mac"); Spacer(); Button("Prepare language") { model.prepareAssets() }.disabled(model.busy) }
                    Text("Language assets are managed by macOS. Prepare may download the selected language; audio is transcribed locally.").font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Text(model.selectedModelReady ? "Model ready · local MLX" : "Selected model needs a 756 MB download")
                        Spacer()
                        Button(model.selectedModelReady ? "Verify model" : "Download model") { model.prepareLocalModel() }.disabled(model.busy)
                    }
                    Text("Nemotron and Apple Speech show words while you speak. Parakeet transcribes after release. All available recognizers also work in Meetings. Only the selected model is loaded.").font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth:.infinity,alignment:.leading) }
    }
    private var dictationSettings: some View {
            PluginSettingsSection("Hold to dictate") { VStack(alignment:.leading,spacing:14) {
                ShortcutRecorder(model: model)
                Picker("Live words", selection: $model.captionPlacement) {
                    Text("In the Nook").tag(PluginTransientCaption.Placement.nook)
                    Text("Bottom of screen · captions").tag(PluginTransientCaption.Placement.bottom)
                }.disabled(model.busy)
                Text("Fn is the default on a new setup. Existing shortcuts are kept. Fn may also be assigned to Emoji or Dictation in macOS Keyboard settings; choose Do Nothing there if macOS still responds to it.").font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
                Picker("Shortcut behavior", selection: $model.shortcutStyle) { ForEach(DictationShortcutStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("Inserted text", selection: $model.tone) { ForEach(DictationTone.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Text("Clean removes stumbles and corrects clear grammar. Formal also changes tone. Both use Apple's on-device model when available; Literal keeps the recognized words.")
                    .font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
                Text("The shortcut works while another app is active, even if Voice settings are open. It pastes into the original app when you finish and never presses Send.").font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
                HStack {
                    Label(model.accessibilityAllowed ? "Text insertion allowed" : "Accessibility needed for insertion", systemImage: model.accessibilityAllowed ? "checkmark.circle" : "cursorarrow")
                    Spacer()
                    Button("Allow text insertion…") { model.requestInsertionPermission() }
                }
                Text("macOS Accessibility lets Nero Voice paste your dictation into the active app. Audio stays on this Mac.").font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
                Toggle("Recording cue", isOn: $model.sounds)
            }.frame(maxWidth:.infinity,alignment:.leading) }
    }
    private var outputSettings: some View {
            PluginSettingsSection("Speaking voice") { VStack(alignment:.leading,spacing:14) {
                Picker("Text to speech", selection: Binding(get: { model.speechBackend }, set: model.chooseSpeechBackend)) {
                    ForEach(SpeechBackend.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.speechBackend == .qwen {
                    Picker("Qwen voice", selection: Binding(get: { model.qwenSpeaker }, set: model.chooseQwenSpeaker)) {
                        ForEach(QwenSpeaker.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Button("Qwen Voice Studio…") { model.settings = false; model.showQwenStudio?() }
                    HStack {
                        Button(model.qwenReady ? "Prepare Qwen" : "Download Qwen · 3.08 GB") { model.prepareQwen() }
                        Button("Release speaking model") { model.releaseSpeakingModel() }.disabled(model.speaking)
                    }
                    Text("Expressive speech on this Mac, with more memory and GPU use than Apple. Preparation never records. The ready model releases after 60 idle seconds.").font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
                } else {
                Picker("Speaking voice", selection: Binding(get: { model.voiceID }, set: model.chooseSpeechVoice)) {
                    Text("Automatic · best available for this language").tag("")
                    Text("Apple · American English · Voice 2 (Ember)").tag(AppleSpeechOutput.voice2Identifier)
                    ForEach(model.speechVoices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(voice.language)\(voice.quality == .premium ? " · Premium" : voice.quality == .enhanced ? " · Enhanced" : "")").tag(voice.identifier)
                    }
                    if !model.voiceID.isEmpty && model.voiceID != AppleSpeechOutput.voice2Identifier && !model.speechVoices.contains(where: { $0.identifier == model.voiceID }) {
                        Text("Saved voice · unavailable for this language").tag(model.voiceID)
                    }
                }
                }
                Picker("Delivery", selection: $model.speechDelivery) {
                    ForEach(SpeechDelivery.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                HStack {
                    Text("\(model.speechVoiceName) · on this Mac").font(.caption).pluginSecondaryText()
                    Spacer()
                    Button(model.speaking ? "Stop reading" : "Preview voice") {
                        if model.speaking { model.stopSpeaking() } else { model.previewSpeech() }
                    }
                }
                Text("Uses voices available to this app. Read draft and Preview never paste or send text. Apple delivery changes pitch and pace; Qwen delivery is a style instruction.").font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth:.infinity,alignment:.leading) }
    }
}
@main struct NeroVoiceApp: App {
    @StateObject private var plugin: VoicePlugin
    init() { _plugin = StateObject(wrappedValue: VoicePlugin()) }
    var body: some Scene { WindowGroup(plugin.hosted ? "Nero Voice Launcher" : "Nero Voice") { VoiceRootView(plugin: plugin).pluginThemed().onAppear { if plugin.hosted { NSApp.windows.first { $0.title == "Nero Voice Launcher" }?.orderOut(nil) } } }.windowResizability(.contentSize) }
}
