import Foundation
import ModuleCore
import VoiceAudio

extension MeetingModel {
    func beginLive(_ meeting: Meeting, feed: MeetingLiveAudioFeed = MeetingLiveAudioFeed(), allowPreparingFixture: Bool = false) async throws {
        try configuration.require(.model)
        let currentOwner = LocalFoundationModelWork.currentOwner
        let recordingToken = token
        func requireCurrent() throws {
            try Task.checkCancellation()
            guard token == recordingToken, (phase == "recording" || (allowPreparingFixture && fixtureStarted && phase == "preparing")), !nativeClosing else { throw CancellationError() }
        }
        try requireCurrent()
        liveService?.cancel(); liveService = nil; liveState.retire()
        if let error = await drainLiveFilePersistence() { liveStatus = "Live words could not be saved: \(error) Audio is retained." }
        try requireCurrent()
        livePersistence = nil; livePersistenceMeeting = nil; livePersistenceOwner = nil; livePersistenceCallbacks = nil
        guard liveEnabled else { feed.finish(); liveStatus = "Audio-only recording · transcribe afterward"; return }
        let provider = asrProvider
        guard provider == .apple || selectedASRReady else {
            feed.finish(); liveStatus = "\(provider.title) is not downloaded. Recording audio only; no model fallback."; return
        }
        let tracks = Set((meeting.microphone ? ["mic"] : []) + (meeting.source != "none" ? ["system"] : []))
        let prior = try store?.liveTranscript(meeting.id, provider: provider)
        try requireCurrent()
        let epoch = try liveState.begin(tracks: tracks, offset: meeting.duration, prior: prior?.utterances ?? [])
        transcript = prior ?? MeetingTranscript(locale: provider == .apple ? (locale?() ?? "en-US") : "auto", provider: provider,
            modelRevision: provider == .apple ? nil : LocalASREngine(provider).revision,
            runtimeRevision: provider == .apple ? nil : LocalASREngine(provider).runtimeRevision)
        try requireCurrent()
        showingLiveTranscript = true; liveCheckpoint = .distantPast
        try requireCurrent()
        if let store {
            livePersistenceMeeting = meeting.id; livePersistenceOwner = currentOwner
            let callbacks = VoiceAudioCallbackAdmission(); livePersistenceCallbacks = callbacks
            livePersistence = MeetingTranscriptCheckpoints(store: store) { [weak self] id, message in
                guard let entered = callbacks.enter() else { return }
                Task { @MainActor in
                    defer { entered.finish() }
                    guard let self, self.selected?.id == id, self.liveState.epoch == epoch else { return }
                    self.liveStatus = "Live words could not be saved: \(message) Audio remains separate."
                }
            }
        }
        try requireCurrent()
        let service = MeetingLiveTranscriber(feed: feed); liveService = service
        liveStatus = "Preparing \(provider.title) for live words…"
        do {
            try requireCurrent()
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroASR")
            try await service.start(provider: provider, tracks: tracks, locale: locale?() ?? "en-US", helper: helper) { [weak self] update in
                guard let self, self.selected?.id == meeting.id, self.liveState.active, self.liveState.epoch == epoch else { return }
                let settled = try self.liveState.receive(update, epoch: epoch)
                if settled {
                    self.transcript?.utterances = self.liveState.settled
                    try self.applyLiveSpeakers()
                    self.hasLiveTranscript = true
                    if Date().timeIntervalSince(self.liveCheckpoint) > 2 { self.liveCheckpoint = Date(); self.saveLiveProgress() }
                }
                self.changed?()
            } failure: { [weak self] message in
                guard let self, self.liveState.epoch == epoch else { return }
                self.saveLiveProgress(); self.liveState.retire(); self.liveStatus = message
            }
            guard liveState.epoch == epoch else { await service.cancelAndWait(); throw CancellationError() }
            liveStatus = provider == .parakeet ? "Live segments · Parakeet · updates at pauses or every 10 seconds" : "Live words · \(provider.title) · local"
        } catch {
            await service.cancelAndWait()
            guard liveState.epoch == epoch else { throw CancellationError() }
            liveService = nil; liveState.retire()
            if Task.isCancelled { throw CancellationError() }
            liveStatus = "Live words unavailable: \(error.localizedDescription) Audio recording continues."
        }
    }
    // A flush returns after the actual serial checkpoint writer; error
    // callbacks accepted by that writer retain their MainActor deliveries.
    func drainLiveFilePersistence() async -> String? {
        let original = livePersistence, callbacks = livePersistenceCallbacks, owner = livePersistenceOwner
        var failure: String?
        do { try await original?.flush() } catch { failure = error.localizedDescription }
        callbacks?.seal(); callbacks?.nativeStopReturned()
        await callbacks?.waitForReturn()
        if failure != nil, let owner { meetingFileUncertain.insert(owner) }
        return failure
    }
    func saveLiveProgress() {
        guard showingLiveTranscript, let transcript, let selected, livePersistenceMeeting == selected.id else { return }
        livePersistence?.save(transcript, id: selected.id, provider: asrProvider)
    }
    func resetCatchUp() { cancelCatchUp(); catchUpNotes = nil; catchUpRange = ""; catchUpStatus = "" }
    func cancelCatchUp(force: Bool = false) {
        if !force, catchUpTask != nil, let catchUpOwner, catchUpOwner != LocalFoundationModelWork.currentOwner { return }
        catchUpEpoch = UUID(); catchUpTask?.cancel(); catchUpTask = nil; catchingUp = false }
    func catchUp(seconds: Double) {
        guard allowProductEffect(.model) else{return}
        guard permitMeetingWork() else { return }
        let owner = LocalFoundationModelWork.currentOwner
        guard !catchingUp, !summarizing, !processing, let selected, let transcript else { catchUpStatus = "Wait for settled words first."; return }
        do{try transcript.requireResolvedTranscription()}catch{catchUpStatus=error.localizedDescription;return}
        let end = transcript.utterances.map(\.end).max() ?? 0
        do {
            let window = try MeetingCatchUpWindow(meetingID: selected.id, transcript: transcript, through: end, seconds: seconds)
            guard MeetingSummarizer.available else { catchUpStatus = "Enable Apple Intelligence for local catch-up. The live transcript is still available."; return }
            catchingUp = true; catchUpStatus = phase == "recording" ? "Catching up on this Mac · recording continues" : "Catching up on this Mac"
            let epoch = UUID(); catchUpEpoch = epoch; catchUpOwner = owner
            catchUpTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.catchUpEpoch == epoch { self.catchingUp = false; self.catchUpTask = nil } }
                do {
                    let notes = try await MeetingSummarizer.catchUp(window)
                    try Task.checkCancellation(); guard self.catchUpEpoch == epoch, self.selected?.id == window.meetingID else { return }
                    self.catchUpNotes = notes
                    self.catchUpRange = "\(clock(window.start))–\(clock(window.end)) · settled words only" + (window.truncated ? " · newest turns within the local context limit" : "")
                    self.catchUpStatus = "Key moments · exact transcript excerpts. Recognition can be wrong; no cloud upload."
                } catch {
                    if self.catchUpEpoch == epoch { self.catchUpStatus = error is CancellationError ? "Catch-up stopped · previous draft kept" : error.localizedDescription }
                }
            }
            retainMeetingTask(catchUpTask, owner: owner)
        } catch { catchUpStatus = error.localizedDescription }
    }
    private func clock(_ seconds: Double) -> String {
        let time = Int(seconds); return String(format: "%02d:%02d", time / 60, time % 60)
    }
}
