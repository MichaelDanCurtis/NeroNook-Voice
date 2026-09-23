import AppKit
import AVFoundation
import Speech
import Combine
import ModuleCore
import VoiceAudio
import NookPluginSDK

@MainActor final class VoiceModel: ObservableObject {
    @Published var session = VoiceSession()
    @Published var status = "Record locally, then review your words"
    @Published var reply = ""
    @Published var settings = false
    @Published var revision = UUID()
    @Published var microphones = MicrophoneDeviceService.inputDevices()
    @Published var languages: [String] = ["en-US"]
    @Published var catalog: [PluginCatalogEntry] = []
    @Published var microphone = UserDefaults.standard.string(forKey: "microphone") ?? "" { didSet { UserDefaults.standard.set(microphone, forKey: "microphone") } }
    @Published var locale = UserDefaults.standard.string(forKey: "locale") ?? "en-US" { didSet { UserDefaults.standard.set(locale, forKey: "locale") } }
    @Published var dictionary = UserDefaults.standard.string(forKey: "dictionary") ?? "" { didSet { UserDefaults.standard.set(String(dictionary.prefix(4096)), forKey: "dictionary") } }
    @Published var shortcut = UserDefaults.standard.string(forKey: "shortcut") ?? "Off" { didSet { UserDefaults.standard.set(shortcut, forKey: "shortcut"); configureHotkey() } }
    @Published var sounds = UserDefaults.standard.bool(forKey: "sounds") { didSet { UserDefaults.standard.set(sounds, forKey: "sounds") } }
    @Published var voiceID = UserDefaults.standard.string(forKey: "voiceID") ?? "" { didSet { UserDefaults.standard.set(voiceID, forKey: "voiceID") } }
    @Published var selectedKey = UserDefaults.standard.string(forKey: "assistant") ?? "" {
        didSet {
            pinnedAction = catalog.first { $0.address.key == selectedKey }?.action
            UserDefaults.standard.set(selectedKey, forKey: "assistant")
            UserDefaults.standard.set(try? JSONEncoder().encode(pinnedAction), forKey: "assistantDefinition")
        }
    }
    @Published var waiting = false
    @Published var speaking = false
    @Published var preparingAssets = false
    var changed: (() -> Void)?
    var invoke: ((UUID, PluginActionAddress, [String: PluginValue]) -> Void)?
    var cancelInvocation: ((UUID) -> Void)?
    var reveal: (() -> Void)?
    private var pinnedAction: PluginRegisteredAction? = UserDefaults.standard.data(forKey: "assistantDefinition").flatMap { try? JSONDecoder().decode(PluginRegisteredAction.self, from: $0) }
    private var pipeline: SpeechPipeline?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var assetTask: Task<Void, Never>?
    private var assetGeneration = UUID()
    private let speaker = AVSpeechSynthesizer()
    private let hotkey = PushToTalk()
    private var observations = Set<AnyCancellable>()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var outgoing: UUID?
    private var outgoingEntry: PluginCatalogEntry?
    private var readReply = false
    private var held = false
    var busy: Bool { session.recording || waiting || preparingAssets }
    var assistant: PluginCatalogEntry? { catalog.first { $0.address.key == selectedKey && $0.action == pinnedAction && $0.action.map(VoiceContract.accepts) == true } }
    init() {
        objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.changed?() } }.store(in: &observations)
        hotkey.pressed = { [weak self] in guard let self, !self.busy else { return }; self.held = true; self.record(); self.reveal?() }
        hotkey.released = { [weak self] in guard let self, self.held else { return }; self.held = false; self.stopRecording() }
        if !CommandLine.arguments.contains("--protocol-test") {
            configureHotkey()
            Task { [weak self] in self?.languages = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted() }
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cancel(); self?.status = "Stopped for sleep or screen lock" } })
            }
        }
    }
    func configureHotkey() { guard !CommandLine.arguments.contains("--protocol-test") else { return }; do { try hotkey.configure(shortcut) } catch { status = error.localizedDescription } }
    func refreshDevices() { microphones = MicrophoneDeviceService.inputDevices() }
    func prepareAssets() {
        guard !busy else { return }; preparingAssets = true; status = "Preparing Apple Speech language…"
        let generation = UUID(); assetGeneration = generation; let language = locale
        assetTask = Task { [self] in
            do { _ = try await SpeechPipeline.prepare(localeIdentifier: language, install: true); try Task.checkCancellation(); guard generation == assetGeneration else { return }; status = "Language ready · audio stays on this Mac" }
            catch { if !Task.isCancelled, generation == assetGeneration { status = error.localizedDescription } }
            if generation == assetGeneration { preparingAssets = false; assetTask = nil }
        }
    }
    func record() {
        guard !busy else { return }; stopSpeaking(); reply = ""; let token = session.begin(); revision = UUID(); status = "Preparing microphone…"
        deadline?.cancel(); deadline = Task { [weak self] in try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled, self?.session.token == token, self?.session.phase == .preparing else { return }; self?.cancel(); self?.status = "Microphone preparation timed out. Try Record again." }
        work = Task { [self] in
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation(); guard session.token == token else { return }
                guard allowed else { throw VoiceProblem.message("Allow Nero Voice in System Settings → Privacy & Security → Microphone.") }
                let pipeline = SpeechPipeline(); self.pipeline = pipeline
                try await pipeline.start(microphone: microphone.isEmpty ? nil : microphone, locale: locale, partial: { [weak self] text in
                    guard let self, self.session.token == token else { return }
                    do { try self.session.partial(text, token: token) } catch { self.fail(error.localizedDescription, token: token) }
                }, failure: { [weak self] text in self?.fail(text, token: token) })
                try Task.checkCancellation(); guard session.ready(token) else { pipeline.cancel(); return }
                status = "Listening · release shortcut or press Stop"
                if sounds { NSSound(named: "Tink")?.play() }
                deadline?.cancel(); deadline = Task { [weak self] in try? await Task.sleep(for: .seconds(60)); guard !Task.isCancelled, self?.session.token == token else { return }; self?.stopRecording() }
            } catch { if session.token == token { fail(error.localizedDescription, token: token) } }
        }
    }
    func stopRecording() {
        if session.phase == .preparing { cancel(); status = "Stopped before recording was ready"; return }
        let token = session.token
        guard session.finishing(token), let pipeline else { return }
        deadline?.cancel(); status = "Finishing your last words…"
        deadline = Task { [weak self] in try? await Task.sleep(for: .seconds(12)); guard !Task.isCancelled, self?.session.token == token else { return }; self?.cancel(); self?.status = "Speech finalization timed out. Review the partial text before using it." }
        work = Task { [self] in
            do {
                let text = try await pipeline.finish()
                try Task.checkCancellation(); guard session.token == token else { return }
                try session.finish(text, token: token)
                self.pipeline = nil; deadline?.cancel(); revision = UUID(); status = "Review your transcript · nothing sent"
            } catch { if session.token == token { fail(error.localizedDescription, token: token) } }
        }
    }
    private func fail(_ message: String, token: UUID) { guard session.token == token else { return }; cancel(); status = message }
    func cancel() {
        held = false; work?.cancel(); work = nil; deadline?.cancel(); deadline = nil
        assetGeneration = UUID(); assetTask?.cancel(); assetTask = nil; preparingAssets = false
        pipeline?.cancel(); pipeline = nil; session.cancel(); revision = UUID()
        if let outgoing { cancelInvocation?(outgoing) }; outgoing = nil; outgoingEntry = nil; waiting = false
        stopSpeaking(); status = "Stopped · review any partial text"
    }
    func edit(_ text: String) { guard !busy else { return }; do { try session.edit(text); revision = UUID() } catch { status = error.localizedDescription } }
    func restore() { guard !busy else { return }; session.restore(); revision = UUID(); status = "Original transcript restored" }
    func applyDictionary() {
        guard !busy else { return }
        do { try session.edit(VoiceDictionary.apply(session.transcript, terms: dictionary)); revision = UUID(); status = "Spellings applied · review before use" } catch { status = error.localizedDescription }
    }
    func clear() { guard !busy else { return }; stopSpeaking(); session.clear(); reply = ""; revision = UUID(); status = "Ready to record" }
    func submit(_ values: [String: PluginValue]) throws {
        guard !busy else { throw VoiceProblem.message("Stop the current recording or request first.") }
        let (text, ask, read) = try VoiceContract.validate(values)
        if ask {
            guard let assistant, let invoke else { throw VoiceProblem.message("Allow a text assistant in Nook Settings → Modules, then choose it in Voice Settings.") }
            try assistant.action!.input.validate(["prompt": .string(text)])
            try session.edit(text); reply = ""; stopSpeaking(); waiting = true; readReply = read
            let request = UUID(); outgoing = request; outgoingEntry = assistant; status = "Asking \(assistant.action!.title)…"
            invoke(request, assistant.address, ["prompt": .string(text)])
            deadline?.cancel(); deadline = Task { [weak self] in try? await Task.sleep(for: .seconds(185)); guard !Task.isCancelled, self?.outgoing == request else { return }; self?.cancel(); self?.status = "Assistant timed out" }
        } else {
            try session.edit(text); NSPasteboard.general.clearContents(); guard NSPasteboard.general.setString(text, forType: .string) else { throw VoiceProblem.message("Could not copy the transcript. Try again.") }; status = "Transcript copied"
        }
        revision = UUID()
    }
    func updateCatalog(_ entries: [PluginCatalogEntry]) {
        catalog = entries.filter { $0.action.map(VoiceContract.accepts) == true }
        if let outgoingEntry, !catalog.contains(outgoingEntry) { cancel(); status = "Assistant disconnected or access changed. Transcript kept." }
    }
    func receive(_ request: UUID, update: PluginRunUpdate) {
        guard outgoing == request, let entry = outgoingEntry else { return }
        if update.phase.terminal {
            deadline?.cancel(); outgoing = nil; outgoingEntry = nil; waiting = false
            if update.phase == .succeeded {
                guard (try? entry.action!.output.validate(update.values)) != nil, case .string(let text) = update.values["reply"] else { status = "Assistant returned an invalid reply"; return }
                reply = text; status = "Reply ready"; if readReply { speak() }
            } else { status = update.message.isEmpty ? "Assistant request stopped" : update.message }
        }
    }
    func speak() {
        guard !busy, !reply.isEmpty else { return }; stopSpeaking()
        let utterance = AVSpeechUtterance(string: reply)
        utterance.voice = voiceID.isEmpty ? AVSpeechSynthesisVoice(language: locale) : AVSpeechSynthesisVoice(identifier: voiceID)
        speaker.speak(utterance); speaking = true; status = "Reading reply aloud"
    }
    func stopSpeaking() { speaker.stopSpeaking(at: .immediate); speaking = false }
    func refreshSpeechState() { if speaking && !speaker.isSpeaking { speaking = false; status = "Reply ready" } }
    func shutdown() { cancel(); hotkey.stop(); lifecycleObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
}
