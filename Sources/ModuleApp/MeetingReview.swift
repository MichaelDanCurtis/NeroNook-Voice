import AppKit
import Foundation
import ModuleCore
import VoiceAudio

extension MeetingModel {
    func loadTranscript(preferLive: Bool = false) {
        transcriptPage = 0
        do {
            let refined = try selected.flatMap { try store?.transcript($0.id, provider: asrProvider) }
            let live = try selected.flatMap { try store?.liveTranscript($0.id, provider: asrProvider) }
            hasLiveTranscript = live != nil; hasRefinedTranscript = refined != nil
            showingLiveTranscript = live != nil && (preferLive || refined == nil)
            transcript = showingLiveTranscript ? live : refined
            liveStatus = showingLiveTranscript ? "Saved live draft · speaker identity is not inferred from the track" : ""
        }
        catch { transcript = nil; status = error.localizedDescription }
    }
    func process(_ action: String) {
        if action == "live:on" || action == "live:off" {
            guard !occupied else { return }; liveEnabled = action == "live:on"; UserDefaults.standard.set(liveEnabled, forKey: "meetingLiveEnabled"); return
        }
        if action == "showLive" || action == "showRefined" { guard !occupied else { return }; loadTranscript(preferLive: action == "showLive"); resetCatchUp(); return }
        if action == "cancel" { processingTask?.cancel(); return }
        if action.hasPrefix("asr:"), let provider = MeetingASRProvider(rawValue: String(action.dropFirst(4))) {
            chooseASR(provider); return
        }
        guard !occupied, canStart?() != false else { return }
        if action == "export" { exportTranscript(); return }
        if action == "prepare" {
            processing = true; status = "Preparing Nemotron 3 speakers · 199 MB download…"
            processingTask = Task { [self] in
                defer { processing = false; processingTask = nil; speakersReady = MeetingSpeakerEngine.ready }
                do { try await MeetingSpeakerEngine.prepare(); status = "Speaker model ready · up to eight speakers per track" }
                catch { status = error is CancellationError ? "Preparation cancelled" : error.localizedDescription }
            }; return
        }
        if action == "prepareASR" {
            guard asrProvider != .apple else { return }
            let engine = LocalASREngine(asrProvider)
            processing = true; status = "Preparing \(engine.name) · 756 MB download…"
            processingTask = Task { [self] in
                defer { processing = false; processingTask = nil; parakeetReady = LocalASREngine(.parakeet).ready }
                do { try await engine.prepare(); status = "\(engine.name) ready for meetings and dictation" }
                catch { status = error is CancellationError ? "Preparation cancelled" : error.localizedDescription }
            }; return
        }
        guard ["transcribe", "speakers"].contains(action), let selected, !selected.chunks.isEmpty, let store else { return }
        if action == "transcribe", asrProvider != .apple, !selectedASRReady {
            status = "Prepare the selected model before transcribing. Apple Speech remains available."; return
        }
        processing = true; processProgress = 0
        processingTask = Task { [self] in
            let temporary = store.folder(selected.id).appendingPathComponent("processing-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary); processing = false; processingTask = nil }
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
                guard (try temporary.resourceValues(forKeys: [.volumeAvailableCapacityKey])).volumeAvailableCapacity ?? 0 > Int(selected.duration * 64000) + 100_000_000 else { throw VoiceProblem.message("Not enough free space to process this recording") }
                let provider = asrProvider
                let refined = try store.transcript(selected.id, provider: provider)
                let live = action == "speakers" && (showingLiveTranscript || refined == nil) ? try store.liveTranscript(selected.id, provider: provider) : nil
                let editingLive = live != nil
                var result = live ?? refined ?? MeetingTranscript(
                    locale: provider == .apple ? (locale?() ?? "en-US") : "auto",
                    provider: provider,
                    modelRevision: provider != .apple ? LocalASREngine(provider).revision : nil,
                    runtimeRevision: provider != .apple ? LocalASREngine(provider).runtimeRevision : nil)
                showingLiveTranscript = editingLive
                func saveResult() throws {
                    if editingLive { try store.saveLiveTranscript(result, id: selected.id, provider: provider) }
                    else { try store.saveTranscript(result, id: selected.id, provider: provider) }
                }
                // Re-run unreviewed labels from older speaker models on every track.
                if action == "speakers" || result.speakerModelRevision != MeetingSpeakerEngine.revision { result.labelledTracks = [] }
                let tracks = Set(selected.chunks.map(\.track)).sorted()
                for (index, track) in tracks.enumerated() {
                    try Task.checkCancellation(); let label = track == "mic" ? "microphone" : "call audio"
                    status = "Preparing \(label)…"
                    let audio = temporary.appendingPathComponent(track + ".caf")
                    try await MeetingTranscription.assemble(selected, track: track, store: store, to: audio)
                    if action == "transcribe", !result.completedTracks.contains(track) {
                        status = "Transcribing \(label) on this Mac…"
                        if provider == .apple {
                            result.utterances.removeAll { $0.track == track }; transcript = result
                            var checkpoint = Date.distantPast
                            try await MeetingTranscription.transcribe(audio, track: track, locale: result.locale) { line in
                                guard result.utterances.count < 40000 else { throw VoiceProblem.message("Transcript limit reached") }; result.utterances.append(line)
                                self.processProgress = (Double(index) + min(1, line.end / max(1, selected.duration))) / Double(tracks.count)
                                if Date().timeIntervalSince(checkpoint) > 2 { checkpoint = Date(); try store.saveTranscript(result, id: selected.id, provider: provider); self.transcript = result }
                            }
                        } else {
                            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/" + LocalASREngine(provider).helperName)
                            let lines = try await LocalASREngine(provider).transcribe(audio, track: track, helper: helper, working: temporary) { fraction in
                                self.processProgress = (Double(index) + fraction) / Double(tracks.count)
                            }
                            result.utterances.removeAll { $0.track == track }
                            result.utterances.append(contentsOf: lines)
                        }
                        result.completedTracks.append(track); try saveResult(); transcript = result
                    }
                    if MeetingSpeakerEngine.ready, (action == "speakers" || speakerSeparation), (result.completedTracks.contains(track) || result.utterances.contains(where: { $0.track == track })), (!result.labelledTracks.contains(track) || result.speakerModelRevision != MeetingSpeakerEngine.revision) {
                        status = "Separating speakers in \(label)…"
                        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroDiarization")
                        let spans = try await MeetingSpeakerEngine.identify(audio, helper: helper, working: temporary) { fraction in
                            self.processProgress = (Double(index) + fraction) / Double(tracks.count)
                        }
                        try result.assign(spans, track: track); result.speakerModelRevision = MeetingSpeakerEngine.revision; try saveResult(); transcript = result
                    }
                    try? FileManager.default.removeItem(at: audio)
                }
                processProgress = 1; transcript = result
                if editingLive { hasLiveTranscript = true } else { hasRefinedTranscript = true }
                speakerStatus = "Room / Call speaker labels saved · review names and unassigned speech"
                status = result.labelledTracks.isEmpty ? "Transcript saved. Prepare speakers to add local speaker labels." : "Transcript ready · review speaker labels and any unassigned speech"
            } catch {
                status = error is CancellationError ? "Processing stopped · saved transcript progress is retained" : error.localizedDescription
                loadTranscript()
            }
        }
    }
    func exportTranscript() {
        guard !occupied, let selected, let transcript else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Meeting transcript.md"; panel.title = "Export meeting transcript"; panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = "# \(selected.title)\n\n\(selected.created.formatted())\n\n"
        for line in transcript.utterances.sorted(by: { $0.start < $1.start }) {
            let seconds = Int(line.start); let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            let name = line.speaker.flatMap { transcript.names[$0] } ?? "Unassigned (\(line.track))"
            text += "**[\(time)] \(name)**\n\n\(line.correction ?? line.text)\n\n"
        }
        text += calendarLink?.markdown ?? ""
        do { try Data(text.utf8).write(to: url, options: .atomic); status = "Transcript exported" } catch { status = error.localizedDescription }
    }
    func review(id: String, text: String, speaker: String, editText: Bool) {
        guard !occupied, let selected, let store, var transcript else { return }
        do {
            if id.hasPrefix("name:") {
                let key = String(id.dropFirst(5)); guard MeetingTranscript.validSpeaker(key), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100 else { return }
                transcript.names[key] = text
                for index in transcript.utterances.indices where transcript.utterances[index].speaker == key { transcript.utterances[index].reviewed = true }
            } else {
                guard let uuid = UUID(uuidString: id), let index = transcript.utterances.firstIndex(where: { $0.id == uuid }), text.utf8.count <= 16000,
                      speaker.isEmpty || MeetingTranscript.validSpeaker(speaker) else { return }
                if editText { transcript.utterances[index].correction = text }; transcript.utterances[index].speaker = speaker.isEmpty ? nil : speaker; transcript.utterances[index].reviewed = true
                if !speaker.isEmpty, transcript.names[speaker] == nil { transcript.names[speaker] = speaker.replacingOccurrences(of: "-", with: " speaker ") }
            }
            if showingLiveTranscript { try store.saveLiveTranscript(transcript, id: selected.id, provider: asrProvider) }
            else { try store.saveTranscript(transcript, id: selected.id, provider: asrProvider) }
            self.transcript = transcript; highlightedUtterance = ""; highlightedCitation = ""; highlightedSourceText = ""
            status = "Correction saved · original transcript retained"
        } catch { status = error.localizedDescription }
    }
}
