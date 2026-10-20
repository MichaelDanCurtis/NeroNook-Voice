import AppKit
import AVFoundation
import Speech
import Combine
import ModuleCore
import VoiceAudio
import NookPluginSDK
import VoiceEditing

@MainActor final class VoiceModel: ObservableObject {
    @Published var personalization = DictationPersonalization()
    @Published var dictationHistory = DictationHistory()
    @Published var dictationPage = "dictate"
    @Published var personalizationStatus = ""
    @Published var styleApps: [DictationAppStyle] = []
    @Published var styleAppID = ""
    @Published var styleAppQuery = ""
    @Published var selectedSnippet: UUID?
    @Published var selectedHistory: UUID?
    @Published var personalizationPage = 0
    var personalizationStore: DictationPersonalizationStore?
    var personalizationFault = false
    var historyFault = false
    var historyEpoch = UUID()
    var historyLastRefresh = Date.distantPast
    var historyTicket: UUID?
    var recordingHistoryID: UUID?
    var recordingTone = DictationTone.clean
    var recordingTerms = ""
    var recordingSnippets: [DictationSnippet] = []
    var recordingAppID = ""
    var recordingAppName = "Nero Voice draft"
    var appPicker: NSOpenPanel?
    var draftPersonalizationWorker: Task<Result<String, Error>, Never>?
    var draftPersonalizationTask: Task<Void, Never>?
    let preloader = SpeechPreloader()
    @Published var session = VoiceSession()
    @Published var status = "Hold your dictation shortcut, speak, then release to paste"
    @Published var reply = ""
    @Published var overlayText: String?
    @Published var settings = false
    @Published var revision = UUID()
    @Published var microphones = MicrophoneDeviceService.inputDevices()
    @Published var languages: [String] = ["en-US"]
    @Published var catalog: [PluginCatalogEntry] = []
    @Published var microphone = UserDefaults.standard.string(forKey: "microphone") ?? "" { didSet { UserDefaults.standard.set(microphone, forKey: "microphone") } }
    @Published var locale = UserDefaults.standard.string(forKey: "locale") ?? "en-US" { didSet { preloader.release(); UserDefaults.standard.set(locale, forKey: "locale") } }
    @Published var dictionary = UserDefaults.standard.string(forKey: "dictionary") ?? "" { didSet { UserDefaults.standard.set(String(dictionary.prefix(4096)), forKey: "dictionary") } }
    @Published var tone = DictationTone(rawValue: UserDefaults.standard.string(forKey: "dictationTone") ?? "") ?? .clean { didSet { UserDefaults.standard.set(tone.rawValue, forKey: "dictationTone") } }
    @Published var interruptionSensitivity = min(100, max(0, UserDefaults.standard.object(forKey: "interruptionSensitivity") as? Int ?? 50)) {
        didSet { UserDefaults.standard.set(interruptionSensitivity, forKey: "interruptionSensitivity") }
    }
    @Published var conversationPace = ConversationPace(rawValue: UserDefaults.standard.string(forKey: "conversationPace") ?? "") ?? .quick {
        didSet { UserDefaults.standard.set(conversationPace.rawValue, forKey: "conversationPace") }
    }
    @Published var dictationASR = VoiceASRProvider(rawValue: UserDefaults.standard.string(forKey: "dictationASRProvider") ?? "") ?? .apple {
        didSet { UserDefaults.standard.set(dictationASR.rawValue, forKey: "dictationASRProvider") }
    }
    @Published var parakeetReady = LocalASREngine(.parakeet).ready
    var selectedModelReady: Bool { dictationASR == .apple || LocalASREngine(dictationASR).ready }
    private var localStream: LocalDictationStream?
    private var localReady: Task<LocalDictationStream, Error>?
    func chooseASR(_ provider: VoiceASRProvider) { guard !busy else { return }; preloader.release(); dictationASR = provider; status = "\(provider.title) selected"; changed?() }
    @Published private(set) var shortcut: DictationShortcut? = {
        if let data = UserDefaults.standard.data(forKey: "dictationShortcutBinding"),
           let saved = try? JSONDecoder().decode(DictationShortcut.self, from: data), saved.valid { return saved }
        if let old = UserDefaults.standard.string(forKey: "shortcut") { return DictationShortcut.fromLegacy(old) }
        return .standard
    }()
    @Published var shortcutStyle = DictationShortcutStyle(rawValue: UserDefaults.standard.string(forKey: "shortcutStyle") ?? "") ?? .hold { didSet { UserDefaults.standard.set(shortcutStyle.rawValue, forKey: "shortcutStyle"); shortcutState.reset() } }
    @Published var inserting = false
    @Published var polishing = false
    @Published var targetName = "your app"
    @Published var accessibilityAllowed = false
    @Published var sounds = UserDefaults.standard.bool(forKey: "sounds") { didSet { UserDefaults.standard.set(sounds, forKey: "sounds") } }
    @Published var speechBackend = SpeechBackend(rawValue: UserDefaults.standard.string(forKey: "speechBackend") ?? "") ?? .apple {
        didSet { speaker.shutdown(); UserDefaults.standard.set(speechBackend.rawValue, forKey: "speechBackend") }
    }
    @Published var qwenSpeaker = QwenSpeaker(rawValue: UserDefaults.standard.string(forKey: "qwenSpeaker") ?? "") ?? .ryan {
        didSet { stopSpeaking(); UserDefaults.standard.set(qwenSpeaker.rawValue, forKey: "qwenSpeaker") }
    }
    @Published var qwenOptions = QwenOptions.saved(UserDefaults.standard.data(forKey: "qwenOptions")) {
        didSet {
            speaker.shutdown()
            UserDefaults.standard.set(try? JSONEncoder().encode(qwenOptions), forKey: "qwenOptions")
            qwenReady = (try? QwenModel(mode: qwenOptions.mode))?.ready == true
            changed?()
        }
    }
    @Published var qwenProfiles = (try? QwenVoiceLibrary().list()) ?? []
    @Published var referenceName = ""
    @Published var referenceTranscript = ""
    @Published var referenceSource: URL?
    @Published var referenceChecking = false
    @Published var referenceSaving = false
    @Published var referenceRecording = false
    @Published var referenceElapsed = 0
    @Published var qwenPreview = "Welcome back. We have time to review your notes, or we can pick up right where we left off."
    @Published var lastArchivedVoice: UUID?
    var showQwenStudio: (() -> Void)?
    let referenceRecorder = QwenReferenceRecorder()
    var referenceTimer: Task<Void, Never>?
    var referenceOwned = false
    var referenceEpoch = UUID()
    @Published var qwenReady = (try? QwenModel(mode: QwenOptions.saved(UserDefaults.standard.data(forKey: "qwenOptions")).mode))?.ready == true
    func chooseSpeechBackend(_ value: SpeechBackend) { guard !busy else { return }; if speechBackend != value { speechBackend = value }; status = "\(value.title) selected"; changed?() }
    func chooseQwenSpeaker(_ value: QwenSpeaker) { guard !busy else { return }; qwenSpeaker = value; qwenOptions.mode = .preset; changed?() }
    var speechOutputReady: Bool { speechBackend == .apple || qwenReady }
    @Published var voiceID = UserDefaults.standard.string(forKey: "voiceID") ?? "" { didSet { UserDefaults.standard.set(voiceID, forKey: "voiceID") } }
    @Published var speechDelivery = SpeechDelivery(rawValue: UserDefaults.standard.string(forKey: "speechDelivery") ?? "") ?? .natural {
        didSet { stopSpeaking(); UserDefaults.standard.set(speechDelivery.rawValue, forKey: "speechDelivery") }
    }
    var speechVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(String(locale.prefix(2))) }
            .sorted { $0.quality.rawValue == $1.quality.rawValue ? $0.name < $1.name : $0.quality.rawValue > $1.quality.rawValue }
    }
    var selectedSpeechVoice: AVSpeechSynthesisVoice? {
        if !voiceID.isEmpty { return AVSpeechSynthesisVoice(identifier: voiceID) }
        return speechVoices.first { $0.language == locale } ?? AVSpeechSynthesisVoice(language: locale)
    }
    var speechVoiceName: String { if speechBackend == .qwen { return "Qwen3 · " + (qwenOptions.mode == .preset ? qwenSpeaker.rawValue : qwenOptions.mode == .design ? "Designed voice" : qwenProfiles.first(where: { $0.id == qwenOptions.cloneID })?.name ?? "Choose cloned voice") }; return voiceID == AppleSpeechOutput.voice2Identifier ? "Apple · American English · Voice 2" : selectedSpeechVoice?.name ?? "Voice unavailable" }
    private var reactionOutput:ConversationAudio?
    private var reactionID:UUID?
    private var startingReaction=false
    private var reactionKind:PluginAvatarReaction?
    private var reactionMeter:Task<Void,Never>?
    private var outputPhase:SpeechPlayback.Phase = .idle
    var avatarPlayback:PluginAvatarPlayback? {
        guard let id=reactionID,let kind=reactionKind,speaking else{return nil}
        return .init(id:id,kind:kind,speech:speechPresentation)
    }
    var speechPresentation:PluginSpeechPlayback {
        .init(outputPhase == .speaking ? .speaking:.preparing,level:outputPhase == .speaking ? (reactionOutput?.playbackLevel ?? 0):0)
    }
    func stopReaction(_ id:UUID?=nil) {if reactionID != nil,(id == nil || id == reactionID){stopSpeaking()}}
    func react(_ kind:PluginAvatarReaction,id:UUID) throws {
        guard kind.hasAudio else{return}
        try speakShared(kind.spokenText,reactionID:id)
    }
    func handleAvatar(_ event:PluginViewEvent) throws {
        try voiceDefinition.validate(event)
        guard case .string(let raw)=event.values["id"],let id=UUID(uuidString:raw),case .string(let kind)=event.values["kind"] else{throw VoiceProblem.message("Invalid avatar gesture")}
        if kind == "stop"{stopReaction(id)}else if let kind=PluginAvatarReaction(rawValue:kind){try react(kind,id:id)}
        changed?()
    }
    private func clearReaction() {
        reactionID=nil;reactionKind=nil;reactionMeter?.cancel();reactionMeter=nil
        speaker.engineOutput=nil;reactionOutput?.stop();reactionOutput=nil
    }
    var speechPhaseChanged: ((SpeechPlayback.Phase, String?) -> Void)?
    func chooseSpeechVoice(_ id: String) { stopSpeaking(); voiceID = id; changed?() }
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
    var meetingActive: (() -> Bool)?
    var stopMeetingPlayback: (() -> Void)?
    private var pinnedAction: PluginRegisteredAction? = UserDefaults.standard.data(forKey: "assistantDefinition").flatMap { try? JSONDecoder().decode(PluginRegisteredAction.self, from: $0) }
    private var pipeline: SpeechPipeline?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var assetTask: Task<Void, Never>?
    private var assetGeneration = UUID()
    private let speaker = SpeechOutput()
    private let hotkey = PushToTalk()
    private let rewriteHotkey = PushToTalk(id: 2)
    let rewrite = SelectionRewrite(editor: AXSelectionEditor(), generate: SelectionTransformer.transform)
    private lazy var rewriteWindow = SelectionRewriteWindow(model: rewrite)
    @Published private(set) var rewriteShortcut: DictationShortcut? = {
        if UserDefaults.standard.bool(forKey: "rewriteShortcutOff") { return nil }
        if let data = UserDefaults.standard.data(forKey: "rewriteShortcutBinding"),
           let saved = try? JSONDecoder().decode(DictationShortcut.self, from: data), saved.valid, saved.trigger == .key { return saved }
        return .init(keyCode: 15, modifiers: 4096 | 2048, keyLabel: "R")
    }()
    private var observations = Set<AnyCancellable>()
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var outgoing: UUID?
    private var outgoingEntry: PluginCatalogEntry?
    private var readReply = false
    private var shortcutState = DictationShortcutState()
    private let insertion = DictationInsertion()
    private let overlay = DictationOverlay()
    private var target: DictationInsertion.Target?
    private var insertionWork: Task<Void, Never>?
    private var polishWork: Task<String, Error>?
    private var insertionGeneration = UUID()
    private var overlayCompletion: Task<Void, Never>?
    private var dictating = false
    private var captionVisible = false
    private var captionDisplayNumber: UInt32?
    private var captionResult = false
    var hostCaptionAvailable = false
    var enhancedCaptionAvailable = false
    @Published var captionPlacement = PluginTransientCaption.Placement(rawValue: UserDefaults.standard.string(forKey: "captionPlacement") ?? "") ?? .nook {
        didSet { UserDefaults.standard.set(captionPlacement.rawValue, forKey: "captionPlacement") }
    }
    var usesHostCaption: Bool { hostCaptionAvailable && (captionPlacement == .nook || enhancedCaptionAvailable) }
    var captionChanged: (() -> Void)?
    private(set) var inputLevel = 0.0
    private var levelTask: Task<Void, Never>?
    private var captionFault = false
    var busy: Bool { rewrite.active || referenceChecking || referenceSaving || referenceRecording || appPicker != nil || session.recording || waiting || preparingAssets || polishing || inserting || meetingActive?() == true }
    var transientCaption: PluginTransientCaption? {
        guard usesHostCaption, captionVisible else { return nil }
        let words = !captionResult && session.phase == .preparing ? "" : overlayText ?? session.transcript
        let safeText = String(words.unicodeScalars.suffix(220))
        return PluginTransientCaption(captionResult ? .result : .active,
                                      title: captionResult ? "Nero Voice" : "Dictating to \(targetName.prefix(55))",
                                      text: safeText, detail: String((status + " · " + recordingTone.rawValue).prefix(160)),
                                      symbol: captionResult ? "checkmark.circle.fill" : "waveform",
                                      displayNumber: captionDisplayNumber,
                                      placement: enhancedCaptionAvailable ? captionPlacement : nil,
                                      activity: enhancedCaptionAvailable ? (captionFault ? .error : captionResult ? .complete : session.phase == .listening ? .recording : .processing) : nil,
                                      level: enhancedCaptionAvailable ? inputLevel : nil)
    }
    var assistant: PluginCatalogEntry? { catalog.first { $0.address.key == selectedKey && $0.action == pinnedAction && $0.action.map(VoiceContract.accepts) == true } }
    init() {
        preloader.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.changed?() } }.store(in: &observations)
        loadPersonalization()
        speaker.changed = { [weak self] phase, error in
            guard let self else { return }
            self.outputPhase=phase
            let wasSpeaking = self.speaking
            self.speaking = phase == .preparing || phase == .speaking
            if let error { self.status = error }
            else if phase == .preparing { self.status = "Preparing \(self.speechBackend == .qwen ? "Qwen" : "Apple") speech…" }
            else if phase == .speaking { self.status = "Reading aloud · \(self.speechVoiceName)" }
            else if phase == .finished { self.status = "Reading finished" }
            else if phase == .idle && wasSpeaking { self.status = "Reading stopped" }
            if !self.speaking,self.reactionID != nil,!self.startingReaction {self.clearReaction()}
            self.speechPhaseChanged?(phase, error)
            self.changed?()
        }
        objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.changed?() } }.store(in: &observations)
        hotkey.cancelled = { [weak self] in self?.cancel(); self?.status = "Shortcut interrupted · no text pasted" }
        hotkey.pressed = { [weak self] in self?.shortcutPressed() }
        rewriteHotkey.pressed = { [weak self] in self?.beginSelectionRewrite() }
        rewrite.changed = { [weak self] in
            guard let self else { return }
            if !self.rewrite.active { self.rewriteWindow.hide() }
            self.objectWillChange.send(); self.changed?()
        }
        hotkey.released = { [weak self] in
            guard let self else { return }
            if self.shortcutState.release(style: self.shortcutStyle) == .stop { self.stopRecording() }
        }
        accessibilityAllowed = insertion.permitted
        if !CommandLine.arguments.contains("--protocol-test") {
            configureHotkey()
            Task { [weak self] in self?.languages = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted() }
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.cancel(); self?.speaker.shutdown(); self?.status = "Stopped for sleep or screen lock" } })
            }
        }
    }
    private func shortcutPressed() {
        switch shortcutState.press(style: shortcutStyle, busy: busy) {
        case .stop: stopRecording()
        case .none: break
        case .start:
            overlayCompletion?.cancel()
            do {
                target = try insertion.capture(); targetName = target!.name; dictating = true
                captionDisplayNumber = target?.displayNumber; captionVisible = true; captionResult = false; overlayText = nil
                beginRecording()
                if !usesHostCaption { overlay.show(model: self) }
            } catch {
                shortcutState.reset(); status = error.localizedDescription
                overlay.show(model: self)
            }
        }
    }
    private func finishDictation(into target: DictationInsertion.Target) {
        self.target = nil; dictating = false; inserting = true
        status = "Pasting into \(target.name)…"
        let text = session.transcript; let historyID = recordingHistoryID; let generation = UUID(); insertionGeneration = generation
        insertionWork = Task { [self] in
            defer { inserting = false }
            do {
                try await insertion.insert(text, into: target)
                guard generation == insertionGeneration else { return }
                setHistoryOutcome(historyID, value: "Paste sent")
                status = "Paste sent to \(target.name)"
                captionResult = true
                scheduleOverlayDismissal(after: 5)
            } catch {
                guard generation == insertionGeneration else { return }
                setHistoryOutcome(historyID, value: "Paste failed")
                status = error.localizedDescription
                captionFault = true; captionResult = true
                scheduleOverlayDismissal(after: 8)
            }
        }
    }
    private func scheduleOverlayDismissal(after seconds: Double) {
        overlayCompletion?.cancel()
        overlayCompletion = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.captionVisible = false
            self.overlay.hide()
            self.changed?()
        }
    }
    func requestInsertionPermission() { insertion.requestPermission(); accessibilityAllowed = insertion.permitted }
    func dismissOverlay() { if session.recording || inserting { cancel() }; overlayCompletion?.cancel(); overlay.hide() }
    var shortcutName: String { shortcut?.displayName ?? "Off" }
    func configureHotkey() {
        guard !CommandLine.arguments.contains("--protocol-test"), Bundle.main.object(forInfoDictionaryKey: "NeroLiveFixtureAudio") == nil else { return }
        do { try hotkey.configure(shortcut) } catch { status = error.localizedDescription }
        do {
            if rewriteShortcutConflict { rewriteHotkey.stop(); status = "Rewrite conflicts with dictation. Choose a different shortcut in Voice settings." }
            else { try rewriteHotkey.configure(rewriteShortcut) }
        } catch { status = error.localizedDescription }
    }
    var rewriteShortcutConflict: Bool { if let rewriteShortcut, let shortcut { return rewriteShortcut.sameBinding(as: shortcut) }; return false }
    var rewriteShortcutName: String { rewriteShortcutConflict ? "Conflict · choose another shortcut" : rewriteShortcut?.displayName ?? "Off" }
    func pauseShortcutForRecording() { hotkey.stop(); rewriteHotkey.stop() }
    func resumeShortcutAfterRecording() { configureHotkey() }
    func beginSelectionRewrite() {
        if rewrite.active { rewriteWindow.show(); return }
        guard !busy, !speaking else { status = "Finish the current Voice activity before Rewrite."; changed?(); return }
        do {
            try rewrite.begin() // Capture BEFORE bringing the review window forward.
            rewriteWindow.show()
        } catch { status = error.localizedDescription; changed?() }
    }
    func chooseRewriteShortcut(_ candidate: DictationShortcut?) {
        guard !busy else { return }
        guard candidate == nil || (candidate!.valid && candidate!.trigger == .key && !(shortcut.map { candidate!.sameBinding(as: $0) } ?? false)) else {
            status = "Use a key combination different from dictation for Rewrite."; configureHotkey(); return
        }
        do {
            try rewriteHotkey.configure(candidate)
            rewriteShortcut = candidate
            UserDefaults.standard.set(candidate == nil, forKey: "rewriteShortcutOff")
            UserDefaults.standard.set(candidate.flatMap { try? JSONEncoder().encode($0) }, forKey: "rewriteShortcutBinding")
            configureHotkey(); status = candidate.map { "Rewrite shortcut set to \($0.displayName)" } ?? "Rewrite shortcut off"
        } catch { configureHotkey(); status = error.localizedDescription }
    }
    func chooseShortcut(_ candidate: DictationShortcut?) {
        guard !busy else { return }
        guard candidate == nil || !(rewriteShortcut.map { candidate!.sameBinding(as: $0) } ?? false) else { status = "Choose different shortcuts for dictation and Rewrite."; configureHotkey(); return }
        guard candidate?.valid ?? true else { status = "Choose Fn, modifiers, a key combination or an F-key."; configureHotkey(); return }
        do {
            try hotkey.configure(candidate)
            shortcut = candidate
            UserDefaults.standard.set(candidate.flatMap { try? JSONEncoder().encode($0) }, forKey: "dictationShortcutBinding")
            UserDefaults.standard.set(candidate == nil ? "Off" : "Custom", forKey: "shortcut")
            configureHotkey()
            status = candidate.map { "Dictation shortcut set to \($0.displayName)" } ?? "Dictation shortcut off"
        } catch {
            configureHotkey()
            status = error.localizedDescription
        }
    }
    func refreshDevices() { microphones = MicrophoneDeviceService.inputDevices() }
    func prepareConversation() {
        guard !busy, !speaking, selectedModelReady else { return }
        preparingAssets = true
        let generation = UUID(); assetGeneration = generation
        let provider = dictationASR, language = locale
        assetTask = Task { [self] in
            do { try await preloader.prepare(provider: provider, locale: language, helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroASR")) }
            catch { if generation == assetGeneration, !Task.isCancelled { status = error.localizedDescription } }
            if generation == assetGeneration { preparingAssets = false; assetTask = nil; changed?() }
        }
    }
    func releasePreparedSpeech() {
        guard !preparingAssets || preloader.preparing else { return }
        preloader.release(); assetGeneration = UUID(); assetTask?.cancel(); assetTask = nil; preparingAssets = false; changed?()
    }
    func prepareAssets() {
        guard !busy else { return }; preparingAssets = true; status = "Preparing Apple Speech language…"
        let generation = UUID(); assetGeneration = generation; let language = locale
        assetTask = Task { [self] in
            do { _ = try await SpeechPipeline.prepare(localeIdentifier: language, install: true); try Task.checkCancellation(); guard generation == assetGeneration else { return }; status = "Language ready · audio stays on this Mac" }
            catch { if !Task.isCancelled, generation == assetGeneration { status = error.localizedDescription } }
            if generation == assetGeneration { preparingAssets = false; assetTask = nil }
        }
    }
    func prepareLocalModel() {
        guard !busy else { return }
        guard dictationASR != .apple else { prepareAssets(); return }
        preloader.release()
        let engine = LocalASREngine(dictationASR)
        preparingAssets = true; status = "Preparing \(engine.name) · 756 MB download…"
        let generation = UUID(); assetGeneration = generation
        assetTask = Task { [self] in
            do {
                try await engine.prepare()
                try Task.checkCancellation()
                guard generation == assetGeneration else { return }
                status = "\(engine.name) ready for dictation and meetings"
            } catch {
                if !Task.isCancelled, generation == assetGeneration { status = error.localizedDescription }
            }
            if generation == assetGeneration {
                parakeetReady = LocalASREngine(.parakeet).ready
                preparingAssets = false; assetTask = nil
            }
        }
    }
    func record() {
        guard !busy else { return }; target = nil; dictating = false; captionVisible = false; beginRecording()
    }
    private func beginRecording() {
        guard !busy else { return }
        preloader.release()
        recordingAppID = target?.appID ?? ""; recordingAppName = target?.name ?? "Nero Voice draft"
        recordingTone = personalization.tone(for: target?.appID, fallback: tone)
        recordingTerms = dictionary; recordingSnippets = personalization.snippets
        historyTicket = personalization.historyEnabled && !historyFault ? historyEpoch : nil; recordingHistoryID = nil
        stopSpeaking(); stopLevelMeter(); captionFault = false; reply = ""; overlayText = nil; let token = session.begin(); revision = UUID(); status = "Preparing microphone…"
        if !selectedModelReady {
            cancel(); status = "Prepare the selected model on the Voice card before dictating."
            return
        }
        deadline?.cancel(); deadline = Task { [weak self] in try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled, self?.session.token == token, self?.session.phase == .preparing else { return }; self?.cancel(); self?.status = "Microphone preparation timed out. Try Record again." }
        work = Task { [self] in
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                try Task.checkCancellation(); guard session.token == token else { return }
                guard allowed else { throw VoiceProblem.message("Allow Nero Voice in System Settings → Privacy & Security → Microphone.") }
                let pipeline = SpeechPipeline(); self.pipeline = pipeline
                try await pipeline.start(microphone: microphone.isEmpty ? nil : microphone, locale: locale, provider: dictationASR, partial: { [weak self] text in
                    guard let self, self.session.token == token else { return }
                    do { try self.session.partial(text, token: token) } catch { self.fail(error.localizedDescription, token: token) }
                }, failure: { [weak self] text in self?.fail(text, token: token) })
                try Task.checkCancellation(); guard session.ready(token) else { pipeline.cancel(); return }
                startLevelMeter(token)
                deadline?.cancel(); deadline = Task { [weak self] in try? await Task.sleep(for: .seconds(60)); guard !Task.isCancelled, self?.session.token == token else { return }; self?.stopRecording() }
                if dictationASR == .nemotron {
                    status = "Recording locally · preparing Nemotron…"
                    let ready = Task { [self] in
                        let stream = try LocalDictationStream(); localStream = stream
                        try await stream.start(helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroASR"))
                        return stream
                    }
                    localReady = ready
                    let stream = try await ready.value
                    try Task.checkCancellation(); guard session.token == token else { return }
                    // Release may already be finalizing the captured audio. Do
                    // not resume capture or start a second PCM writer afterward.
                    guard session.phase == .listening else { return }
                    stream.observe(audio: { [weak pipeline] in pipeline?.capturedSnapshot }, partial: { [weak self] text in
                        guard let self, self.session.token == token else { return }
                        do { try self.session.partial(text, token: token) } catch { self.fail(error.localizedDescription, token: token) }
                    }, failure: { [weak self] text in self?.fail(text, token: token) })
                }
                status = dictationASR == .parakeet
                    ? "Listening with Parakeet · release to transcribe"
                    : (shortcutStyle == .hold ? "Listening · release shortcut or press Stop" : "Listening · press shortcut again to finish")
                if sounds { NSSound(named: "Tink")?.play() }
            } catch { if session.token == token { fail(error.localizedDescription, token: token) } }
        }
    }
    private func startLevelMeter(_ token: UUID) {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.session.token == token, self.session.phase == .listening else { return }
                let signal = self.pipeline?.inputSignal?.level ?? 0
                self.inputLevel = min(1, max(0, self.inputLevel * 0.4 + signal * 0.6))
                self.captionChanged?()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private func stopLevelMeter() { levelTask?.cancel(); levelTask = nil; inputLevel = 0; captionChanged?() }
    func stopRecording() {
        if session.phase == .preparing {
            cancel(); status = "Released before the microphone was ready. Hold again and speak when REC appears."; return
        }
        stopLevelMeter()
        let token = session.token
        guard session.finishing(token), let pipeline else { return }
        deadline?.cancel(); status = dictationASR == .parakeet ? "Transcribing with local Parakeet…" : "Finishing your last words…"
        let selectedProvider = dictationASR
        deadline = Task { [weak self] in try? await Task.sleep(for: .seconds(selectedProvider != .apple ? 60 : 12)); guard !Task.isCancelled, self?.session.token == token else { return }; self?.cancel(); self?.status = "Speech finalization timed out. Review the partial text before using it." }
        work = Task { [self] in
            do {
                let appleText = try await pipeline.finish()
                let text: String
                if selectedProvider == .nemotron {
                    guard let pcm = pipeline.capturedAudio, let ready = localReady else { throw VoiceProblem.message("No local audio was captured.") }
                    let stream = try await ready.value
                    try Task.checkCancellation(); guard session.token == token else { return }
                    text = try await stream.finish(pcm); localStream = nil; localReady = nil
                } else if selectedProvider == .parakeet {
                    guard let pcm = pipeline.capturedAudio else { throw VoiceProblem.message("No local audio was captured.") }
                    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroASR")
                    text = try await LocalASREngine(.parakeet).transcribeDictation(pcm, helper: helper)
                } else { text = appleText }
                try Task.checkCancellation(); guard session.token == token else { return }
                try session.finish(text, token: token)
                self.pipeline = nil; deadline?.cancel(); polishing = true
                status = recordingTone == .literal ? "Preparing words…" : "Cleaning your words on this Mac…"
                // FoundationModels may synchronously initialize a local model
                // before its first suspension. Keep that work off the main
                // actor so the plugin can continue servicing its heartbeat.
                let selectedTone = recordingTone
                let selectedDictionary = recordingTerms
                let snippets = recordingSnippets
                let polish = Task.detached(priority: .userInitiated) {
                    let plan = try DictationSnippetPlan(raw: text, snippets: snippets)
                    if let exact = plan.exactText { return exact }
                    let cleaned = await VoicePolisher.polish(plan.prepared, tone: selectedTone, dictionary: selectedDictionary)
                    return try plan.render(cleaned, fallback: VoiceCleanup.baseline(plan.prepared, tone: selectedTone, dictionary: selectedDictionary))
                }
                polishWork = polish
                let cleaned = try await polish.value
                if session.token == token { polishWork = nil }
                try Task.checkCancellation(); guard session.token == token else { return }
                try session.edit(cleaned)
                recordingHistoryID = saveDictationHistory(raw: text, text: cleaned, tone: selectedTone, appID: recordingAppID, appName: recordingAppName, recognizer: selectedProvider.rawValue, ticket: historyTicket)
                overlayText = cleaned; polishing = false; revision = UUID(); shortcutState.reset()
                status = "Review your transcript · nothing sent"
                if dictating, let target { finishDictation(into: target) }
            } catch { if session.token == token { fail(error.localizedDescription, token: token) } }
        }
    }
    private func fail(_ message: String, token: UUID) {
        guard session.token == token else { return }
        let wasDictating = dictating
        cancel(); status = message; captionFault = true
        if wasDictating {
            captionVisible = true; captionResult = true
            scheduleOverlayDismissal(after: 8)
            changed?()
        }
    }
    func cancel() {
        rewrite.close()
        cancelReference()
        speaker.shutdown()
        preloader.release()
        stopLevelMeter(); captionFault = false
        appPicker?.cancel(nil); appPicker = nil
        draftPersonalizationWorker?.cancel(); draftPersonalizationTask?.cancel(); draftPersonalizationWorker = nil; draftPersonalizationTask = nil
        historyTicket = nil
        stopMeetingPlayback?()
        shortcutState.reset(); target = nil; dictating = false
        insertionGeneration = UUID(); insertionWork?.cancel(); overlayCompletion?.cancel(); overlayText = nil
        polishWork?.cancel(); polishWork = nil
        captionVisible = false; captionResult = false; polishing = false
        // An already sent paste cannot be recalled; retain busy until its clipboard lease ends.
        work?.cancel(); work = nil; deadline?.cancel(); deadline = nil
        assetGeneration = UUID(); assetTask?.cancel(); assetTask = nil; preparingAssets = false
        localReady?.cancel(); localReady = nil; localStream?.cancel(); localStream = nil; pipeline?.cancel(); pipeline = nil; session.cancel(); revision = UUID()
        if let outgoing { cancelInvocation?(outgoing) }; outgoing = nil; outgoingEntry = nil; waiting = false
        stopSpeaking(); status = "Stopped · review any partial text"; changed?()
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
        speakText(reply)
    }
    func renderSpeech(_ text: String) throws {
        try speaker.speak(text, backend: speechBackend, voiceID: voiceID, appleVoice: selectedSpeechVoice,
                          qwenSpeaker: qwenSpeaker, locale: locale, delivery: speechDelivery, qwenOptions: qwenOptions)
    }
    func speakText(_ text: String) {
        guard !busy, !CommandLine.arguments.contains("--protocol-test") else { return }
        do { try renderSpeech(text) } catch { status = error.localizedDescription; changed?() }
    }
    func speakShared(_ text: String,reactionID requestedID:UUID?=nil) throws {
        guard !busy, !speaking, meetingActive?() != true, !CommandLine.arguments.contains("--protocol-test") else { throw VoiceProblem.message("Voice is busy. Finish the current activity first.") }
        let reaction=PluginAvatarReaction.allCases.first{$0.hasAudio && $0.spokenText == text}
        startingReaction=reaction != nil;defer{startingReaction=false}
        if let reaction {
            reactionKind=reaction;reactionID=requestedID ?? UUID()
            let output=ConversationAudio();try output.startOutput();reactionOutput=output;speaker.engineOutput=output
        }
        do {
            if reaction != nil {
                var options=qwenOptions
                if speechBackend == .qwen,options.mode == .preset {
                    let cue="Speak playfully with a happy smiling voice and light natural giggles. Keep the words clear."
                    if options.instruction.utf8.count+cue.utf8.count+1<=512 {options.instruction += (options.instruction.isEmpty ? "":" ")+cue}
                }
                try speaker.speak(text,backend:speechBackend,voiceID:voiceID,appleVoice:selectedSpeechVoice,qwenSpeaker:qwenSpeaker,locale:locale,delivery:speechDelivery,qwenOptions:options)
            } else {try renderSpeech(text)}
        } catch {clearReaction();throw error}
        if let reaction {
            let id=reactionID
            reactionMeter=Task{[weak self] in
                let start=Date()
                while !Task.isCancelled {
                    try? await Task.sleep(for:.milliseconds(100))
                    guard !Task.isCancelled,let self,self.reactionID==id else{return}
                    if Date().timeIntervalSince(start)>40 || self.meetingActive?() == true || self.busy {self.stopReaction();return}
                    self.changed?()
                }
            }
        }
    }
    func releaseSpeakingModel() { speaker.shutdown(); status = "Speaking model released · downloaded files retained"; changed?() }
    func prepareQwen() {
        guard !busy, !speaking, !CommandLine.arguments.contains("--protocol-test") else { return }
        preloader.release(); preparingAssets = true; let id = UUID(); assetGeneration = id
        status = "Preparing Qwen · download once, all speech stays local…"; changed?()
        assetTask = Task { [weak self] in
            guard let self else { return }
            do {
                let model = try QwenModel(mode: qwenOptions.mode)
                try await model.download { [weak self] done, total in Task { @MainActor in
                    guard let self, self.assetGeneration == id, self.preparingAssets else { return }
                    self.status = "Preparing Qwen · file \(done) of \(total)"; self.changed?()
                } }
                try Task.checkCancellation(); guard assetGeneration == id else { return }
                try await speaker.prepareQwen(mode: qwenOptions.mode); try Task.checkCancellation(); guard assetGeneration == id else { return }
                qwenReady = true; status = "Qwen ready · microphone off · releases after 60 idle seconds"
            } catch { if assetGeneration == id { status = error.localizedDescription } }
            guard assetGeneration == id else { return }; preparingAssets = false; assetTask = nil; changed?()
        }
    }
    func readDraft() { speakText(session.transcript) }
    func previewSpeech() { speakText("Welcome back. We have time to review your notes, or we can pick up right where we left off. What would you like to do?") }
    func stopSpeaking() { speaker.stop(); clearReaction(); speaking = false }
    func refreshSpeechState() {
        if Date().timeIntervalSince(historyLastRefresh) > 60 && !busy { refreshHistory() }
        accessibilityAllowed = insertion.permitted
        if session.phase == .listening, let error = pipeline?.inputError { fail(error, token: session.token); return }
        if session.phase == .listening, let signal = pipeline?.inputSignal {
            if signal.age > 3 { fail("The microphone stopped delivering audio. Choose a microphone in Voice settings and try again.", token: session.token); return }
            let device = microphones.first { microphone.isEmpty ? $0.isDefault : $0.id == microphone }?.name ?? "Microphone"
            status = "\(dictationASR == .parakeet ? "Listening with Parakeet" : "Listening") · \(device) · input \(Int(signal.level * 100))%"
        }
    }
    func shutdown() { cancel(); discardReferenceSource(); speaker.shutdown(); insertion.shutdown(); overlay.hide(); hotkey.stop(); rewriteHotkey.stop(); lifecycleObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
}
