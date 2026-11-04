import AppKit
import AVFoundation
import Combine
import ModuleCore
import VoiceAudio
import NookPluginSDK

// Holds the actual work, even when a visible slot is reset or replaced. A
// context is sealed synchronously before its originals are cancelled.
@MainActor final class MeetingOwnedTasks {
    private struct Entry { let owner: VoiceFoundationOwner; let task: Task<Void, Never> }
    private var originals: [UUID: Entry] = [:]
    private var sealedOwners: Set<VoiceFoundationOwner> = []
    private var sealed = false
    func permits(_ owner: VoiceFoundationOwner) -> Bool { !sealed && !sealedOwners.contains(owner) }
    func retain(_ task: Task<Void, Never>, owner: VoiceFoundationOwner) {
        let id = UUID(); originals[id] = Entry(owner: owner, task: task)
        if !permits(owner) { task.cancel() }
        Task { @MainActor [weak self] in await task.value; self?.originals[id] = nil }
    }
    func waitForReturn(_ owner: VoiceFoundationOwner?) async {
        while true {
            let current = originals.values.filter { owner == nil || $0.owner == owner }.map(\.task)
            if current.isEmpty { return }
            for task in current { await task.value }
            await Task.yield() // let retained completion observers remove entries
        }
    }
    func close(_ owner: VoiceFoundationOwner?) -> [Task<Void, Never>] {
        if let owner { sealedOwners.insert(owner) } else { sealed = true }
        let captured = originals.values.filter { owner == nil || $0.owner == owner }.map(\.task)
        captured.forEach { $0.cancel() }
        return captured
    }
}

