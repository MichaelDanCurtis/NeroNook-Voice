import AppKit
import Foundation
import ModuleCore
import VoiceAudio

extension MeetingModel {
    func loadTranscript() {
        transcriptPage = 0
        do { transcript = try selected.flatMap { try store?.transcript($0.id) } }
        catch { transcript = nil; status = error.localizedDescription }
    }
    func process(_ action: String) {
        if action == "cancel" { processingTask?.cancel(); return }
        guard !occupied, canStart?() != false else { return }
        if action == "export" { exportTranscript(); return }
        if action == "prepare" {
            processing = true; status = "Preparing local speaker model · 236 MB download…"
            processingTask = Task { [self] in
                defer { processing = false; processingTask = nil; speakersReady = MeetingSpeakerEngine.ready }
                do { try await MeetingSpeakerEngine.prepare(); status = "Speaker model ready · up to four speakers per track" }
                catch { status = error is CancellationError ? "Preparation cancelled" : error.localizedDescription }
            }; return
        }
        guard ["transcribe", "speakers"].contains(action), let selected, !selected.chunks.isEmpty, let store else { return }
        processing = true; processProgress = 0
        processingTask = Task { [self] in
            let temporary = store.folder(selected.id).appendingPathComponent("processing-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary); processing = false; processingTask = nil }
            do {
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
                guard (try temporary.resourceValues(forKeys: [.volumeAvailableCapacityKey])).volumeAvailableCapacity ?? 0 > Int(selected.duration * 64000) + 100_000_000 else { throw VoiceProblem.message("Not enough free space to process this recording") }
                var result = try store.transcript(selected.id) ?? MeetingTranscript(locale: locale?() ?? "en-US")
                let tracks = Set(selected.chunks.map(\.track)).sorted()
                for (index, track) in tracks.enumerated() {
                    try Task.checkCancellation(); let label = track == "mic" ? "microphone" : "call audio"
                    status = "Preparing \(label)…"
                    let audio = temporary.appendingPathComponent(track + ".caf")
                    try await MeetingTranscription.assemble(selected, track: track, store: store, to: audio)
                    if action == "transcribe", !result.completedTracks.contains(track) {
                        result.utterances.removeAll { $0.track == track }; transcript = result
                        var checkpoint = Date.distantPast
                        status = "Transcribing \(label) on this Mac…"
                        try await MeetingTranscription.transcribe(audio, track: track, locale: result.locale) { line in
                            guard result.utterances.count < 40000 else { throw VoiceProblem.message("Transcript limit reached") }; result.utterances.append(line)
                            self.processProgress = (Double(index) + min(1, line.end / max(1, selected.duration))) / Double(tracks.count)
                            if Date().timeIntervalSince(checkpoint) > 2 { checkpoint = Date(); try store.saveTranscript(result, id: selected.id); self.transcript = result }
                        }
                        result.completedTracks.append(track); try store.saveTranscript(result, id: selected.id); transcript = result
                    }
                    if MeetingSpeakerEngine.ready, result.completedTracks.contains(track), !result.labelledTracks.contains(track) {
                        status = "Separating speakers in \(label)…"
                        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroDiarization")
                        let spans = try await MeetingSpeakerEngine.identify(audio, helper: helper, working: temporary) { fraction in
                            self.processProgress = (Double(index) + fraction) / Double(tracks.count)
                        }
                        try result.assign(spans, track: track); try store.saveTranscript(result, id: selected.id); transcript = result
                    }
                    try? FileManager.default.removeItem(at: audio)
                }
                processProgress = 1; transcript = result
                status = result.labelledTracks.isEmpty ? "Transcript saved. Prepare speakers to add local speaker labels." : "Transcript ready · review speaker labels and any unassigned speech"
            } catch {
                status = error is CancellationError ? "Processing stopped · saved transcript progress is retained" : error.localizedDescription
                transcript = try? store.transcript(selected.id)
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
        do { try Data(text.utf8).write(to: url, options: .atomic); status = "Transcript exported" } catch { status = error.localizedDescription }
    }
    func review(id: String, text: String, speaker: String, editText: Bool) {
        guard !occupied, let selected, let store, var transcript else { return }
        do {
            if id.hasPrefix("name:") {
                let key = String(id.dropFirst(5)); guard MeetingTranscript.validSpeaker(key), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100 else { return }
                transcript.names[key] = text
            } else {
                guard let uuid = UUID(uuidString: id), let index = transcript.utterances.firstIndex(where: { $0.id == uuid }), text.utf8.count <= 16000,
                      speaker.isEmpty || MeetingTranscript.validSpeaker(speaker) else { return }
                if editText { transcript.utterances[index].correction = text }; transcript.utterances[index].speaker = speaker.isEmpty ? nil : speaker; transcript.utterances[index].reviewed = true
                if !speaker.isEmpty, transcript.names[speaker] == nil { transcript.names[speaker] = speaker.replacingOccurrences(of: "-", with: " speaker ") }
            }
            try store.saveTranscript(transcript, id: selected.id); self.transcript = transcript; status = "Correction saved · original transcript retained"
        } catch { status = error.localizedDescription }
    }
}
