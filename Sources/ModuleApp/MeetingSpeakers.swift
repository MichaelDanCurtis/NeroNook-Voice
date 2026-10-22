import Foundation
import ModuleCore
import VoiceAudio

extension MeetingModel {
    func beginSpeakerSession(_ meeting: Meeting) {
        if speakerMeetingID == meeting.id { return } // pause/resume shares identity state
        cancelLiveSpeakers(); speakerMeetingID = meeting.id; liveSpeakers.reset()
        guard speakerSeparation else { speakerStatus = "Speaker separation off"; return }
        guard speakersReady else { speakerStatus = "Prepare Nemotron speakers to label people in both sources"; return }
        guard liveEnabled, asrProvider == .apple else {
            speakerStatus = "Speaker labels after Stop · one MLX model at a time"; return
        }
        let service = MeetingLiveSpeakerAnalyzer(); liveSpeakerService = service
        let epoch = liveSpeakers.epoch
        speakerStatus = "Preparing local speaker labels · audio recording remains independent"
        speakerStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await service.start(update: { [weak self] track, spans, through in
                    guard let self, self.speakerMeetingID == meeting.id, self.liveSpeakers.epoch == epoch else { return }
                    try self.liveSpeakers.receive(track: track, spans: spans, through: through, epoch: epoch)
                    try self.applyLiveSpeakers(); self.speakerStatus = "Live Room / Call speakers · provisional, a few seconds behind words"
                    self.saveLiveProgress(); self.changed?()
                }, failure: { [weak self] message in
                    guard let self, self.liveSpeakers.epoch == epoch else { return }
                    self.speakerStatus = message + " Identify speakers from saved audio afterward."
                })
                guard self.liveSpeakers.epoch == epoch else { service.cancel(); return }
                self.liveSpeakerReady = true; self.attachSpeakerFeed(service.feed)
                self.speakerStatus = "Listening for individual speakers in room and call audio"
            } catch {
                service.cancel()
                guard self.liveSpeakers.epoch == epoch else { return }
                self.liveSpeakerService = nil; self.liveSpeakerReady = false; self.speakerStatus = "Live speaker labels unavailable · " + String(error.localizedDescription.prefix(140)) + ". Saved audio can be analysed afterward."
            }
        }
    }
    func applyLiveSpeakers(final: Bool = false) throws {
        guard let original = transcript, speakerMeetingID == selected?.id else { return }
        transcript = try liveSpeakers.applying(to: original, final: final)
        if final { transcript?.speakerModelRevision = MeetingSpeakerEngine.analysisRevision }
    }
    func finishLiveSpeakers() async -> Bool {
        await speakerStartTask?.value
        guard let service = liveSpeakerService else { return false }
        defer { service.cancel(); liveSpeakerService = nil; liveSpeakerReady = false; speakerStartTask = nil }
        do {
            speakerStatus = "Finishing speaker labels…"
            try await service.finish(); try Task.checkCancellation()
            try applyLiveSpeakers(final: true); saveLiveProgress()
            speakerStatus = "Room and Call speakers saved · review names and uncertain speech"
            return true
        } catch {
            speakerStatus = "Live speaker labels incomplete · " + String(error.localizedDescription.prefix(160))
            return false
        }
    }
    func cancelLiveSpeakers() {
        speakerStartTask?.cancel(); speakerStartTask = nil; liveSpeakerService?.cancel(); liveSpeakerService = nil; liveSpeakerReady = false
        speakerMeetingID = nil; liveSpeakers.reset()
    }
    func chooseSpeakerSeparation(_ enabled: Bool) {
        guard !occupied else { return }; speakerSeparation = enabled; UserDefaults.standard.set(enabled, forKey: "meetingSpeakerSeparation")
        speakerStatus = enabled ? (speakersReady ? "Separate people in both room and call audio" : "Prepare the local speaker model to label people") : "Speaker separation off"
    }
}