// A synchronous/modal caller signals only after its original callback and
// any accepted file operation have actually returned. Cancellation of the
// waiter cannot manufacture that return.
@MainActor final class MeetingFileCompletion {
    private var returned = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func finish() {
        guard !returned else { return }; returned = true
        let originals = waiters; waiters.removeAll(); originals.forEach { $0.resume() }
    }
    func wait() async {
        if returned { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

// The original panel completion is reserved before begin. Its lease lives
// through the actual callback and any queued MainActor delivery, even if stop
// comes first. A missing native completion cannot become a released receipt.
final class MeetingFilePanelCompletion: @unchecked Sendable {
    private let admission: VoiceAudioCallbackAdmission
    private let original: VoiceAudioCallbackLease
    private let lock = NSLock()
    private var delivered = false
    private var beginning = false
    private var closed = false
    init() {
        let admission = VoiceAudioCallbackAdmission()
        self.admission = admission; self.original = admission.enter()!
    }
    // Called immediately before panel.begin, after the last reentrant UI
    // callout. There is no native callback until this returns true.
    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !delivered, !beginning else { return false }
        beginning = true; return true
    }
    func deliver(_ operation: @escaping @MainActor () async -> Void) {
        lock.lock()
        guard !delivered else { lock.unlock(); return }
        delivered = true; lock.unlock()
        let original = original
        Task { @MainActor in defer { original.finish() }; await operation() }
    }
    func seal() {
        lock.lock(); closed = true
        let neverBegan = !beginning && !delivered
        if neverBegan { delivered = true }
        lock.unlock()
        admission.seal()
        // If begin was never invoked, there is no native callback to wait for.
        if neverBegan { original.finish() }
    }
    func nativeStopReturned() { admission.nativeStopReturned() }
    func waitForReturn() async { await admission.waitForReturn() }
}

enum MeetingProviderCapacity {
    static func permits(live: Int, recorded: Int) -> Bool {
        live >= 0 && recorded >= 0 && live < 32 && recorded < 4096 && live < 4096 - recorded
    }
}

// One global owner for the original observer/timer callbacks and their
// derived MainActor deliveries. Native source removal and delivery return are
// separate required events; this never certifies outside-process quiet.
@MainActor final class MeetingNativeObserverOwner {
    let admission = VoiceAudioCallbackAdmission()
    private(set) var closing = false
    func seal() { closing = true; admission.seal() }
    func sourceStopsReturned() { admission.nativeStopReturned() }
    func waitForReturn() async { await admission.waitForReturn() }
}

// Reserved before recording callouts; late construction remains on this exact
// attempt even if Stop reenters while a synchronous native call is in flight.
@MainActor final class MeetingRecordingAttempt {
    let owner: VoiceFoundationOwner
    let generation = UUID()
    var meeting: Meeting?
    var writer: MeetingAudioWriter?
    var capture: MeetingCapture?
    var startScheduled = false
    var startReturned = false
    var captureAdmissionAttempted = false
    var sealed = false
    init(owner: VoiceFoundationOwner, meeting: Meeting? = nil) { self.owner = owner; self.meeting = meeting }
}

@MainActor final class MeetingModel: ObservableObject {
    var transcriptionPresentation=MeetingTranscriptionPresentation()
    var transcriptionSearchPending=Set<UUID>()
    var transcriptionSearchRecovery=Set<UUID>()
    let configuration:VoiceProductConfiguration
    var hasAmbientProductObservers:Bool{timer != nil || !lifecycle.isEmpty || termination != nil}
    var preferences:VoiceProductPreferences { configuration.preferences }
    @discardableResult func allowProductEffect(_ effect:VoiceProductConfiguration.Effect)->Bool {
        guard configuration.admit(effect) else{status=configuration.reason;return false};return true
    }
    func storeMeetingPreference(_ value:Any?,forKey key:String){
        guard permitMeetingWork()else{return}
        preferences.set(value,forKey:key)
        if let issue=preferences.issue{meetingFileUnknown[LocalFoundationModelWork.currentOwner]=issue;status=issue}
    }
    let ownedMeetingTasks = MeetingOwnedTasks()
    let meetingFileTasks = MeetingOwnedTasks()
    var meetingFileUncertain: Set<VoiceFoundationOwner> = []
    var meetingFileUnknown: [VoiceFoundationOwner: String] = [:]
    var pendingMeetingProviders: [UUID: VoiceFoundationOwner] = [:]
    var capturedMeetingProviders: [UUID: (owner: VoiceFoundationOwner, request: VoiceOwnedProviderRequest)] = [:]
    // A local write return is distinct from the external provider's outcome.
    // Keep request-scoped local status after the original output handle returns.
    var providerWriteOutcomes: [UUID: (owner: VoiceFoundationOwner, issue: String?)] = [:]
    var providerCancelIssues: [UUID: String] = [:]
    var providerEffectUncertain: Set<VoiceFoundationOwner> = []
    var settlingMeetingProviders: Set<UUID> = []
    var providerSettlementTasks: [UUID: Task<Void, Never>] = [:]
    // 32 concurrent originals and 4096 retained outcomes are ceilings, not
    // future work queues. Full native-context admission also enforces its own
    // shared run limits; refusing here never drops a retained original.
    func permitsMeetingProvider() -> Bool {
        MeetingProviderCapacity.permits(live: capturedMeetingProviders.count, recorded: providerWriteOutcomes.count)
    }
    func settleMeetingProvider(_ request: UUID, originalTask: Task<Void, Never>? = nil) {
        pendingMeetingProviders[request] = nil
        guard let original = capturedMeetingProviders[request],
              settlingMeetingProviders.insert(request).inserted else { return }
        let task = Task { @MainActor [weak self] in
            await originalTask?.value
            await original.request.retire()
            guard let self else { return }
            guard self.capturedMeetingProviders[request] != nil else {
                self.settlingMeetingProviders.remove(request); self.providerSettlementTasks[request] = nil; return
            }
            self.providerWriteOutcomes[request] = (original.owner,
                self.providerCancelIssues.removeValue(forKey: request) ?? original.request.writeIssue)
            self.capturedMeetingProviders[request] = nil
            self.settlingMeetingProviders.remove(request); self.providerSettlementTasks[request] = nil
        }
        providerSettlementTasks[request] = task
        retainMeetingTask(task, owner: original.owner)
    }
    var captureProviderRequest: ((UUID) -> VoiceOwnedProviderRequest?)?
    var meetingUnverified: [VoiceFoundationOwner: Set<String>] = [:]
    func markMeetingUnverified(_ reason: String, owner: VoiceFoundationOwner) {
        meetingUnverified[owner, default: []].insert(reason)
    }
    func resolveMeetingUnverified(_ reason: String, owner: VoiceFoundationOwner) {
        meetingUnverified[owner]?.remove(reason)
        if meetingUnverified[owner]?.isEmpty == true { meetingUnverified[owner] = nil }
    }
    func permitMeetingWork() -> Bool {
        let owner = LocalFoundationModelWork.currentOwner
        return configuration.permitsData() && ownedMeetingTasks.permits(owner) && meetingFileTasks.permits(owner)
    }
    func retainMeetingTask(_ task: Task<Void, Never>?, owner: VoiceFoundationOwner) {
        if let task { ownedMeetingTasks.retain(task, owner: owner); meetingFileTasks.retain(task, owner: owner) }
    }
    var serviceBeginLocal: (() throws -> Void)?
    private func serviceAllowsActivity() -> Bool {
        guard allowProductEffect(.capture) else{return false}
        do { try serviceBeginLocal?(); return true }
        catch { status = error.localizedDescription; changed?(); return false }
    }
    @Published var organization = MeetingOrganization()
    @Published var folderScope = "all"
    @Published var organizationStatus = ""
    @Published var organizationFailed = false
    @Published var choosingImport = false
    var importPicker: NSOpenPanel?
    var importPickerOwner: VoiceFoundationOwner?
    var importPickerAdmission: MeetingFilePanelCompletion?
    var exportPanel: NSSavePanel?
    var exportOwner: VoiceFoundationOwner?
    var exportCompletion: MeetingFileCompletion?
    var importOwner: VoiceFoundationOwner?
    @Published var importing = false
    @Published var importProgress = 0.0
    @Published var importStatus = ""
    var importEpoch = UUID()
    var importTask: Task<Void, Never>?
    var importWorker: Task<Meeting, Error>?
    @Published var calendarLink: MeetingCalendarLink?
    @Published var calendarLibrary: [UUID: MeetingCalendarLink] = [:]
    @Published var calendarProviders: [PluginCatalogEntry] = []
    @Published var calendarReadEntries: [PluginCatalogEntry] = []
    @Published var calendarProvider = ""
    @Published var calendarDay = MeetingCalendarDay.text(Date())
    @Published var calendarPickerOpen = false
    @Published var calendarEvents: [PluginCalendarEvent] = []
    @Published var calendarBusy = false
    @Published var calendarStatus = ""
    @Published var calendarNext = -1
    @Published var calendarTotal = 0
    var calendarObserved = Date.distantPast
    var calendarRequest: UUID?
    var calendarPendingEntry: PluginCatalogEntry?
    var calendarPurpose = ""
    var calendarOwner: VoiceFoundationOwner?
    var calendarTask: Task<Void, Never>?
    var invokeCalendar: ((UUID, PluginActionAddress, [String: PluginValue]) -> Void)?
    var cancelCalendarInvocation: ((UUID) -> Void)?
    @Published var questionProviders: [PluginCatalogEntry] = []
    @Published var questionProvider = ""
    @Published var questionText = ""
    @Published var questionStatus = ""
    @Published var askingQuestion = false
    @Published var questionSnapshot: MeetingChatEvidence?
    @Published var questionScope = "meeting"
    @Published var questionLibraryFilter = ""
    @Published var meetingChat = MeetingChat(meetingID: nil)
    @Published var chatPage = 0
    var chatLoadFailed = false
    var currentChatTurn: UUID?
    @Published var questionAnswer: PluginEvidenceAnswer?
    @Published var highlightedCitation = ""
    @Published var highlightedSourceText = ""
    @Published var highlightedUtterance = ""
    var questionRequest: UUID?
    var questionEpoch = UUID()
    var questionOwner: VoiceFoundationOwner?
    var questionTask: Task<Void, Never>?
    var pendingQuestionProvider: PluginCatalogEntry?
    var invokeQuestion: ((UUID, PluginActionAddress, [String: PluginValue]) -> Void)?
    var cancelQuestionInvocation: ((UUID) -> Void)?
    @Published var notebook: MeetingNotebook?
    @Published var notebookPage = "transcript"
    var noteEvidencePage = 0
    @Published var searchIDs: Set<UUID>?
    var searchOwner: VoiceFoundationOwner?
    var searchGeneration = UUID()
    var searchTask: Task<Void, Never>?
    var summaryTask: Task<Void, Never>?
    @Published var summarizing = false
    @Published var callOffersEnabled = true
    @Published var callOffer: MeetingCallOffer?
    var callState = MeetingCallState()
    let callPanel: MeetingCallOfferPanel
    let callDetectionOwner = MeetingCallDetectionOwner()
    var callDetectionSuspended = false
    @Published var speakerSeparation = true
    @Published var speakerStatus = "Speakers are labelled within each source; names are yours to assign"
    var liveSpeakers = MeetingLiveSpeakers()
    var liveSpeakerService: MeetingLiveSpeakerAnalyzer?
    var liveSpeakerReady = false
    var speakerOwner: VoiceFoundationOwner?
    var speakerStartTask: Task<Void, Never>?
    var speakerMeetingID: UUID?
    @Published var liveEnabled = true
    @Published var liveStatus = ""
    @Published var liveState = MeetingLiveState()
    @Published var showingLiveTranscript = false
    @Published var hasLiveTranscript = false
    @Published var hasRefinedTranscript = false
    @Published var catchingUp = false
    @Published var catchUpStatus = ""
    @Published var catchUpNotes: MeetingNotebook?
    @Published var catchUpRange = ""
    var catchUpOwner: VoiceFoundationOwner?
    var catchUpTask: Task<Void, Never>?
    var catchUpEpoch = UUID()
    var liveService: MeetingLiveTranscriber?
    var livePersistence: MeetingTranscriptCheckpoints?
    var livePersistenceMeeting: UUID?
    var livePersistenceOwner: VoiceFoundationOwner?
    var livePersistenceCallbacks: VoiceAudioCallbackAdmission?
    private var analysisTask: Task<Void, Never>?
    private var livePreparing = false
    var liveCheckpoint = Date.distantPast
    @Published var phase = "idle"
    @Published var status = "Record a meeting on this Mac"
    @Published var library: [Meeting] = []
    @Published var selected: Meeting?
    @Published var duration = 0.0
    @Published var playhead = 0.0
    @Published var playing = false
    @Published var levels: [String: Double] = [:]
    @Published var sources: [MeetingAudioSource] = []
    @Published var transcript: MeetingTranscript?
    @Published var libraryPage = 0
    @Published var libraryQuery = ""
    @Published var transcriptPage = 0
    @Published var processing = false
    @Published var processProgress = 0.0
    @Published var speakersReady = false
    @Published var parakeetReady = false
    var selectedASRReady: Bool { configuration.allows(.model) && (asrProvider == .apple || LocalASREngine(asrProvider).ready) }
    @Published var asrProvider = MeetingASRProvider.apple
    var processingOwner: VoiceFoundationOwner?
    var processingTask: Task<Void, Never>?
    var locale: (() -> String)?
    var occupied: Bool { choosingImport || importing || active || processing || summarizing || catchingUp || askingQuestion || calendarBusy }
    var changed: (() -> Void)?
    var canStart: (() -> Bool)?
    var microphone: (() -> String)?
    private var originalStore:MeetingStore?
    var store:MeetingStore? { configuration.permitsData() ? originalStore:nil }
    private var writer: MeetingAudioWriter?
    private var capture: MeetingCapture?
    private(set) var lastCaptureStop: MeetingCaptureStopResult?
    // Captured at original recording admission, not looked up from a mutable
    // client when a callback or a later detach arrives.
    private var recordingOwner: VoiceFoundationOwner?
    private var recordingAttempt: MeetingRecordingAttempt?
    private var recordingFinalizing = false
    private var task: Task<Void, Never>?
    private var fixtureTask: Task<Void, Never>?
    private(set) var fixtureStarted = false
    private(set) var token = UUID()
    private var started = 0.0
    private var timer: Timer?
    private var players: [String: AVAudioPlayer] = [:]
    private var playbackOwner: VoiceFoundationOwner?
    private var playbackCallbacks: VoiceAudioCallbackAdmission?
    private var playbackReason: String?
    private var playbackEpoch = 0.0
    let nativeObserverOwner = MeetingNativeObserverOwner()
    var nativeCallbacks: VoiceAudioCallbackAdmission { nativeObserverOwner.admission }
    var nativeClosing: Bool { nativeObserverOwner.closing }
    private var observations = Set<AnyCancellable>()
    private var lifecycle: [NSObjectProtocol] = []
    private var termination: NSObjectProtocol?
    var active: Bool { ["preparing", "recording", "paused", "finishing"].contains(phase) }
    init(configuration suppliedConfiguration:VoiceProductConfiguration? = nil,
         appearanceStore: PluginAppearanceStore? = nil,
         presentationAllowed: @escaping @MainActor () -> Bool = { true }) {
        let configuration = suppliedConfiguration ?? .legacy
        self.configuration=configuration
        self.callPanel = MeetingCallOfferPanel(appearanceStore: appearanceStore, presentationAllowed: presentationAllowed)
        self.folderScope = preferences.string(forKey: "meetingFolder") ?? "all"
        self.questionLibraryFilter = preferences.string(forKey: "meetingChatFilter") ?? ""
        self.callOffersEnabled = preferences.object(forKey: "teamsMeetingOffers") as? Bool ?? true
        self.speakerSeparation = preferences.object(forKey: "meetingSpeakerSeparation") as? Bool ?? true
        self.liveEnabled = preferences.object(forKey: "meetingLiveEnabled") as? Bool ?? true
        self.asrProvider = MeetingASRProvider(rawValue: preferences.string(forKey: "meetingASRProvider") ?? "") ?? .apple
        if configuration.allows(.model){speakersReady=MeetingSpeakerEngine.ready;parakeetReady=LocalASREngine(.parakeet).ready}
        let demo = configuration.isolated ? nil : Bundle.main.object(forInfoDictionaryKey: "NeroLiveFixtureAudio") as? String
        let root = demo == nil ? configuration.meetingsRoot
            : FileManager.default.temporaryDirectory.appendingPathComponent("NeroVoice-LiveDemo-" + UUID().uuidString)
        originalStore = try? { () throws -> MeetingStore in
            try configuration.validateData()
            let actual=try MeetingStore(root:root)
            try configuration.validateData()
            return actual
        }()
        let callbacks = nativeCallbacks
        objectWillChange.throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true).sink { [weak self] _ in
            guard let entered = callbacks.enter() else { return }
            Task { @MainActor in
                defer { entered.finish() }
                guard let self, !self.nativeClosing else { return }; self.changed?()
            }
        }.store(in: &observations)
        if configuration.isolated {
            loadOrganization();refresh()
            status=configuration.reason
            return
        }
        guard !CommandLine.arguments.contains("--protocol-test") else { return }
        if let store {
            for value in store.list() where ["recording", "paused"].contains(value.state) { _ = try? MeetingAudioWriter.recover(value, store: store) }
        } else { status = "Cannot open the meeting library" }
        loadOrganization(); refresh(); if demo == nil { refreshSources() }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let entered = callbacks.enter() else { return }
            Task { @MainActor in
                defer { entered.finish() }
                guard let self, !self.nativeClosing else { return }; self.playbackTick()
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let entered = callbacks.enter() else { return }; defer { entered.finish() }
            MainActor.assumeIsolated { guard let self, !self.nativeClosing else { return }; self.shutdown() }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            lifecycle.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let entered = callbacks.enter() else { return }
                Task { @MainActor in
                defer { entered.finish() }; guard let self, !self.nativeClosing else { return }
                self.callDetectionSuspended = true; self.stopCallDetection(); self.cancelLiveSpeakers(); self.importPicker?.cancel(nil); self.cancelImport(force: true); self.summaryTask?.cancel(); self.cancelCatchUp(force: true); self.cancelQuestion(force: true); self.cancelCalendar(force: true); self.processingTask?.cancel(); self.stopPlayback(force: true); if self.active { self.finish(paused: false, issue: "Stopped for sleep or screen lock.") }
            } })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            lifecycle.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let entered = callbacks.enter() else { return }
                Task { @MainActor in
                defer { entered.finish() }; guard let self, !self.nativeClosing else { return }
                self.callDetectionSuspended = false; self.startCallDetection()
            } })
        }
    }
    func refreshSources() {
        guard allowProductEffect(.discovery) else{return}
        sources = MeetingSources.available().map { source in
            let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == source.id }?.localizedName ?? source.name
            return .init(id: source.id, name: name)
        }
    }
    func refresh() { guard permitMeetingWork()else{status="The original isolated library is unavailable";return};library = store?.list() ?? []; refreshCalendarLibrary(); if let id = selected?.id { selected = library.first { $0.id == id } }; searchLibrary() }
    func chooseASR(_ provider: MeetingASRProvider) {
        guard permitMeetingWork(), !occupied else { return }
        asrProvider = provider
        storeMeetingPreference(provider.rawValue, forKey: "meetingASRProvider")
        loadTranscript()
        status = "\(provider.title) selected for meetings"
    }
    func select(_ id: UUID) { guard permitMeetingWork(), !occupied else { return }; stopPlayback(); resetCatchUp(); resetQuestion(); questionScope = "meeting"; selected = library.first { $0.id == id }; duration = selected?.duration ?? 0; playhead = 0; loadTranscript(); notebook = try? store?.notebook(id); loadCalendarLink(); loadChat() }
    private func reserveRecordingAttempt(meeting: Meeting? = nil) -> MeetingRecordingAttempt? {
        guard permitMeetingWork(), !recordingFinalizing, (!active || phase == "paused") else { return nil }
        let owner = LocalFoundationModelWork.currentOwner
        let attempt = MeetingRecordingAttempt(owner: owner, meeting: meeting)
        recordingAttempt = attempt; recordingOwner = owner; token = attempt.generation; task = nil
        markMeetingUnverified("recording-capture-original-return-pending", owner: owner); lastCaptureStop = nil
        phase = "preparing"
        guard !attempt.sealed, token == attempt.generation else { return nil }
        status = "Preparing meeting audio…"
        guard !attempt.sealed, token == attempt.generation else { return nil }
        return attempt
    }
    func start(title: String, mic: Bool, source: String, live: Bool = true) {
        guard permitMeetingWork(), serviceAllowsActivity() else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NeroLiveFixtureAudio") == nil else { status = "This developer demo uses only its bundled synthetic file."; return }
        guard !occupied, !recordingFinalizing, canStart?() != false, let store else { status = "Finish dictation before starting a meeting"; return }
        guard mic || source != "none", source == "none" || source == "all" || sources.contains(where: { $0.id == source }) else { status = "Choose a recording source"; return }
        guard let attempt = reserveRecordingAttempt() else { return }
        stopPlayback(); cancelLiveSpeakers(); callPanel.hide(); callOffer = nil
        guard !attempt.sealed, token == attempt.generation else { return }
        resetCatchUp(); resetQuestion(); liveEnabled = live; storeMeetingPreference(live, forKey: "meetingLiveEnabled")
        guard !attempt.sealed, token == attempt.generation else { return }
        liveStatus = ""; showingLiveTranscript = live; hasLiveTranscript = false; hasRefinedTranscript = false; notebookPage = "transcript"
        guard !attempt.sealed, token == attempt.generation else { return }
        let value = Meeting(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? calendarLink?.event.title ?? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))" : title, source: source, microphone: mic)
        do {
            try store.save(value); attempt.meeting = value
            guard !attempt.sealed, token == attempt.generation else { return }
            fileNewMeeting(value.id, scope: folderScope); if let calendarLink { try store.saveCalendarLink(calendarLink, id: value.id) }
            guard !attempt.sealed, token == attempt.generation else { return }
            selected = value
            guard !attempt.sealed, token == attempt.generation else { return }
            questionScope = "meeting"; loadChat()
            guard !attempt.sealed, token == attempt.generation else { return }
            notebook = MeetingNotebook(meetingID: value.id); transcript = nil; transcriptPage = 0; duration = 0
            guard !attempt.sealed, token == attempt.generation else { return }
            refresh()
            guard !attempt.sealed, token == attempt.generation else { return }
            begin(value, attempt: attempt)
        } catch {
            meetingFileUncertain.insert(attempt.owner)
            if token == attempt.generation { finish(paused: false, issue: error.localizedDescription) }
        }
    }
    func resume() {
        guard permitMeetingWork(), serviceAllowsActivity(), phase == "paused", !recordingFinalizing,
              let value = selected, canStart?() != false, let attempt = reserveRecordingAttempt(meeting: value) else { return }
        begin(value, attempt: attempt)
    }
    private func begin(_ meeting: Meeting, attempt: MeetingRecordingAttempt) {
        guard !attempt.sealed, token == attempt.generation, let store else { return }
        let generation = attempt.generation
        attempt.startScheduled = true
        task = Task { [self] in
            defer { attempt.startReturned = true }
            do {
                try Task.checkCancellation(); guard !attempt.sealed, generation == token else { throw CancellationError() }
                if meeting.microphone {
                    let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    try Task.checkCancellation(); guard generation == token else { return }
                    guard allowed else { throw VoiceProblem.message("Allow Nero Voice in macOS Microphone settings") }
                }
                var value = meeting; value.state = "recording"; value.issue = ""
                try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
                // Attach before the first captured frame. Model preparation
                // consumes this bounded opening queue once it is ready.
                let openingFeed = liveEnabled ? MeetingLiveAudioFeed(bufferingLimit: 512) : nil
                let speakerFeed = speakerOpeningFeed(for: value)
                let writer = try MeetingAudioWriter(store: store, meeting: value, liveFeed: openingFeed,
                    speakerFeed: speakerFeed); attempt.writer = writer; self.writer = writer
                try Task.checkCancellation(); guard !attempt.sealed, generation == token else { throw CancellationError() }
                if liveEnabled { markMeetingUnverified("live-worker-original-return-pending", owner: attempt.owner) }
                beginSpeakerSession(value, openingFeed: speakerFeed)
                try Task.checkCancellation(); guard !attempt.sealed, generation == token else { throw CancellationError() }
                attempt.captureAdmissionAttempted = true
                let capture = MeetingCapture(); attempt.capture = capture; self.capture = capture
                started = ProcessInfo.processInfo.systemUptime
                try Task.checkCancellation(); guard !attempt.sealed, generation == token else { throw CancellationError() }
                try capture.start(microphone: microphone?().isEmpty == false ? microphone?() : nil, includeMicrophone: value.microphone,
                                  systemSource: value.source, writer: writer, offset: value.duration) { [weak self] error in self?.finish(paused: false, issue: error) }
                for _ in 0..<80 {
                    try Task.checkCancellation(); guard generation == token else { return }
                    let state = writer.snapshot(); if let error = state.error { throw VoiceProblem.message(error) }
                    if (!value.microphone || state.last["mic"] != nil) && (value.source == "none" || state.last["system"] != nil) {
                        phase = "recording"
                        try Task.checkCancellation(); guard !attempt.sealed, generation == token else { throw CancellationError() }
                        status = "Recording · saved on this Mac"
                        try Task.checkCancellation(); guard !attempt.sealed, generation == token else { throw CancellationError() }
                        prepareAnalysis(value, writer: writer, generation: generation, openingFeed: openingFeed)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw VoiceProblem.message("A selected source is not delivering audio. Check its permission or choose another source.")
            } catch { if generation == token { finish(paused: false, issue: error.localizedDescription) } }
        }
    }
    private func prepareAnalysis(_ meeting: Meeting, writer: MeetingAudioWriter, generation: UUID, openingFeed: MeetingLiveAudioFeed?) {
        guard token == generation, phase == "recording", !nativeClosing else { return }
        livePreparing = true
        if liveEnabled, let recordingOwner { markMeetingUnverified("live-worker-original-return-pending", owner: recordingOwner) }
        if liveEnabled { liveStatus = "Audio is recording · preparing local live words…" }
        guard token == generation, phase == "recording", !nativeClosing else { return }
        let cleanup = MeetingCleanupReceipt(), owner = recordingOwner
        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if let issue = cleanup.issue, let owner { self.markMeetingUnverified("live-asr-original-close:" + issue, owner: owner) }
            }
            do {
                try Task.checkCancellation()
                try await MeetingCleanupContext.$current.withValue(cleanup) {
                    try await self.beginLive(meeting, feed: openingFeed ?? MeetingLiveAudioFeed())
                }
                try Task.checkCancellation()
                guard self.token == generation, self.phase == "recording" else { return }
                writer.attachLiveFeed(self.liveService?.feed)
                self.livePreparing = false; self.analysisTask = nil
            } catch {
                guard self.token == generation else { return }
                self.livePreparing = false; self.analysisTask = nil
                self.liveStatus = "Live words unavailable · saved audio can be transcribed afterward."
            }
        }
    }
    func tick() {
        guard phase == "recording" || phase == "preparing", let writer else { return }
        let value = writer.snapshot(); duration = value.duration; levels = value.levels
        if let error = value.error { finish(paused: false, issue: error); return }
        if phase == "recording", let meeting = selected {
            let now = ProcessInfo.processInfo.systemUptime
            let tracks = (meeting.microphone ? ["mic"] : []) + (meeting.source != "none" ? ["system"] : [])
            if tracks.contains(where: { now - (value.last[$0] ?? started) > 5 }) { finish(paused: false, issue: "An audio source stopped delivering. Saved audio is retained.") }
        }
    }
    func finish(paused: Bool, issue: String = "") {
        guard active, phase != "finishing", !recordingFinalizing else { return }
        recordingFinalizing = true
        let attempt = recordingAttempt; attempt?.sealed = true
        let fileOwner = attempt?.owner ?? recordingOwner
        // Reserve the original finalization return before @Published phase or
        // native Stop can synchronously reenter either retirement controller.
        let finalizationReturn = MeetingFileCompletion()
        if let fileOwner {
            let originalReturn = Task { await finalizationReturn.wait() }
            retainMeetingTask(originalReturn, owner: fileOwner)
        }
        // Retain the actual originals before cancellation or any callout can
        // replace the visible fields. The final writer cannot close until the
        // admitted capture callbacks and the original preparation return.
        let originalStart = task, originalAnalysis = analysisTask
        let originalFixture = fixtureTask, originalSpeakerStart = speakerStartTask
        let originalCapture = attempt != nil ? attempt?.capture : capture
        let originalLiveService = liveService
        phase = "finishing"; token = UUID(); originalStart?.cancel(); originalCapture?.stop(); capture = nil
        originalAnalysis?.cancel(); analysisTask = nil
        // Final Stop must not launch a model that is still preparing. Pause
        // keeps that same bounded queue and speaker identity for Resume.
        if !paused && !liveSpeakerReady { speakerStartTask?.cancel(); liveSpeakerService?.cancel() }
        if livePreparing { liveService?.cancel(); liveService = nil; liveState.retire(); livePreparing = false }
        fixtureTask?.cancel(); fixtureTask = nil
        var originalSpeakerRetirement: Task<Void, Never>?
        if !issue.isEmpty { liveService?.cancel(); liveState.retire(); originalSpeakerRetirement = cancelLiveSpeakers() }
        levels = [:]
        task = Task { [self] in
            defer { recordingFinalizing = false; finalizationReturn.finish() }
            await originalStart?.value
            let actualCapture = attempt != nil ? attempt?.capture : originalCapture
            if let actualCapture {
                let result = await actualCapture.stopAndDrain(); lastCaptureStop = result
                if result.microphoneStopReturned && !result.stoppedDuringStart && result.systemStatuses.allSatisfy({ $0 == 0 }), let attempt {
                    resolveMeetingUnverified("recording-capture-original-return-pending", owner: attempt.owner)
                }
            } else if let attempt, (!attempt.startScheduled || attempt.startReturned), !attempt.captureAdmissionAttempted {
                // Explicit attempt-stage receipt: the original start returned
                // without ever reaching capture construction/native admission.
                resolveMeetingUnverified("recording-capture-original-return-pending", owner: attempt.owner)
            }
            let writer = attempt != nil ? attempt?.writer : self.writer
            await originalAnalysis?.value
            await originalFixture?.value
            await originalSpeakerStart?.value
            do {
                if let writer { selected = try await writer.finish(state: issue.isEmpty ? (paused ? "paused" : "saved") : "interrupted", issue: issue) }
                else if var value = attempt?.meeting, let store { value.state = issue.isEmpty ? (paused ? "paused" : "saved") : "interrupted"; value.issue = issue; try store.save(value); selected = value }
                if issue.isEmpty, let service = liveService {
                    liveStatus = "Finishing the last words…"
                    do { try await service.finish(); liveStatus = "Live draft saved · refine or identify speakers after recording" }
                    catch { service.cancel(); liveStatus = "\(error.localizedDescription) Saved audio is intact." }
                }
                await originalLiveService?.cancelAndWait()
                if let resourceIssue = originalLiveService?.resourceReturnIssue, let fileOwner {
                    markMeetingUnverified("live-asr-original-resource:" + resourceIssue, owner: fileOwner)
                }
                liveService = nil
                var labelled = false
                if !paused && issue.isEmpty { labelled = await finishLiveSpeakers() }
                await originalSpeakerRetirement?.value
                if !paused, let fileOwner { resolveMeetingUnverified("live-worker-original-return-pending", owner: fileOwner) }
                saveLiveProgress()
                if let error = await drainLiveFilePersistence() {
                    if let fileOwner { meetingFileUncertain.insert(fileOwner) }
                    liveStatus = "Live words could not be saved: \(error) Audio is retained."
                }
                liveState.retire()
                self.writer = nil; refresh(); duration = selected?.duration ?? 0; phase = paused && issue.isEmpty ? "paused" : "idle"
                status = issue.isEmpty ? (paused ? "Paused · recording saved" : "Meeting saved · ready to play") : issue
                if !paused && issue.isEmpty && !labelled && speakerSeparation && speakersReady && transcript?.utterances.isEmpty == false {
                    process("speakers")
                }
            } catch {
                if let fileOwner { meetingFileUncertain.insert(fileOwner) }
                // Finalization may have stopped on the first failed track;
                // close every original remaining owned file on its writer queue.
                _ = await writer?.closeAfterFailure()
                let speakerRetirement = cancelLiveSpeakers(); liveService?.cancel()
                await originalLiveService?.cancelAndWait(); await originalSpeakerRetirement?.value; await speakerRetirement?.value
                if let resourceIssue = originalLiveService?.resourceReturnIssue, let fileOwner {
                    markMeetingUnverified("live-asr-original-resource:" + resourceIssue, owner: fileOwner)
                }
                if let fileOwner { resolveMeetingUnverified("live-worker-original-return-pending", owner: fileOwner) }
                liveService = nil; saveLiveProgress()
                if await drainLiveFilePersistence() != nil, let fileOwner { meetingFileUncertain.insert(fileOwner) }
                liveState.retire(); self.writer = nil; phase = "idle"
                status = "Recording stopped. Recovery needed: \(error.localizedDescription)"; refresh()
            }
        }
        if let task, let recordingOwner { meetingFileTasks.retain(task, owner: recordingOwner) }
    }
    // Stop only the recording admitted by this exact native-context token.
    // Other meeting families are still unqualified, so even a joined recording
    // must not manufacture a family-wide released result.
    /// Seal only the presentation owner; meeting work remains with its own
    /// existing recording, file, provider and observer retirement controllers.
    func sealPresentationForRetirement() -> Task<Bool, Never> {
        callPanel.sealPresentationForRetirement()
    }

    func retireShared(owner: VoiceFoundationOwner?) async -> VoiceResourceRelease {
        if owner == nil {
            // Close native/restart admission before any task cancellation or
            // callback-bearing stop can synchronously reenter this owner.
            nativeObserverOwner.seal(); callDetectionSuspended = true; callDetectionOwner.seal()
        }
        let originals = ownedMeetingTasks.close(owner)
        if owner == nil {
            stopCallDetection()
            timer?.invalidate(); timer = nil
            for observer in lifecycle { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            lifecycle.removeAll()
            if let termination { NotificationCenter.default.removeObserver(termination); self.termination = nil }
            observations.removeAll()
            nativeObserverOwner.sourceStopsReturned()
        }
        let ownsImport = owner == nil || importOwner == owner
        let originalWorker = ownsImport ? importWorker : nil
        let originalImport = ownsImport ? importTask : nil
        _ = closeImportPicker(owner: owner)
        if owner == nil || exportOwner == owner { exportPanel?.cancel(nil) }
        originalWorker?.cancel()
        if owner == nil || questionOwner == owner { cancelQuestion(force: true) }
        if owner == nil || calendarOwner == owner { cancelCalendar(force: true) }
        if owner == nil || catchUpOwner == owner { cancelCatchUp(force: true) }
        if owner == nil || playbackOwner == owner { stopPlayback(force: true) }
        let providerEntries = capturedMeetingProviders.filter { owner == nil || $0.value.owner == owner }
        let ownsRecording = owner == nil || recordingOwner == owner
        if ownsRecording && active && phase != "finishing" {
            finish(paused: false, issue: "Recording stopped; saved audio is retained.")
        }
        let originalFinalization = ownsRecording && phase == "finishing" ? task : nil
        if let originalWorker { _ = try? await originalWorker.value }
        await originalImport?.value
        await originalFinalization?.value
        if owner == nil { await callDetectionOwner.waitForReturn(); await callPanel.retire(); await nativeObserverOwner.waitForReturn() }
        for original in originals { await original.value }
        await ownedMeetingTasks.waitForReturn(owner)
        for (request, entry) in providerEntries where capturedMeetingProviders[request] != nil {
            await entry.request.retire()
            providerWriteOutcomes[request] = (entry.owner, providerCancelIssues.removeValue(forKey: request) ?? entry.request.writeIssue)
            capturedMeetingProviders[request] = nil
            settlingMeetingProviders.remove(request)
        }
        pendingMeetingProviders = pendingMeetingProviders.filter { owner != nil && $0.value != owner }
        let reasons = meetingUnverified.filter { owner == nil || $0.key == owner }.values.flatMap { $0 }
        if !reasons.isEmpty { return .unknown(reasons.sorted().joined(separator: ",")) }
        let uncertain = providerEffectUncertain.contains { owner == nil || $0 == owner }
        return .released(uncertain ? .effectUncertain : .cancelled)
    }
    // Exact panel owner: seal admission before cancel and retain already
    // admitted callback deliveries. A later stale callback cannot start import.
    @discardableResult func closeImportPicker(owner: VoiceFoundationOwner?) -> Task<Void, Never>? {
        guard owner == nil || importPickerOwner == owner, let panel = importPicker else { return nil }
        let capturedOwner = importPickerOwner ?? LocalFoundationModelWork.localUser
        guard let admission = importPickerAdmission else {
            meetingFileUnknown[capturedOwner] = "import-panel-callback-owner-missing"
            importPicker = nil; importPickerOwner = nil; choosingImport = false; panel.cancel(nil)
            return nil
        }
        admission.seal()
        let original = Task { await admission.waitForReturn(); _ = panel }
        meetingFileTasks.retain(original, owner: capturedOwner)
        importPicker = nil; importPickerOwner = nil; importPickerAdmission = nil; choosingImport = false
        panel.cancel(nil); admission.nativeStopReturned()
        return original
    }
    // File-family retirement is independent of the broader capture/meeting
    // result. Only owned local originals are joined; remote/broker state is not
    // inferred from a writer or callback return.
    func retireFileWork(owner: VoiceFoundationOwner?) async -> VoiceResourceRelease {
        let originals = meetingFileTasks.close(owner)
        let ownsImport = owner == nil || importOwner == owner
        let worker = ownsImport ? importWorker : nil
        let supervisor = ownsImport ? importTask : nil
        let picker = closeImportPicker(owner: owner)
        let ownsExport = owner == nil || exportOwner == owner
        let export = ownsExport ? exportCompletion : nil
        if ownsExport { exportPanel?.cancel(nil) }
        worker?.cancel()
        if owner == nil || questionOwner == owner { cancelQuestion(force: true) }
        if owner == nil || calendarOwner == owner { cancelCalendar(force: true) }
        if owner == nil || playbackOwner == owner { stopPlayback(force: true) }
        let ownsRecording = owner == nil || recordingOwner == owner
        if ownsRecording && active && phase != "finishing" {
            finish(paused: false, issue: "Recording stopped; saved audio is retained.")
        }
        let finalization = ownsRecording && phase == "finishing" ? task : nil
        if let worker { _ = try? await worker.value }
        await supervisor?.value; await picker?.value; await export?.wait(); await finalization?.value
        for original in originals { await original.value }
        await meetingFileTasks.waitForReturn(owner)
        let unknown = meetingFileUnknown.filter { owner == nil || $0.key == owner }.values.sorted()
        if !unknown.isEmpty { return .unknown(unknown.joined(separator: ",")) }
        let uncertain = meetingFileUncertain.contains { owner == nil || $0 == owner }
        return .released(uncertain ? .effectUncertain : .cancelled)
    }
    // A full adapter can own a particular outgoing request even when the
    // initiating user is local. Its detach must never stop that user's other
    // recording or summary; match only the exact originally reserved IDs.
    func retireProviderRequests(_ requests: Set<UUID>) async -> VoiceResourceRelease {
        let question = questionRequest.flatMap { requests.contains($0) ? questionTask : nil }
        let calendar = calendarRequest.flatMap { requests.contains($0) ? calendarTask : nil }
        if let id = questionRequest, requests.contains(id) { cancelQuestion(force: true) }
        if let id = calendarRequest, requests.contains(id) { cancelCalendar(force: true) }
        let settlements = requests.compactMap { providerSettlementTasks[$0] }
        await question?.value; await calendar?.value
        for settlement in settlements { await settlement.value }
        let entries = capturedMeetingProviders.filter { requests.contains($0.key) }
        let unknown = requests.contains { id in entries[id] == nil && providerWriteOutcomes[id] == nil }
        for entry in entries.values { await entry.request.retire() }
        for (id, entry) in entries where capturedMeetingProviders[id] != nil {
            providerWriteOutcomes[id] = (entry.owner, providerCancelIssues.removeValue(forKey: id) ?? entry.request.writeIssue)
            capturedMeetingProviders[id] = nil; settlingMeetingProviders.remove(id)
        }
        if unknown { return .unknown("provider-local-request-return-unavailable") }
        return .released(.effectUncertain)
    }
    /// Context-owned IDs only, after retireProviderRequests joined their actual
    /// local originals. Other owners and all unresolved entries remain intact.
    func pruneProviderRequests(_ requests:Set<UUID>)async->VoiceResourceRelease{
        let originals=requests.compactMap{providerSettlementTasks[$0]}
        for original in originals{await original.value}
        guard requests.allSatisfy({questionRequest != $0 && calendarRequest != $0 &&
            capturedMeetingProviders[$0] == nil && pendingMeetingProviders[$0] == nil &&
            !settlingMeetingProviders.contains($0) && providerWriteOutcomes[$0] != nil}) else{
            return .unknown("meeting-provider-prune-original-unreturned")
        }
        for request in requests{
            providerWriteOutcomes[request]=nil;providerCancelIssues[request]=nil
            providerSettlementTasks[request]=nil
        }
        return .released(.effectUncertain)
    }
    func bookmark() { guard permitMeetingWork(), phase == "recording" else { return }; writer?.mark("Bookmark"); status = "Bookmark added" }
    func stopPlayback(force: Bool = false) {
        if !force, playing, let playbackOwner, playbackOwner != LocalFoundationModelWork.currentOwner { return }
        let callbacks = playbackCallbacks, originalOwner = playbackOwner, originalReason = playbackReason
        callbacks?.seal(); playbackCallbacks = nil; playbackReason = nil
        players.values.forEach { $0.stop() } // Actual owned stop calls return here.
        players = [:]; playing = false
        callbacks?.nativeStopReturned()
        if let callbacks, let originalOwner, let originalReason {
            let original = Task { @MainActor [self] in
                await callbacks.waitForReturn()
                resolveMeetingUnverified(originalReason, owner: originalOwner)
            }
            retainMeetingTask(original, owner: originalOwner)
        }
    }
    func play() {
        guard allowProductEffect(.speech) else{return}
        guard permitMeetingWork(), serviceAllowsActivity() else { return }
        guard !occupied, let meeting = selected, !meeting.chunks.isEmpty else { return }
        let owner = LocalFoundationModelWork.currentOwner
        if playing { if playbackOwner == owner { stopPlayback() }; return }
        guard canStart?() != false else { status = "Finish dictation or speech playback before playing a meeting."; return }
        if playhead >= meeting.duration { playhead = 0 }
        playbackOwner = owner; playbackCallbacks = VoiceAudioCallbackAdmission()
        let reason = "native-playback-return-" + UUID().uuidString; playbackReason = reason
        markMeetingUnverified(reason, owner: owner)
        playbackEpoch = ProcessInfo.processInfo.systemUptime - playhead; playing = true; playbackTick()
    }
    func seek(_ time: Double) {
        guard !active, time.isFinite, let meeting = selected else { return }
        let wasPlaying = playing; stopPlayback(); playhead = max(0, min(meeting.duration, time))
        if wasPlaying { play() }
    }
    private func playbackTick() {
        guard playing, let callbacks = playbackCallbacks, let owner = playbackOwner,
              let entered = callbacks.enter(), let meeting = selected, let store else { return }
        defer { entered.finish() }
        playhead = min(meeting.duration, ProcessInfo.processInfo.systemUptime - playbackEpoch)
        guard playing, playbackCallbacks === callbacks, meetingFileTasks.permits(owner) else { return }
        if playhead >= meeting.duration { stopPlayback(force: true); return }
        let chunks = meeting.chunks.filter { $0.start <= playhead && playhead < $0.start + $0.duration }
        for key in Array(players.keys) where !chunks.contains(where: { $0.file == key }) { players.removeValue(forKey: key)?.stop() }
        for chunk in chunks where players[chunk.file] == nil {
            guard playing, playbackCallbacks === callbacks, meetingFileTasks.permits(owner) else { return }
            do {
                let player = try AVAudioPlayer(contentsOf: store.audio(chunk, meeting: meeting))
                guard playing, playbackCallbacks === callbacks, meetingFileTasks.permits(owner) else { player.stop(); return }
                player.prepareToPlay(); player.currentTime = playhead - chunk.start
                player.volume = meeting.microphone && meeting.source != "none" ? 0.7 : 1
                guard playing, playbackCallbacks === callbacks, meetingFileTasks.permits(owner) else { return }
                guard player.play() else { throw VoiceProblem.message("Audio playback could not start") }
                guard playing, playbackCallbacks === callbacks, meetingFileTasks.permits(owner) else {
                    player.stop(); return
                }
                players[chunk.file] = player
            } catch { stopPlayback(force: true); status = error.localizedDescription; return }
        }
    }
    func rename(_ title: String) {
        guard permitMeetingWork(), !occupied, var value = selected, let store else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty, clean.utf8.count <= 400 else { return }
        value.title = clean; do { try store.save(value); refresh() } catch { status = error.localizedDescription }
    }
    func revealFiles() { guard allowProductEffect(.externalFiles)else{return};if let selected, let store { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.folder(selected.id).path) } }
    func deleteSelected() {
        guard allowProductEffect(.nativePresentation) else{return}
        guard permitMeetingWork(), !occupied, let selected, let store else { return }; stopPlayback()
        let alert = NSAlert(); alert.messageText = "Move this meeting to Trash?"; alert.informativeText = "\(selected.title) and its saved audio will move to the Trash."; alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try FileManager.default.trashItem(at: store.folder(selected.id), resultingItemURL: nil); resetQuestion(); cancelCalendar(); calendarLink = nil; self.selected = nil; notebook = nil; transcript = nil; duration = 0; refresh() } catch { status = error.localizedDescription }
    }
    func shutdown() {
        stopCallDetection(); cancelLiveSpeakers(); analysisTask?.cancel(); analysisTask = nil; importPicker?.cancel(nil); importWorker?.cancel(); importTask?.cancel(); fixtureTask?.cancel(); searchTask?.cancel(); summaryTask?.cancel(); cancelCatchUp(force: true); cancelQuestion(force: true); cancelCalendar(force: true); processingTask?.cancel(); liveService?.cancel(); liveService = nil; saveLiveProgress(); livePersistence?.flushSynchronously(); liveState.retire(); MeetingSpeakerEngine.stopJobs(); LocalASREngine.stopJobs(); token = UUID(); task?.cancel(); capture?.stop(); capture = nil; writer?.finishSynchronously(); writer = nil; stopPlayback(force: true); timer?.invalidate() }
    /// Dedicated developer app identity only: no microphone or Core Audio tap.
    func startLiveFixture() {
        guard allowProductEffect(.capture) else{return}
        guard permitMeetingWork(), let name = Bundle.main.object(forInfoDictionaryKey: "NeroLiveFixtureAudio") as? String,
              name == "synthetic-live.caf", !fixtureStarted, let root = Bundle.main.resourceURL, let store else { return }
        let owner = LocalFoundationModelWork.currentOwner
        recordingOwner = owner; markMeetingUnverified("fixture-live-worker-return-unqualified", owner: owner)
        fixtureStarted = true
        fixtureTask = Task { [self] in
            do {
                asrProvider = .nemotron; liveEnabled = true; notebookPage = "transcript"
                let file = try AVAudioFile(forReading: root.appendingPathComponent(name))
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, file.length <= 30*16000 else { throw VoiceProblem.message("Invalid developer fixture") }
                var value = Meeting(title: "Synthetic live demo · no microphone capture", source: "all", microphone: true)
                value.state = "recording"; try store.save(value); selected = value; notebook = .init(meetingID: value.id); phase = "preparing"; refresh()
                try await beginLive(value, allowPreparingFixture: true); try Task.checkCancellation()
                let writer = try MeetingAudioWriter(store: store, meeting: value, liveFeed: liveService?.feed, speakerFeed: liveSpeakerService?.feed); self.writer = writer
                phase = "recording"; status = "Synthetic file-fed audio only · no microphone or system capture"
                for repetition in 0..<2 {
                    file.framePosition = 0
                    while file.framePosition < file.length {
                        try Task.checkCancellation()
                        let start = Double(Int64(repetition)*file.length + file.framePosition)/16000
                        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!
                        try file.read(into: buffer, frameCount: 1600)
                        writer.append(buffer, track: "mic", start: start); writer.append(buffer, track: "system", start: start+0.05)
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                finish(paused: false)
            } catch { if !Task.isCancelled { finish(paused: false, issue: error.localizedDescription) } }
        }
        retainMeetingTask(fixtureTask, owner: owner)
    }
}
