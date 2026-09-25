import AppKit
import AVFoundation
import Combine
import ModuleCore
import VoiceAudio
import NookPluginSDK

@MainActor final class MeetingModel: ObservableObject {
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
    var processingTask: Task<Void, Never>?
    var locale: (() -> String)?
    var occupied: Bool { active || processing }
    var changed: (() -> Void)?
    var canStart: (() -> Bool)?
    var microphone: (() -> String)?
    let store: MeetingStore?
    private var writer: MeetingAudioWriter?
    private var capture: MeetingCapture?
    private var task: Task<Void, Never>?
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
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeroVoice/Meetings", isDirectory: true)
        store = try? MeetingStore(root: root)
        objectWillChange.throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true).sink { [weak self] _ in Task { @MainActor in self?.changed?() } }.store(in: &observations)
        guard !CommandLine.arguments.contains("--protocol-test") else { return }
        if let store {
            for value in store.list() where ["recording", "paused"].contains(value.state) { _ = try? MeetingAudioWriter.recover(value, store: store) }
        } else { status = "Cannot open the meeting library" }
        refresh(); refreshSources()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in Task { @MainActor in self?.playbackTick() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.shutdown() } }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            lifecycle.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
                self?.stopPlayback(); if self?.active == true { self?.finish(paused: false, issue: "Stopped for sleep or screen lock.") }
            } })
        }
    }
    func refreshSources() {
        sources = MeetingSources.available().map { source in
            let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == source.id }?.localizedName ?? source.name
            return .init(id: source.id, name: name)
        }
    }
    func refresh() { library = store?.list() ?? []; if let id = selected?.id { selected = library.first { $0.id == id } } }
    func select(_ id: UUID) { guard !occupied else { return }; stopPlayback(); selected = library.first { $0.id == id }; duration = selected?.duration ?? 0; playhead = 0; loadTranscript() }
    func start(title: String, mic: Bool, source: String) {
        guard !occupied, canStart?() != false, let store else { status = "Finish dictation before starting a meeting"; return }
        guard mic || source != "none", source == "none" || source == "all" || sources.contains(where: { $0.id == source }) else { status = "Choose a recording source"; return }
        stopPlayback()
        let value = Meeting(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))" : title, source: source, microphone: mic)
        do { try store.save(value); selected = value; transcript = nil; transcriptPage = 0; duration = 0; refresh(); begin(value) } catch { status = error.localizedDescription }
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
                let writer = try MeetingAudioWriter(store: store, meeting: value); self.writer = writer
                let capture = MeetingCapture(); self.capture = capture
                started = ProcessInfo.processInfo.systemUptime
                try capture.start(microphone: microphone?().isEmpty == false ? microphone?() : nil, includeMicrophone: value.microphone,
                                  systemSource: value.source, writer: writer, offset: value.duration) { [weak self] error in self?.finish(paused: false, issue: error) }
                for _ in 0..<80 {
                    try Task.checkCancellation(); guard generation == token else { return }
                    let state = writer.snapshot(); if let error = state.error { throw VoiceProblem.message(error) }
                    if (!value.microphone || state.last["mic"] != nil) && (value.source == "none" || state.last["system"] != nil) {
                        phase = "recording"; status = "Recording · saved on this Mac"; return
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw VoiceProblem.message("A selected source is not delivering audio. Check its permission or choose another source.")
            } catch { if generation == token { finish(paused: false, issue: error.localizedDescription) } }
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
        guard active, phase != "finishing" else { return }
        phase = "finishing"; token = UUID(); task?.cancel(); capture?.stop(); capture = nil
        let writer = self.writer; levels = [:]
        task = Task { [self] in
            do {
                if let writer { selected = try await writer.finish(state: issue.isEmpty ? (paused ? "paused" : "saved") : "interrupted", issue: issue) }
                else if var value = selected, let store { value.state = issue.isEmpty ? (paused ? "paused" : "saved") : "interrupted"; value.issue = issue; try store.save(value); selected = value }
                self.writer = nil; refresh(); duration = selected?.duration ?? 0; phase = paused && issue.isEmpty ? "paused" : "idle"
                status = issue.isEmpty ? (paused ? "Paused · recording saved" : "Meeting saved · ready to play") : issue
            } catch { phase = "idle"; status = "Recording stopped. Recovery needed: \(error.localizedDescription)"; refresh() }
        }
    }
    func bookmark() { guard phase == "recording" else { return }; writer?.mark("Bookmark"); status = "Bookmark added" }
    func stopPlayback() { players.values.forEach { $0.stop() }; players = [:]; playing = false }
    func play() {
        guard !active, let meeting = selected, !meeting.chunks.isEmpty else { return }
        if playing { stopPlayback(); return }
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
        do { try FileManager.default.trashItem(at: store.folder(selected.id), resultingItemURL: nil); self.selected = nil; transcript = nil; duration = 0; refresh() } catch { status = error.localizedDescription }
    }
    func shutdown() { processingTask?.cancel(); MeetingSpeakerEngine.stopJobs(); token = UUID(); task?.cancel(); capture?.stop(); capture = nil; writer?.finishSynchronously(); writer = nil; stopPlayback(); timer?.invalidate() }
}
