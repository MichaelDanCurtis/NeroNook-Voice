import AppKit
import AVFoundation
import Combine
import ModuleCore
import VoiceAudio
import NookPluginSDK

@MainActor final class MeetingModel: ObservableObject {
    @Published var organization = MeetingOrganization()
    @Published var folderScope = UserDefaults.standard.string(forKey: "meetingFolder") ?? "all"
    @Published var organizationStatus = ""
    @Published var organizationFailed = false
    @Published var choosingImport = false
    var importPicker: NSOpenPanel?
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
    @Published var questionLibraryFilter = UserDefaults.standard.string(forKey: "meetingChatFilter") ?? ""
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
    var questionTask: Task<Void, Never>?
    var pendingQuestionProvider: PluginCatalogEntry?
    var invokeQuestion: ((UUID, PluginActionAddress, [String: PluginValue]) -> Void)?
    var cancelQuestionInvocation: ((UUID) -> Void)?
    @Published var notebook: MeetingNotebook?
    @Published var notebookPage = "transcript"
    @Published var searchIDs: Set<UUID>?
    var searchTask: Task<Void, Never>?
    var summaryTask: Task<Void, Never>?
    @Published var summarizing = false
    @Published var callOffersEnabled = UserDefaults.standard.object(forKey: "teamsMeetingOffers") as? Bool ?? true
    @Published var callOffer: MeetingCallOffer?
    var callState = MeetingCallState()
    let callPanel = MeetingCallOfferPanel()
    var callDetectionTask: Task<Void, Never>?
    var callDetectionSuspended = false
    @Published var speakerSeparation = UserDefaults.standard.object(forKey: "meetingSpeakerSeparation") as? Bool ?? true
    @Published var speakerStatus = "Speakers are labelled within each source; names are yours to assign"
    var liveSpeakers = MeetingLiveSpeakers()
    var liveSpeakerService: MeetingLiveSpeakerAnalyzer?
    var liveSpeakerReady = false
    var speakerStartTask: Task<Void, Never>?
    var speakerMeetingID: UUID?
    @Published var liveEnabled = UserDefaults.standard.object(forKey: "meetingLiveEnabled") as? Bool ?? true
    @Published var liveStatus = ""
    @Published var liveState = MeetingLiveState()
    @Published var showingLiveTranscript = false
    @Published var hasLiveTranscript = false
    @Published var hasRefinedTranscript = false
    @Published var catchingUp = false
    @Published var catchUpStatus = ""
    @Published var catchUpNotes: MeetingNotebook?
    @Published var catchUpRange = ""
    var catchUpTask: Task<Void, Never>?
    var catchUpEpoch = UUID()
    var liveService: MeetingLiveTranscriber?
    var livePersistence: MeetingTranscriptCheckpoints?
    var livePersistenceMeeting: UUID?
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
    @Published var speakersReady = MeetingSpeakerEngine.ready
    @Published var parakeetReady = LocalASREngine(.parakeet).ready
    var selectedASRReady: Bool { asrProvider == .apple || LocalASREngine(asrProvider).ready }
    @Published var asrProvider = MeetingASRProvider(rawValue: UserDefaults.standard.string(forKey: "meetingASRProvider") ?? "") ?? .apple
    var processingTask: Task<Void, Never>?
    var locale: (() -> String)?
    var occupied: Bool { choosingImport || importing || active || processing || summarizing || catchingUp || askingQuestion || calendarBusy }
    var changed: (() -> Void)?
    var canStart: (() -> Bool)?
    var microphone: (() -> String)?
    let store: MeetingStore?
    private var writer: MeetingAudioWriter?
    private var capture: MeetingCapture?
    private var task: Task<Void, Never>?
    private var fixtureTask: Task<Void, Never>?
    private var fixtureStarted = false
    private var token = UUID()
    private var started = 0.0
    private var timer: Timer?
    private var players: [String: AVAudioPlayer] = [:]
    private var playbackEpoch = 0.0
    private var observations = Set<AnyCancellable>()
    private var lifecycle: [NSObjectProtocol] = []
    private var termination: NSObjectProtocol?
    var active: Bool { ["preparing", "recording", "paused", "finishing"].contains(phase) }
    init() {
        let demo = Bundle.main.object(forInfoDictionaryKey: "NeroLiveFixtureAudio") as? String
        let root = demo == nil ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeroVoice/Meetings", isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("NeroVoice-LiveDemo-" + UUID().uuidString)
        store = try? MeetingStore(root: root)
        objectWillChange.throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true).sink { [weak self] _ in Task { @MainActor in self?.changed?() } }.store(in: &observations)
        guard !CommandLine.arguments.contains("--protocol-test") else { return }
        if let store {
            for value in store.list() where ["recording", "paused"].contains(value.state) { _ = try? MeetingAudioWriter.recover(value, store: store) }
        } else { status = "Cannot open the meeting library" }
        loadOrganization(); refresh(); if demo == nil { refreshSources() }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in Task { @MainActor in self?.playbackTick() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.shutdown() } }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            lifecycle.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
                self?.callDetectionSuspended = true; self?.stopCallDetection(); self?.cancelLiveSpeakers(); self?.importPicker?.cancel(nil); self?.cancelImport(); self?.summaryTask?.cancel(); self?.cancelCatchUp(); self?.cancelQuestion(); self?.cancelCalendar(); self?.processingTask?.cancel(); self?.stopPlayback(); if self?.active == true { self?.finish(paused: false, issue: "Stopped for sleep or screen lock.") }
            } })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            lifecycle.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
                self?.callDetectionSuspended = false; self?.startCallDetection()
            } })
        }
    }
    func refreshSources() {
        sources = MeetingSources.available().map { source in
            let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == source.id }?.localizedName ?? source.name
            return .init(id: source.id, name: name)
        }
    }
    func refresh() { library = store?.list() ?? []; refreshCalendarLibrary(); if let id = selected?.id { selected = library.first { $0.id == id } }; searchLibrary() }
    func chooseASR(_ provider: MeetingASRProvider) {
        guard !occupied else { return }
        asrProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: "meetingASRProvider")
        loadTranscript()
        status = "\(provider.title) selected for meetings"
    }
    func select(_ id: UUID) { guard !occupied else { return }; stopPlayback(); resetCatchUp(); resetQuestion(); questionScope = "meeting"; selected = library.first { $0.id == id }; duration = selected?.duration ?? 0; playhead = 0; loadTranscript(); notebook = try? store?.notebook(id); loadCalendarLink(); loadChat() }
    func start(title: String, mic: Bool, source: String, live: Bool = true) {
        guard Bundle.main.object(forInfoDictionaryKey: "NeroLiveFixtureAudio") == nil else { status = "This developer demo uses only its bundled synthetic file."; return }
        guard !occupied, canStart?() != false, let store else { status = "Finish dictation before starting a meeting"; return }
        guard mic || source != "none", source == "none" || source == "all" || sources.contains(where: { $0.id == source }) else { status = "Choose a recording source"; return }
        stopPlayback(); cancelLiveSpeakers(); callPanel.hide(); callOffer = nil
        resetCatchUp(); resetQuestion(); liveEnabled = live; UserDefaults.standard.set(live, forKey: "meetingLiveEnabled")
        liveStatus = ""; showingLiveTranscript = live; hasLiveTranscript = false; hasRefinedTranscript = false; notebookPage = "transcript"
        let value = Meeting(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? calendarLink?.event.title ?? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))" : title, source: source, microphone: mic)
        do { try store.save(value); fileNewMeeting(value.id, scope: folderScope); if let calendarLink { try store.saveCalendarLink(calendarLink, id: value.id) }; selected = value; questionScope = "meeting"; loadChat(); notebook = MeetingNotebook(meetingID: value.id); transcript = nil; transcriptPage = 0; duration = 0; refresh(); begin(value) } catch { status = error.localizedDescription }
    }
    func resume() { guard phase == "paused", let value = selected, canStart?() != false else { return }; begin(value) }
    private func begin(_ meeting: Meeting) {
        guard let store else { return }; phase = "preparing"; status = "Preparing meeting audio…"
        token = UUID(); let generation = token
        task = Task { [self] in
            do {
                if meeting.microphone {
                    let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    try Task.checkCancellation(); guard generation == token else { return }
                    guard allowed else { throw VoiceProblem.message("Allow Nero Voice in macOS Microphone settings") }
                }
                var value = meeting; value.state = "recording"; value.issue = ""
                try Task.checkCancellation(); guard generation == token else { throw CancellationError() }
                let writer = try MeetingAudioWriter(store: store, meeting: value,
                    speakerFeed: liveSpeakerReady ? liveSpeakerService?.feed : nil); self.writer = writer
                let capture = MeetingCapture(); self.capture = capture
                started = ProcessInfo.processInfo.systemUptime
                try capture.start(microphone: microphone?().isEmpty == false ? microphone?() : nil, includeMicrophone: value.microphone,
                                  systemSource: value.source, writer: writer, offset: value.duration) { [weak self] error in self?.finish(paused: false, issue: error) }
                for _ in 0..<80 {
                    try Task.checkCancellation(); guard generation == token else { return }
                    let state = writer.snapshot(); if let error = state.error { throw VoiceProblem.message(error) }
                    if (!value.microphone || state.last["mic"] != nil) && (value.source == "none" || state.last["system"] != nil) {
                        phase = "recording"; status = "Recording · saved on this Mac"
                        prepareAnalysis(value, writer: writer, generation: generation)
                        return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw VoiceProblem.message("A selected source is not delivering audio. Check its permission or choose another source.")
            } catch { if generation == token { finish(paused: false, issue: error.localizedDescription) } }
        }
    }
    private func prepareAnalysis(_ meeting: Meeting, writer: MeetingAudioWriter, generation: UUID) {
        livePreparing = true
        if liveEnabled { liveStatus = "Audio is recording · preparing local live words…" }
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.beginLive(meeting)
                try Task.checkCancellation()
                guard self.token == generation, self.phase == "recording" else { return }
                writer.attachLiveFeed(self.liveService?.feed)
                if self.liveService != nil, writer.snapshot().duration > meeting.duration + 0.5 {
                    self.liveStatus += " · Earlier audio is saved; Transcribe the recording for its opening words."
                }
                self.livePreparing = false; self.analysisTask = nil
                self.beginSpeakerSession(meeting)
            } catch {
                guard self.token == generation else { return }
                self.livePreparing = false; self.analysisTask = nil
                self.liveStatus = "Live words unavailable · saved audio can be transcribed afterward."
            }
        }
    }
    func attachSpeakerFeed(_ feed: MeetingLiveAudioFeed) { writer?.attachSpeakerFeed(feed) }
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
        guard active, phase != "finishing" else { return }
        phase = "finishing"; token = UUID(); task?.cancel(); capture?.stop(); capture = nil
        analysisTask?.cancel(); analysisTask = nil
        if livePreparing { liveService?.cancel(); liveService = nil; liveState.retire(); livePreparing = false }
        fixtureTask?.cancel(); fixtureTask = nil
        if !issue.isEmpty { liveService?.cancel(); liveState.retire(); cancelLiveSpeakers() }
        let writer = self.writer; levels = [:]
        task = Task { [self] in
            do {
                if let writer { selected = try await writer.finish(state: issue.isEmpty ? (paused ? "paused" : "saved") : "interrupted", issue: issue) }
                else if var value = selected, let store { value.state = issue.isEmpty ? (paused ? "paused" : "saved") : "interrupted"; value.issue = issue; try store.save(value); selected = value }
                if issue.isEmpty, let service = liveService {
                    liveStatus = "Finishing the last words…"
                    do { try await service.finish(); liveStatus = "Live draft saved · refine or identify speakers after recording" }
                    catch { service.cancel(); liveStatus = "\(error.localizedDescription) Saved audio is intact." }
                }
                liveService = nil
                var labelled = false
                if !paused && issue.isEmpty { labelled = await finishLiveSpeakers() }
                saveLiveProgress()
                do { try await livePersistence?.flush() }
                catch { liveStatus = "Live words could not be saved: \(error.localizedDescription) Audio is retained." }
                liveState.retire()
                self.writer = nil; refresh(); duration = selected?.duration ?? 0; phase = paused && issue.isEmpty ? "paused" : "idle"
                status = issue.isEmpty ? (paused ? "Paused · recording saved" : "Meeting saved · ready to play") : issue
                if !paused && issue.isEmpty && !labelled && speakerSeparation && speakersReady && transcript?.utterances.isEmpty == false {
                    process("speakers")
                }
            } catch { cancelLiveSpeakers(); liveService?.cancel(); liveService = nil; saveLiveProgress(); liveState.retire(); self.writer = nil; phase = "idle"; status = "Recording stopped. Recovery needed: \(error.localizedDescription)"; refresh() }
        }
    }
    func bookmark() { guard phase == "recording" else { return }; writer?.mark("Bookmark"); status = "Bookmark added" }
    func stopPlayback() { players.values.forEach { $0.stop() }; players = [:]; playing = false }
    func play() {
        guard !occupied, let meeting = selected, !meeting.chunks.isEmpty else { return }
        if playing { stopPlayback(); return }
        guard canStart?() != false else { status = "Finish dictation or speech playback before playing a meeting."; return }
        if playhead >= meeting.duration { playhead = 0 }
        playbackEpoch = ProcessInfo.processInfo.systemUptime - playhead; playing = true; playbackTick()
    }
    func seek(_ time: Double) {
        guard !active, time.isFinite, let meeting = selected else { return }
        let wasPlaying = playing; stopPlayback(); playhead = max(0, min(meeting.duration, time))
        if wasPlaying { play() }
    }
    private func playbackTick() {
        guard playing, let meeting = selected, let store else { return }
        playhead = min(meeting.duration, ProcessInfo.processInfo.systemUptime - playbackEpoch)
        if playhead >= meeting.duration { stopPlayback(); return }
        let chunks = meeting.chunks.filter { $0.start <= playhead && playhead < $0.start + $0.duration }
        for key in Array(players.keys) where !chunks.contains(where: { $0.file == key }) { players.removeValue(forKey: key)?.stop() }
        for chunk in chunks where players[chunk.file] == nil {
            do {
                let player = try AVAudioPlayer(contentsOf: store.audio(chunk, meeting: meeting)); player.prepareToPlay(); player.currentTime = playhead - chunk.start
                player.volume = meeting.microphone && meeting.source != "none" ? 0.7 : 1
                guard player.play() else { throw VoiceProblem.message("Audio playback could not start") }; players[chunk.file] = player
            } catch { stopPlayback(); status = error.localizedDescription; return }
        }
    }
    func rename(_ title: String) {
        guard !occupied, var value = selected, let store else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines); guard !clean.isEmpty, clean.utf8.count <= 400 else { return }
        value.title = clean; do { try store.save(value); refresh() } catch { status = error.localizedDescription }
    }
    func revealFiles() { if let selected, let store { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.folder(selected.id).path) } }
    func deleteSelected() {
        guard !occupied, let selected, let store else { return }; stopPlayback()
        let alert = NSAlert(); alert.messageText = "Move this meeting to Trash?"; alert.informativeText = "\(selected.title) and its saved audio will move to the Trash."; alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try FileManager.default.trashItem(at: store.folder(selected.id), resultingItemURL: nil); resetQuestion(); cancelCalendar(); calendarLink = nil; self.selected = nil; notebook = nil; transcript = nil; duration = 0; refresh() } catch { status = error.localizedDescription }
    }
    func shutdown() {
        stopCallDetection(); cancelLiveSpeakers(); analysisTask?.cancel(); analysisTask = nil; importPicker?.cancel(nil); importWorker?.cancel(); importTask?.cancel(); fixtureTask?.cancel(); searchTask?.cancel(); summaryTask?.cancel(); cancelCatchUp(); cancelQuestion(); cancelCalendar(); processingTask?.cancel(); liveService?.cancel(); liveService = nil; saveLiveProgress(); livePersistence?.flushSynchronously(); liveState.retire(); MeetingSpeakerEngine.stopJobs(); LocalASREngine.stopJobs(); token = UUID(); task?.cancel(); capture?.stop(); capture = nil; writer?.finishSynchronously(); writer = nil; stopPlayback(); timer?.invalidate() }
    /// Dedicated developer app identity only: no microphone or Core Audio tap.
    func startLiveFixture() {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "NeroLiveFixtureAudio") as? String,
              name == "synthetic-live.caf", !fixtureStarted, let root = Bundle.main.resourceURL, let store else { return }
        fixtureStarted = true
        fixtureTask = Task { [self] in
            do {
                asrProvider = .nemotron; liveEnabled = true; notebookPage = "transcript"
                let file = try AVAudioFile(forReading: root.appendingPathComponent(name))
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, file.length <= 30*16000 else { throw VoiceProblem.message("Invalid developer fixture") }
                var value = Meeting(title: "Synthetic live demo · no microphone capture", source: "all", microphone: true)
                value.state = "recording"; try store.save(value); selected = value; notebook = .init(meetingID: value.id); phase = "preparing"; refresh()
                try await beginLive(value); try Task.checkCancellation()
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
    }
}
