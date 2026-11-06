import AppKit
import AVFoundation
import Speech
import Combine
import ModuleCore
import VoiceAudio
import NookPluginSDK
import VoiceEditing

@MainActor final class VoiceModel: ObservableObject {
    let configuration:VoiceProductConfiguration
    var nativeSpeechOutputIsConstructed:Bool{speaker != nil}
    var hasAmbientProductObservers:Bool{!lifecycleObservers.isEmpty}
    var preferences:VoiceProductPreferences { configuration.preferences }
    @discardableResult func allowProductEffect(_ effect:VoiceProductConfiguration.Effect)->Bool {
        guard configuration.admit(effect) else{status=configuration.reason;return false};return true
    }
    var serviceBeginLocal: (() throws -> Void)?
    let fileWork=VoiceFileWork()
    var referenceInput:VoiceOwnedFileSource?
    var referenceCleanupIssue:String?
    var referenceSaveResult:(epoch:UUID,owner:VoiceFoundationOwner,result:Result<QwenReference,Error>)?
    var referenceFinishResult:(epoch:UUID,result:Result<URL,Error>)?
    var referencePicker:NSOpenPanel?
    var referencePickerCallback:VoiceFileCallback?
    var referenceOwner=LocalFoundationModelWork.localUser
    var referencePickerOwner=LocalFoundationModelWork.localUser
    private let controlAdmission = VoiceAudioCallbackAdmission()
    private var originalControlJobs: [UUID: Task<Void, Never>] = [:]
    private var originalControlShutdown: Task<Void, Never>?
    func enterControlCallback() -> VoiceAudioCallbackLease? { controlAdmission.enter() }
    private func retainControlJob(_ original: Task<Void, Never>?) {
        guard let original else { return }
        let id=UUID(); originalControlJobs[id]=original
        Task { [weak self] in await original.value; self?.originalControlJobs[id]=nil }
    }
    private let dictationIOOutcomes=VoiceOriginalIOOutcomes()
    private var recordingFoundationAdmission: VoiceFoundationAdmission?
    private var recordingFileAdmission:(sessionID:UUID,owner:VoiceFoundationOwner)?
    private var rewriteFoundationOwner = LocalFoundationModelWork.localUser
    private var originalReactionReturns: [UUID: Task<Void, Never>] = [:]
    func captureReferenceConsumer()->VoiceFilePriorReturn{
        let original=speaker?.ownedShutdown()
        return VoiceFilePriorReturn(completion:original?.completion,issue:{original?.issue})
    }
    func storePreference(_ value:Any?,forKey key:String){
        let owner=LocalFoundationModelWork.currentOwner
        try? fileWork.operation(owner:owner){try configuration.validateData();preferences.set(value,forKey:key);if let issue=preferences.issue{throw VoiceProblem.message(issue)}}
    }
    func serviceAllowsActivity() -> Bool {
        guard allowProductEffect(.capture), originalControlShutdown == nil else { return false }
        guard dictationIOOutcomes.issue == nil,preloader.resourceReturnIssue == nil else{
            status="The previous local speech resources need recovery. Restart Voice before recording again.";changed?();return false
        }
        do { try serviceBeginLocal?(); return true }
        catch { status = error.localizedDescription; changed?(); return false }
    }
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
    var appPickerCallback:VoiceFileCallback?
    var appPickerOwner=LocalFoundationModelWork.localUser
    var historyEraseAlert:NSAlert?
    var historyEraseOwner=LocalFoundationModelWork.localUser
    var draftPersonalizationWorker: Task<Result<String, Error>, Never>?
    var draftPersonalizationTask: Task<Void, Never>?
    let preloader = SpeechPreloader()
    @Published var session = VoiceSession()
    @Published var status = "Hold your dictation shortcut, speak, then release to paste"
    @Published var reply = ""
    @Published var overlayText: String?
    @Published var settings = false
    @Published var revision = UUID()
    @Published var microphones: [MicrophoneDevice] = []
    @Published var languages: [String] = ["en-US"]
    @Published var catalog: [PluginCatalogEntry] = []
    @Published var microphone = "" { didSet { storePreference(microphone, forKey: "microphone") } }
    @Published var locale = "en-US" { didSet { preloader.release(); storePreference(locale, forKey: "locale") } }
    @Published var dictionary = "" { didSet { storePreference(String(dictionary.prefix(4096)), forKey: "dictionary") } }
    @Published var tone = DictationTone.clean { didSet { storePreference(tone.rawValue, forKey: "dictationTone") } }
    @Published var interruptionSensitivity = 50 {
        didSet { storePreference(interruptionSensitivity, forKey: "interruptionSensitivity") }
    }
    @Published var conversationPace = ConversationPace.quick {
        didSet { storePreference(conversationPace.rawValue, forKey: "conversationPace") }
    }
    @Published var dictationASR = VoiceASRProvider.apple {
        didSet { storePreference(dictationASR.rawValue, forKey: "dictationASRProvider") }
    }
    @Published var parakeetReady = false
    var selectedModelReady:Bool{
        configuration.allows(.model) && (dictationASR == .apple || ((try? fileWork.operation(owner:LocalFoundationModelWork.currentOwner){LocalASREngine(dictationASR).ready}) ?? false))
    }
    private var localStream: LocalDictationStream?
    private var localReady: Task<LocalDictationStream, Error>?
    func chooseASR(_ provider: VoiceASRProvider) { guard !busy else { return }; preloader.release(); dictationASR = provider; status = "\(provider.title) selected"; changed?() }
    @Published private(set) var shortcut: DictationShortcut? = .standard
    @Published var shortcutStyle = DictationShortcutStyle.hold { didSet { storePreference(shortcutStyle.rawValue, forKey: "shortcutStyle"); shortcutState.reset() } }
    @Published var inserting = false
    @Published var polishing = false
    @Published var targetName = "your app"
    @Published var accessibilityAllowed = false
    @Published var sounds = false { didSet { storePreference(sounds, forKey: "sounds") } }
    @Published var speechBackend = SpeechBackend.apple {
        didSet { speaker?.shutdown(); storePreference(speechBackend.rawValue, forKey: "speechBackend") }
    }
    @Published var qwenSpeaker = QwenSpeaker.ryan {
        didSet { stopSpeaking(); storePreference(qwenSpeaker.rawValue, forKey: "qwenSpeaker") }
    }
    @Published var qwenOptions = QwenOptions() {
        didSet {
            speaker?.shutdown()
            storePreference(try? JSONEncoder().encode(qwenOptions), forKey: "qwenOptions")
            qwenReady = configuration.allows(.model) && ((try? fileWork.operation(owner:LocalFoundationModelWork.currentOwner){(try? QwenModel(mode:qwenOptions.mode))?.ready == true}) ?? false)
            changed?()
        }
    }
    @Published var qwenProfiles: [QwenReference] = []
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
    var referenceTimer: Task<Void,Never>?{
        didSet{if let referenceTimer{fileWork.retain(referenceTimer,owner:referenceOwner)}}
    }
    var referenceOwned = false
    var referenceEpoch = UUID()
    @Published var qwenReady = false
    func chooseSpeechBackend(_ value: SpeechBackend) { guard !busy else { return }; if speechBackend != value { speechBackend = value }; status = "\(value.title) selected"; changed?() }
    func chooseQwenSpeaker(_ value: QwenSpeaker) { guard !busy else { return }; qwenSpeaker = value; qwenOptions.mode = .preset; changed?() }
    var speechOutputReady: Bool { configuration.allows(.speech) && (speechBackend == .apple || qwenReady) }
    @Published var voiceID = "" { didSet { storePreference(voiceID, forKey: "voiceID") } }
    @Published var speechDelivery = SpeechDelivery.natural {
        didSet { stopSpeaking(); storePreference(speechDelivery.rawValue, forKey: "speechDelivery") }
    }
    var speechVoices: [AVSpeechSynthesisVoice] {
        guard configuration.allows(.discovery) else{return []}
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(String(locale.prefix(2))) }
            .sorted { $0.quality.rawValue == $1.quality.rawValue ? $0.name < $1.name : $0.quality.rawValue > $1.quality.rawValue }
    }
    var selectedSpeechVoice: AVSpeechSynthesisVoice? {
        guard configuration.allows(.discovery) else{return nil}
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
        reactionID=nil;reactionKind=nil
        let originalMeter=reactionMeter;reactionMeter=nil;retainControlJob(originalMeter);originalMeter?.cancel()
        speaker?.engineOutput=nil
        let originalOutput = reactionOutput; reactionOutput=nil
        if let originalOutput {
            let id=UUID(), original=originalOutput.stopAndWait()
            originalReactionReturns[id]=original
            Task { [weak self] in await original.value; self?.originalReactionReturns[id]=nil; self?.changed?() }
        }
    }
    var speechPhaseChanged: ((SpeechPlayback.Phase, String?) -> Void)?
    func chooseSpeechVoice(_ id: String) { stopSpeaking(); voiceID = id; changed?() }
    @Published var selectedKey = "" {
        didSet {
            pinnedAction = catalog.first { $0.address.key == selectedKey }?.action
            storePreference(selectedKey, forKey: "assistant")
            storePreference(try? JSONEncoder().encode(pinnedAction), forKey: "assistantDefinition")
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
    private var pinnedAction: PluginRegisteredAction?
    private var pipeline: SpeechPipeline?
    private let dictationWork = DictationWorkOwner()
    private var cancellingDictation = false
    private var deadline: Task<Void, Never>?
    private var assetTask: Task<Void, Never>? {
        didSet{if let assetTask{fileWork.retain(assetTask,owner:LocalFoundationModelWork.currentOwner)}}
    }
    private var assetGeneration = UUID()
    private var assetCallbacks:[UUID:(owner:VoiceFoundationOwner,gate:VoiceAudioCallbackAdmission)]=[:]
    private var speaker: SpeechOutput?
    private var speechFileOwner=LocalFoundationModelWork.localUser
    private let hotkey = PushToTalk()
    private let rewriteHotkey = PushToTalk(id: 2)
    let rewrite = SelectionRewrite(editor: AXSelectionEditor(), generate: SelectionTransformer.transform)
    private var rewriteWindow:SelectionRewriteWindow?
    @Published private(set) var rewriteShortcut: DictationShortcut? = .init(keyCode:15,modifiers:4096 | 2048,keyLabel:"R")
    private var observations = Set<AnyCancellable>()
    private var lifecycleObservers: [NSObjectProtocol] = []
    var captureProviderRequest: ((UUID)->VoiceOwnedProviderRequest?)?
    private var providerHandles:[UUID:VoiceOwnedProviderRequest]=[:]
    private var providerSettlements:[UUID:Task<Void,Never>]=[:]
    private var providerOutcomes:[UUID:String]=[:]
    private var outgoing: UUID?
    private var outgoingEntry: PluginCatalogEntry?
    private var readReply = false
    private var shortcutState = DictationShortcutState()
    private let insertion = DictationInsertion()
    private let overlay:DictationOverlay
    let presentationAppearanceStore:PluginAppearanceStore?
    private let presentationAllowed:@MainActor ()->Bool
    private var originalPresentationRetirement:Task<Bool,Never>?
    private var target: DictationInsertion.Target?
    private var insertionFileOwner=LocalFoundationModelWork.localUser
    private var insertionWork:Task<Void,Never>?{
        didSet{if let insertionWork{fileWork.retain(insertionWork,owner:insertionFileOwner)}}
    }
    private var polishWork: Task<String, Error>?
    private var insertionGeneration = UUID()
    private var overlayCompletion: Task<Void, Never>?
    private var dictating = false
    private var captionVisible = false
    private var captionDisplayNumber: UInt32?
    private var captionResult = false
    var hostCaptionAvailable = false
    var enhancedCaptionAvailable = false
    @Published var captionPlacement = PluginTransientCaption.Placement.nook {
        didSet { storePreference(captionPlacement.rawValue, forKey: "captionPlacement") }
    }
    var usesHostCaption: Bool { hostCaptionAvailable && (captionPlacement == .nook || enhancedCaptionAvailable) }
    var captionChanged: (() -> Void)?
    private(set) var inputLevel = 0.0
    private var levelTask: Task<Void, Never>?
    private var captionFault = false
    // Meeting admission must not consult its own occupied/paused callback.
    // Keep every local conflict here, including voice-reference work/pickers.
    var localBusy: Bool { dictationIOOutcomes.issue != nil || preloader.resourceReturnIssue != nil || fileWork.busy || referencePicker != nil || rewrite.active || rewrite.retiring || (speaker?.workerRetirementIsOwned == true) || referenceChecking || referenceSaving || referenceRecording || appPicker != nil || session.recording || waiting || preparingAssets || polishing || inserting || preloader.busy || dictationWork.busy }
    var busy: Bool { localBusy || meetingActive?() == true }
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
    init(permitsGlobalControls:Bool=true,configuration suppliedConfiguration:VoiceProductConfiguration?=nil,appearanceStore:PluginAppearanceStore?=nil,presentationAllowed:@escaping @MainActor ()->Bool={true}) {
        let configuration = suppliedConfiguration ?? .legacy
        self.configuration=configuration
        self.presentationAppearanceStore=appearanceStore;self.presentationAllowed=presentationAllowed
        self.overlay=DictationOverlay(appearanceStore:appearanceStore,presentationAllowed:presentationAllowed)
        self.microphones = configuration.allows(.discovery) ? (MicrophoneDeviceService.inputDevices()) : []
        self.microphone = preferences.string(forKey: "microphone") ?? ""
        self.locale = preferences.string(forKey: "locale") ?? "en-US"
        self.dictionary = preferences.string(forKey: "dictionary") ?? ""
        self.tone = DictationTone(rawValue: preferences.string(forKey: "dictationTone") ?? "") ?? .clean
        self.interruptionSensitivity = min(100, max(0, preferences.object(forKey: "interruptionSensitivity") as? Int ?? 50))
        self.conversationPace = ConversationPace(rawValue: preferences.string(forKey: "conversationPace") ?? "") ?? .quick
        self.dictationASR = VoiceASRProvider(rawValue: preferences.string(forKey: "dictationASRProvider") ?? "") ?? .apple
        self.parakeetReady = configuration.allows(.model) ? (LocalASREngine(.parakeet).ready) : false
        self.shortcutStyle = DictationShortcutStyle(rawValue: preferences.string(forKey: "shortcutStyle") ?? "") ?? .hold
        self.sounds = preferences.bool(forKey: "sounds")
        self.speechBackend = SpeechBackend(rawValue: preferences.string(forKey: "speechBackend") ?? "") ?? .apple
        self.qwenSpeaker = QwenSpeaker(rawValue: preferences.string(forKey: "qwenSpeaker") ?? "") ?? .ryan
        self.qwenOptions = QwenOptions.saved(preferences.data(forKey: "qwenOptions"))
        self.qwenProfiles = configuration.permitsData() ? ((try? configuration.qwenLibrary.list()) ?? []):[]
        self.qwenReady = configuration.allows(.model) ? ((try? QwenModel(mode: QwenOptions.saved(preferences.data(forKey: "qwenOptions")).mode))?.ready == true) : false
        self.voiceID = preferences.string(forKey: "voiceID") ?? ""
        self.speechDelivery = SpeechDelivery(rawValue: preferences.string(forKey: "speechDelivery") ?? "") ?? .natural
        self.selectedKey = preferences.string(forKey: "assistant") ?? ""
        self.captionPlacement = PluginTransientCaption.Placement(rawValue: preferences.string(forKey: "captionPlacement") ?? "") ?? .nook
        self.shortcut = { () -> DictationShortcut? in
        if let data = preferences.data(forKey: "dictationShortcutBinding"),
           let saved = try? JSONDecoder().decode(DictationShortcut.self, from: data), saved.valid { return saved }
        if let old = preferences.string(forKey: "shortcut") { return DictationShortcut.fromLegacy(old) }
        return .standard
        }()
        self.rewriteShortcut = { () -> DictationShortcut? in
        if preferences.bool(forKey: "rewriteShortcutOff") { return nil }
        if let data = preferences.data(forKey: "rewriteShortcutBinding"),
           let saved = try? JSONDecoder().decode(DictationShortcut.self, from: data), saved.valid, saved.trigger == .key { return saved }
        return .init(keyCode: 15, modifiers: 4096 | 2048, keyLabel: "R")
        }()
        self.pinnedAction=preferences.data(forKey:"assistantDefinition").flatMap{try? JSONDecoder().decode(PluginRegisteredAction.self,from:$0)}
        if configuration.allows(.speech){speaker=SpeechOutput()}

        dictationWork.changed = { [weak self] in self?.objectWillChange.send(); self?.changed?() }
        let admission = controlAdmission
        preloader.objectWillChange.sink { [weak self] _ in
            guard let entered=admission.enter() else{return}
            Task { @MainActor in defer{entered.finish()}; self?.changed?() }
        }.store(in: &observations)
        loadPersonalization()
        speaker?.changed = { [weak self] phase, error in
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
        objectWillChange.sink { [weak self] _ in
            guard let entered=admission.enter() else{return}
            Task { @MainActor in defer{entered.finish()}; self?.changed?() }
        }.store(in: &observations)
        hotkey.cancelled = { [weak self] in
            guard let entered=admission.enter() else{return};defer{entered.finish()}
            self?.cancel(); self?.status = "Shortcut interrupted · no text pasted"
        }
        hotkey.pressed = { [weak self] in
            guard let entered=admission.enter() else{return};defer{entered.finish()};self?.shortcutPressed()
        }
        rewriteHotkey.pressed = { [weak self] in
            guard let entered=admission.enter() else{return};defer{entered.finish()};self?.beginSelectionRewrite()
        }
        rewrite.captureGenerator = { [weak self] in
            let originalOwner = self?.rewriteFoundationOwner ?? LocalFoundationModelWork.localUser
            let configuration=self?.configuration
            return { text, operation in
                guard let configuration else{throw CancellationError()}
                try await configuration.require(.model)
                return try await LocalFoundationModelWork.$currentOwner.withValue(originalOwner) {
                    try await SelectionTransformer.transform(text, operation: operation)
                }
            }
        }
        rewrite.changed = { [weak self] in
            guard let self else { return }
            if !self.rewrite.active { self.rewriteWindow?.hide() }
            self.objectWillChange.send(); self.changed?()
        }
        hotkey.released = { [weak self] in
            guard let entered=admission.enter() else{return};defer{entered.finish()}
            guard let self else { return }
            if self.shortcutState.release(style: self.shortcutStyle) == .stop { self.stopRecording() }
        }
        accessibilityAllowed = configuration.allows(.accessibility) ? insertion.permitted:false
        if permitsGlobalControls && configuration.allows(.globalControls) && !CommandLine.arguments.contains("--protocol-test") {
            configureHotkey()
            Task { [weak self] in self?.languages = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.sorted() }
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    guard let entered=admission.enter() else{return}
                    Task { @MainActor in defer{entered.finish()};self?.cancel();self?.speaker?.shutdown();self?.status = "Stopped for sleep or screen lock" }
                })
            }
        }
        if configuration.isolated{status=configuration.reason}
    }
    private func shortcutPressed() {
        guard allowProductEffect(.globalControls) else{return}
        guard serviceAllowsActivity() else { return }
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
    private func finishDictation(into target: DictationInsertion.Target,owner:VoiceFoundationOwner) {
        self.target = nil; dictating = false; inserting = true
        status = "Pasting into \(target.name)…"
        let text = session.transcript; let historyID = recordingHistoryID; let generation = UUID(); insertionGeneration = generation
        insertionFileOwner=owner
        insertionWork = Task { [self] in
            defer { inserting = false }
            do {
                try await insertion.insert(text, into: target)
                guard generation == insertionGeneration else { return }
                setHistoryOutcome(historyID,value:"Paste sent",owner:owner)
                status = "Paste sent to \(target.name)"
                captionResult = true
                scheduleOverlayDismissal(after: 5)
            } catch {
                guard generation == insertionGeneration else { return }
                setHistoryOutcome(historyID,value:"Paste failed",owner:owner)
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
    func requestInsertionPermission() { guard allowProductEffect(.accessibility) else{return};insertion.requestPermission(); accessibilityAllowed = configuration.allows(.accessibility) ? insertion.permitted:false }
    func dismissOverlay() { if session.recording || inserting { cancel() }; overlayCompletion?.cancel(); overlay.hide() }
    var shortcutName: String { shortcut?.displayName ?? "Off" }
    func configureHotkey() {
        guard allowProductEffect(.globalControls) else{return}
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
        guard presentationAllowed(),originalPresentationRetirement == nil else{return}
        guard allowProductEffect(.accessibility) else{return}
        guard serviceAllowsActivity() else { return }
        if rewrite.active { rewriteWindow?.show(); return }
        guard !busy, !speaking else { status = "Finish the current Voice activity before Rewrite."; changed?(); return }
        do {
            rewriteFoundationOwner = LocalFoundationModelWork.currentOwner
            try rewrite.begin() // Capture BEFORE bringing the review window forward.
            if rewriteWindow == nil{rewriteWindow=SelectionRewriteWindow(model:rewrite,appearanceStore:presentationAppearanceStore,presentationAllowed:presentationAllowed)}
            rewriteWindow?.show()
        } catch { status = error.localizedDescription; changed?() }
    }
    func chooseRewriteShortcut(_ candidate: DictationShortcut?) {
        guard !busy else { return }
        guard candidate == nil || (candidate!.valid && candidate!.trigger == .key && !(shortcut.map { candidate!.sameBinding(as: $0) } ?? false)) else {
            status = "Use a key combination different from dictation for Rewrite."; configureHotkey(); return
        }
        do {
            if configuration.allows(.globalControls){try rewriteHotkey.configure(candidate)}
            rewriteShortcut = candidate
            storePreference(candidate == nil, forKey: "rewriteShortcutOff")
            storePreference(candidate.flatMap { try? JSONEncoder().encode($0) }, forKey: "rewriteShortcutBinding")
            configureHotkey(); status = candidate.map { "Rewrite shortcut set to \($0.displayName)" } ?? "Rewrite shortcut off"
        } catch { configureHotkey(); status = error.localizedDescription }
    }
    func chooseShortcut(_ candidate: DictationShortcut?) {
        guard !busy else { return }
        guard candidate == nil || !(rewriteShortcut.map { candidate!.sameBinding(as: $0) } ?? false) else { status = "Choose different shortcuts for dictation and Rewrite."; configureHotkey(); return }
        guard candidate?.valid ?? true else { status = "Choose Fn, modifiers, a key combination or an F-key."; configureHotkey(); return }
        do {
            if configuration.allows(.globalControls){try hotkey.configure(candidate)}
            shortcut = candidate
            storePreference(candidate.flatMap { try? JSONEncoder().encode($0) }, forKey: "dictationShortcutBinding")
            storePreference(candidate == nil ? "Off" : "Custom", forKey: "shortcut")
            configureHotkey()
            status = candidate.map { "Dictation shortcut set to \($0.displayName)" } ?? "Dictation shortcut off"
        } catch {
            configureHotkey()
            status = error.localizedDescription
        }
    }
    func refreshDevices() { guard allowProductEffect(.discovery) else{return};microphones = MicrophoneDeviceService.inputDevices() }
    func prepareConversation() {
        guard serviceAllowsActivity() else { return }
        guard !busy, !speaking, selectedModelReady else { return }
        preparingAssets = true
        let generation = UUID(); assetGeneration = generation
        let provider = dictationASR, language = locale
        assetTask = Task { [self] in
            guard !Task.isCancelled else{return}
            do { try await preloader.prepare(provider: provider, locale: language, helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroASR")) }
            catch { if generation == assetGeneration, !Task.isCancelled { status = error.localizedDescription } }
            if generation == assetGeneration { preparingAssets = false; assetTask = nil; changed?() }
        }
    }
    func releasePreparedSpeech() {
        guard !preparingAssets || preloader.preparing else { return }
        let original=assetTask
        assetCallbacks[assetGeneration]?.gate.seal()
        assetGeneration=UUID();assetTask=nil;original?.cancel();preparingAssets=false
        preloader.release();changed?()
    }
    func prepareAssets() {
        guard serviceAllowsActivity() else { return }
        guard !busy else { return }; preparingAssets = true; status = "Preparing Apple Speech language…"
        let generation = UUID(); assetGeneration = generation; let language = locale
        assetTask = Task { [self] in
            guard !Task.isCancelled else{return}
            do { _ = try await SpeechPipeline.prepare(localeIdentifier: language, install: true); try Task.checkCancellation(); guard generation == assetGeneration else { return }; status = "Language ready · audio stays on this Mac" }
            catch { if !Task.isCancelled, generation == assetGeneration { status = error.localizedDescription } }
            if generation == assetGeneration { preparingAssets = false; assetTask = nil }
        }
    }
    func prepareLocalModel() {
        guard serviceAllowsActivity() else { return }
        guard !busy else { return }
        guard dictationASR != .apple else { prepareAssets(); return }
        preloader.release()
        let engine = LocalASREngine(dictationASR)
        preparingAssets = true; status = "Preparing \(engine.name) · 756 MB download…"
        let generation = UUID(); assetGeneration = generation
        assetTask = Task { [self] in
            guard !Task.isCancelled else{return}
            do {
                try await engine.prepare()
                try Task.checkCancellation()
                guard generation == assetGeneration else { return }
                status = "\(engine.name) ready for dictation and meetings"
            } catch {
                if !Task.isCancelled, generation == assetGeneration { status = error.localizedDescription }
            }
            if generation == assetGeneration {
                parakeetReady = (try? fileWork.operation(owner:LocalFoundationModelWork.currentOwner){LocalASREngine(.parakeet).ready}) ?? false
                preparingAssets = false; assetTask = nil
            }
        }
    }
    func record() {
        guard serviceAllowsActivity() else { return }
        guard !busy else { return }; target = nil; dictating = false; captionVisible = false; beginRecording()
    }
    private func beginRecording() {
        guard allowProductEffect(.capture) else{return}
        guard !busy else { return }
        let originalFoundationOwner = LocalFoundationModelWork.currentOwner
        var token: UUID?
        var originalPreloadRetirement: Task<Void, Never>?
        var originalRecognizerRetirement: Task<Void, Never>?
        dictationWork.start(prepare: { [self] original in
            // Reserve the actual work before @Published/audio/caption callouts.
            // Preparation remains synchronous so an immediate hotkey release
            // sees .preparing and cancels this same original task.
            let admittedToken = session.begin(); token = admittedToken
            recordingFoundationAdmission = VoiceFoundationAdmission(sessionID: admittedToken, owner: originalFoundationOwner)
            recordingFileAdmission=(admittedToken,originalFoundationOwner)
            guard !original.isCancelled else { session.cancel(); return }
            let current = { !original.isCancelled && self.session.token == token }
            preloader.release()
            guard current() else { return }
            originalPreloadRetirement = preloader.retirementCompletion()
            originalRecognizerRetirement = MeetingLiveTranscriber.pendingRetirementCompletion()
            recordingAppID = target?.appID ?? ""; recordingAppName = target?.name ?? "Nero Voice draft"
            recordingTone = personalization.tone(for: target?.appID, fallback: tone)
            recordingTerms = dictionary; recordingSnippets = personalization.snippets
            historyTicket = personalization.historyEnabled && !historyFault ? historyEpoch : nil; recordingHistoryID = nil
            stopSpeaking()
            guard current() else { return }
            stopLevelMeter()
            guard current() else { return }
            captionFault = false; reply = ""
            guard current() else { return }
            overlayText = nil
            guard current() else { return }
            revision = UUID()
            guard current() else { return }
            status = "Preparing microphone…"
            guard current() else { return }
            if !selectedModelReady {
                cancel(); status = "Prepare the selected model on the Voice card before dictating."
                return
            }
            let preparedToken = token
            deadline?.cancel(); deadline = Task { [weak self] in try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled, self?.session.token == preparedToken, self?.session.phase == .preparing else { return }; self?.cancel(); self?.status = "Microphone preparation timed out. Try Record again." }
        }) { [self] in
            guard let token, session.token == token else { return }
            do {
                await originalPreloadRetirement?.value
                await originalRecognizerRetirement?.value
                try Task.checkCancellation(); guard session.token == token else { return }
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
                        try Task.checkCancellation(); guard self.session.token == token else { throw CancellationError() }
                        let stream = try LocalDictationStream(); self.localStream = stream
                        do {
                            try await stream.start(helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroASR"))
                            try Task.checkCancellation(); guard self.session.token == token else { throw CancellationError() }
                            return stream
                        } catch {
                            stream.cancel()
                            let joined=self.dictationIOOutcomes.join(stream.retirementCompletion(),issue:{stream.resourceReturnIssue})
                            await joined?.value;throw error
                        }
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
    private func stopLevelMeter() {
        let original=levelTask;levelTask=nil;retainControlJob(original);original?.cancel()
        inputLevel=0;captionChanged?()
    }
    func stopRecording() {
        if session.phase == .preparing {
            cancel(); status = "Released before the microphone was ready. Hold again and speak when REC appears."; return
        }
        stopLevelMeter()
        let token = session.token
        guard session.finishing(token), let pipeline else { return }
        guard let originalFoundationAdmission = recordingFoundationAdmission,
              originalFoundationAdmission.sessionID == token,let originalFileAdmission=recordingFileAdmission,
              originalFileAdmission.sessionID == token else {
            fail("Dictation ownership changed before finalization.", token: token); return
        }
        deadline?.cancel(); status = dictationASR == .parakeet ? "Transcribing with local Parakeet…" : "Finishing your last words…"
        let selectedProvider = dictationASR
        deadline = Task { [weak self] in try? await Task.sleep(for: .seconds(selectedProvider != .apple ? 60 : 12)); guard !Task.isCancelled, self?.session.token == token else { return }; self?.cancel(); self?.status = "Speech finalization timed out. Review the partial text before using it." }
        dictationWork.start { [self] in
            do {
                let appleText = try await pipeline.finish()
                let text: String
                if selectedProvider == .nemotron {
                    guard let pcm = pipeline.capturedAudio, let ready = localReady else { throw VoiceProblem.message("No local audio was captured.") }
                    let stream = try await ready.value
                    try Task.checkCancellation(); guard session.token == token else { return }
                    text = try await stream.finish(pcm)
                    let joined=dictationIOOutcomes.join(stream.retirementCompletion(),issue:{stream.resourceReturnIssue})
                    await joined?.value
                    try Task.checkCancellation(); guard session.token == token else { return }
                    localStream = nil; localReady = nil
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
                let polish = originalFoundationAdmission.detached {
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
                recordingHistoryID = saveDictationHistory(raw: text, text: cleaned, tone: selectedTone, appID: recordingAppID, appName: recordingAppName, recognizer: selectedProvider.rawValue, ticket: historyTicket,owner:originalFileAdmission.owner)
                overlayText = cleaned; polishing = false; revision = UUID(); shortcutState.reset()
                status = "Review your transcript · nothing sent"
                if dictating, let target { finishDictation(into:target,owner:originalFileAdmission.owner) }
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
        guard !cancellingDictation else { return }
        cancellingDictation = true
        defer { cancellingDictation = false }
        let alreadyDraining = dictationWork.draining
        dictationWork.cancel { [self] in
            // Clear captured references and invalidate the session before any
            // callback-bearing UI/audio cancellation. The owner is already busy.
            let originalReady = localReady; localReady = nil
            let originalStream = localStream; localStream = nil
            let originalPipeline = pipeline; pipeline = nil
            let originalAssets = assetTask; assetTask = nil;assetCallbacks[assetGeneration]?.gate.seal(); assetGeneration = UUID()
            session.cancel(); recordingFoundationAdmission = nil;recordingFileAdmission=nil; revision = UUID(); historyTicket = nil
            originalReady?.cancel(); originalAssets?.cancel()
            originalStream?.cancel(); originalPipeline?.cancel()
            var resources = [Task<Void, Never>]()
            if let original=dictationIOOutcomes.join(originalStream?.retirementCompletion(),issue:{[originalStream] in originalStream?.resourceReturnIssue}){resources.append(original)}
            if let original = originalPipeline?.retirementCompletion() { resources.append(original) }
            if let originalReady{resources.append(Task{[self] in
                if let stream=try? await originalReady.value{
                    stream.cancel();let joined=dictationIOOutcomes.join(stream.retirementCompletion(),issue:{stream.resourceReturnIssue});await joined?.value
                }
            })}
            if let originalAssets { resources.append(Task { await originalAssets.value }) }
            rewrite.close(); cancelReference()
            let output = speaker?.shutdown()
            preloader.release()
            // A repeated Cancel sees the same pending global output/preload
            // handles; the existing owner already retains them.
            if !alreadyDraining {
                if let output { resources.append(output) }
                if let preload=preloader.retirementCompletion(){
                    resources.append(dictationIOOutcomes.join(preload,issue:{[preloader] in preloader.resourceReturnIssue}) ?? preload)
                }
            }
            stopLevelMeter(); captionFault = false
            cancelStyleAppPicker()
            draftPersonalizationWorker?.cancel(); draftPersonalizationTask?.cancel(); draftPersonalizationWorker = nil; draftPersonalizationTask = nil
            stopMeetingPlayback?()
            shortcutState.reset(); target = nil; dictating = false
            insertionGeneration = UUID(); insertionWork?.cancel(); overlayCompletion?.cancel(); overlayText = nil
            polishWork?.cancel(); polishWork = nil
            captionVisible = false; captionResult = false; polishing = false
            // An already sent paste cannot be recalled; keep its clipboard lease.
            let originalDeadline=deadline;deadline=nil;retainControlJob(originalDeadline);originalDeadline?.cancel();preparingAssets=false
            if let request=outgoing {
                outgoing=nil;outgoingEntry=nil;waiting=false
                if let handle=providerHandles[request] { do { try handle.cancel() } catch { providerOutcomes[request]="cancel-enqueue-failed" } }
                else { cancelInvocation?(request) }
                settleProvider(request, originalTask:originalDeadline)
            }
            stopSpeaking(); status = "Stopped · review any partial text"; changed?()
            return resources
        }
    }
    func edit(_ text: String) { guard !busy else { return }; do { try session.edit(text); revision = UUID() } catch { status = error.localizedDescription } }
    func restore() { guard !busy else { return }; session.restore(); revision = UUID(); status = "Original transcript restored" }
    func applyDictionary() {
        guard !busy else { return }
        do { try session.edit(VoiceDictionary.apply(session.transcript, terms: dictionary)); revision = UUID(); status = "Spellings applied · review before use" } catch { status = error.localizedDescription }
    }
    func clear() { guard !busy else { return }; stopSpeaking(); session.clear(); reply = ""; revision = UUID(); status = "Ready to record" }
    func submit(_ values: [String: PluginValue]) throws {
        try configuration.require(.provider)
        guard !busy else { throw VoiceProblem.message("Stop the current recording or request first.") }
        let (text, ask, read) = try VoiceContract.validate(values)
        if ask {
            guard let assistant, let invoke else { throw VoiceProblem.message("Allow a text assistant in Nook Settings → Modules, then choose it in Voice Settings.") }
            try assistant.action!.input.validate(["prompt": .string(text)])
            let request=UUID(),original=captureProviderRequest?(request)
            if captureProviderRequest != nil && original == nil { throw VoiceProblem.message("The original provider connection is unavailable or busy.") }
            if let original { providerHandles[request]=original }
            do {
                try session.edit(text); reply = ""; stopSpeaking(); waiting = true; readReply = read
                outgoing = request; outgoingEntry = assistant; status = "Asking \(assistant.action!.title)…"
                if let original { try original.invoke(address:assistant.address,values:["prompt":.string(text)]) }
                else { invoke(request, assistant.address, ["prompt": .string(text)]) }
                deadline?.cancel(); deadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(185))
                    guard !Task.isCancelled,self?.outgoing == request else{return}
                    self?.cancel();self?.status="Assistant timed out"
                }
            } catch {
                outgoing=nil;outgoingEntry=nil;waiting=false
                settleProvider(request)
                throw error
            }
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
            let originalTimer=deadline;deadline=nil;originalTimer?.cancel()
            outgoing = nil; outgoingEntry = nil; waiting = false
            settleProvider(request, originalTask:originalTimer)
            if update.phase == .succeeded {
                guard (try? entry.action!.output.validate(update.values)) != nil, case .string(let text) = update.values["reply"] else { status = "Assistant returned an invalid reply"; return }
                reply = text; status = "Reply ready"; if readReply { speak() }
            } else { status = update.message.isEmpty ? "Assistant request stopped" : update.message }
        }
    }
    /// Local callbacks are closed synchronously before this joins the exact timer
    /// and original writer. A remote provider may still have performed an effect.
    private func settleProvider(_ request:UUID,originalTask:Task<Void,Never>?=nil){
        guard providerSettlements[request]==nil,let handle=providerHandles[request] else{return}
        let task=Task { [self,handle] in
            await originalTask?.value
            await handle.retire()
            providerOutcomes[request]=handle.writeIssue ?? providerOutcomes[request] ?? "effect-uncertain"
            providerHandles[request]=nil
        }
        providerSettlements[request]=task
    }
    func retireProviderRequests(_ requests:Set<UUID>)async->VoiceResourceRelease{
        var missing=false
        for request in requests {
            if outgoing == request {
                outgoing=nil;outgoingEntry=nil;waiting=false
                let originalTimer=deadline;deadline=nil;originalTimer?.cancel()
                if let handle=providerHandles[request] { do{try handle.cancel()}catch{providerOutcomes[request]="cancel-enqueue-failed"} }
                else { missing=true }
                settleProvider(request,originalTask:originalTimer)
            }
            if let original=providerSettlements[request] { await original.value }
            else if let handle=providerHandles[request] { await handle.retire();providerOutcomes[request]=handle.writeIssue ?? "effect-uncertain";providerHandles[request]=nil }
            else if providerOutcomes[request]==nil { missing=true }
        }
        return missing ? .unknown("dictation-provider-original-missing") : .released(.effectUncertain)
    }
    /// Called only by the original context's sealed history after its exact-ID
    /// retirement returned. Recheck the actual slots after every original join;
    /// missing/unknown or active entries stay retained, never pruned as clean.
    func pruneProviderRequests(_ requests:Set<UUID>)async->VoiceResourceRelease{
        let originals=requests.compactMap{providerSettlements[$0]}
        for original in originals{await original.value}
        guard requests.allSatisfy({outgoing != $0 && providerHandles[$0] == nil && providerOutcomes[$0] != nil}) else{
            return .unknown("dictation-provider-prune-original-unreturned")
        }
        for request in requests{providerSettlements[request]=nil;providerOutcomes[request]=nil}
        return .released(.effectUncertain)
    }
    func speak() {
        speakText(reply)
    }
    func renderSpeech(_ text: String) throws {
        try configuration.require(.speech)
        try serviceBeginLocal?()
        speechFileOwner=LocalFoundationModelWork.currentOwner
        try speaker?.speak(text, backend: speechBackend, voiceID: voiceID, appleVoice: selectedSpeechVoice,
                          qwenSpeaker: qwenSpeaker, locale: locale, delivery: speechDelivery, qwenOptions: qwenOptions)
    }
    func speakText(_ text: String) {
        guard !busy, !CommandLine.arguments.contains("--protocol-test") else { return }
        do { try renderSpeech(text) } catch { status = error.localizedDescription; changed?() }
    }
    func speakShared(_ text: String,reactionID requestedID:UUID?=nil) throws {
        try configuration.require(.speech)
        try serviceBeginLocal?()
        guard !busy, !speaking, meetingActive?() != true, !CommandLine.arguments.contains("--protocol-test") else { throw VoiceProblem.message("Voice is busy. Finish the current activity first.") }
        speechFileOwner=LocalFoundationModelWork.currentOwner
        let reaction=PluginAvatarReaction.allCases.first{$0.hasAudio && $0.spokenText == text}
        startingReaction=reaction != nil;defer{startingReaction=false}
        if let reaction {
            reactionKind=reaction;reactionID=requestedID ?? UUID()
            let output=ConversationAudio();try output.startOutput();reactionOutput=output;speaker?.engineOutput=output
        }
        do {
            if reaction != nil {
                var options=qwenOptions
                if speechBackend == .qwen,options.mode == .preset {
                    let cue="Speak playfully with a happy smiling voice and light natural giggles. Keep the words clear."
                    if options.instruction.utf8.count+cue.utf8.count+1<=512 {options.instruction += (options.instruction.isEmpty ? "":" ")+cue}
                }
                try speaker?.speak(text,backend:speechBackend,voiceID:voiceID,appleVoice:selectedSpeechVoice,qwenSpeaker:qwenSpeaker,locale:locale,delivery:speechDelivery,qwenOptions:options)
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
    func releaseSpeakingModel() { speaker?.shutdown(); status = "Speaking model released · downloaded files retained"; changed?() }
    func prepareQwen() {
        guard serviceAllowsActivity() else { return }
        guard !busy, !speaking, !CommandLine.arguments.contains("--protocol-test") else { return }
        let owner=LocalFoundationModelWork.currentOwner;speechFileOwner=owner
        preloader.release(); preparingAssets = true; let id = UUID(); assetGeneration = id
        status = "Preparing Qwen · download once, all speech stays local…"; changed?()
        guard fileWork.permits(owner),assetGeneration == id else{preparingAssets=false;return}
        let callbacks=VoiceAudioCallbackAdmission()
        assetCallbacks[id]=(owner,callbacks);fileWork.retainCallbacks(callbacks,owner:owner)
        assetTask = Task { [weak self] in
            defer{callbacks.seal();callbacks.nativeStopReturned();self?.assetCallbacks[id]=nil}
            guard !Task.isCancelled else{return}
            guard let self else { return }
            do {
                let model = try QwenModel(mode: qwenOptions.mode)
                try await model.download { [weak self] done,total in
                    guard let entered=callbacks.enter()else{return}
                    Task{@MainActor in
                        defer{entered.finish()}
                        guard let self,self.assetGeneration == id,self.preparingAssets,self.fileWork.permits(owner)else{return}
                        self.status="Preparing Qwen · file \(done) of \(total)";self.changed?()
                    }
                }
                try Task.checkCancellation(); guard assetGeneration == id else { return }
                try await speaker?.prepareQwen(mode: qwenOptions.mode); try Task.checkCancellation(); guard assetGeneration == id else { return }
                qwenReady = true; status = "Qwen ready · microphone off · releases after 60 idle seconds"
            } catch { if assetGeneration == id { status = error.localizedDescription } }
            guard assetGeneration == id else { return }; preparingAssets = false; assetTask = nil; changed?()
        }
    }
    func readDraft() { speakText(session.transcript) }
    func previewSpeech() { speakText("Welcome back. We have time to review your notes, or we can pick up right where we left off. What would you like to do?") }
    func stopSpeaking() { speaker?.stop(); clearReaction(); speaking = false }
    func refreshSpeechState() {
        if Date().timeIntervalSince(historyLastRefresh) > 60 && !busy { refreshHistory() }
        accessibilityAllowed = configuration.allows(.accessibility) ? insertion.permitted:false
        if session.phase == .listening, let error = pipeline?.inputError { fail(error, token: session.token); return }
        if session.phase == .listening, let signal = pipeline?.inputSignal {
            if signal.age > 3 { fail("The microphone stopped delivering audio. Choose a microphone in Voice settings and try again.", token: session.token); return }
            let device = microphones.first { microphone.isEmpty ? $0.isDefault : $0.id == microphone }?.name ?? "Microphone"
            status = "\(dictationASR == .parakeet ? "Listening with Parakeet" : "Listening") · \(device) · input \(Int(signal.level * 100))%"
        }
    }
    /// Own API/callback/file returns only. Apple brokers and other apps are not
    /// part of this receipt; returned operation/cleanup failures stay failed.
    func sharedFileRetirement(owner:VoiceFoundationOwner?)async->VoiceResourceRelease{
        fileWork.close(owner)
        for entry in assetCallbacks.values where owner == nil || entry.owner == owner{entry.gate.seal()}
        let consumerOwner=speechFileOwner
        let consumer=(owner == nil || owner == consumerOwner) ? captureReferenceConsumer():nil
        if owner == nil || appPickerOwner == owner{cancelStyleAppPicker()}
        if owner == nil || historyEraseOwner == owner,let alert=historyEraseAlert{
            if NSApp.modalWindow === alert.window{NSApp.abortModal();alert.window.orderOut(nil)}
        }
        if owner == nil || referencePickerOwner == owner{
            let panel=referencePicker,callback=referencePickerCallback
            referencePicker=nil;referencePickerCallback=nil
            callback?.close{panel?.cancel(nil)}
        }
        if owner == nil || referenceOwner == owner{
            cancelReference();discardReferenceSource()
        }
        await consumer?.completion?.value
        if let issue=consumer?.issue(){fileWork.recordUnknown(consumerOwner,issue:issue)}
        await fileWork.wait(owner)
        return fileWork.release(owner)
    }
    func sharedDictationRetirement() async ->Bool{
        let originalInsertion = insertionWork, originalPolish = polishWork
        let originalPersonalization = draftPersonalizationTask
        let originalPersonalizationWorker = draftPersonalizationWorker
        cancel()
        let originalDictation = dictationWork.retirementCompletion()
        let controls=Array(originalControlJobs.values)
        await originalDictation?.value
        for original in controls { await original.value }
        await originalInsertion?.value
        _ = try? await originalPolish?.value
        await originalPersonalization?.value
        _ = await originalPersonalizationWorker?.value
        return dictationIOOutcomes.issue == nil && preloader.resourceReturnIssue == nil
    }
    func sharedSpeechRetirement() async -> Bool {
        let original = speaker?.ownedShutdown()
        clearReaction()
        let originalOutputs = Array(originalReactionReturns.values), controls=Array(originalControlJobs.values)
        await original?.completion?.value
        for control in controls { await control.value }
        for output in originalOutputs { await output.value }
        return original?.issue == nil
    }
    func sharedEditingRetirement() async {
        rewrite.close()
        let original = rewrite.retirementCompletion()
        await original?.value
    }
    func sealPresentationForRetirement()->Task<Bool,Never>{
        if let originalPresentationRetirement{return originalPresentationRetirement}
        let returns=VoicePresentationReturns()
        let original=Task {await returns.result()};originalPresentationRetirement=original
        let overlayOriginal=overlay.sealPresentationForRetirement()
        let rewriteOriginal=rewriteWindow?.sealForRetirement()
        returns.install(Task {let a=await overlayOriginal.value;let b=await rewriteOriginal?.value ?? true;return a && b})
        return original
    }
    func shutdownControlCallbacks() -> Task<Void, Never> {
        if let originalControlShutdown{return originalControlShutdown}
        let admission=controlAdmission
        admission.seal()
        let originals=Array(originalControlJobs.values)
        let presentationOriginal=sealPresentationForRetirement()
        let overlayOriginal=overlayCompletion;overlayCompletion=nil;overlayOriginal?.cancel()
        let original=Task {
            for job in originals{await job.value}
            await overlayOriginal?.value
            _ = await presentationOriginal.value
            await admission.waitForReturn()
        }
        originalControlShutdown=original
        hotkey.stop();rewriteHotkey.stop()
        lifecycleObservers.forEach{NSWorkspace.shared.notificationCenter.removeObserver($0)};lifecycleObservers.removeAll()
        observations.removeAll();overlay.hide();rewriteWindow?.hide()
        admission.nativeStopReturned()
        return original
    }
    func shutdown() { _=shutdownControlCallbacks();cancel(); discardReferenceSource(); speaker?.shutdown(); insertion.shutdown(); overlay.hide(); hotkey.stop(); rewriteHotkey.stop(); lifecycleObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
}
