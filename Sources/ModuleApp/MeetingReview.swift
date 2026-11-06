import AppKit
import Foundation
import ModuleCore
import VoiceAudio

extension MeetingModel {
    func loadTranscript(preferLive: Bool = false) {
        transcriptPage = 0
        do {
            guard let selected,let store else{
                transcript=nil;hasLiveTranscript=false;hasRefinedTranscript=false;showingLiveTranscript=false;liveStatus="";return
            }
            let loaded=try SavedMeetingTrackProcessor.loadPresentation(store:store,meetingID:selected.id,provider:asrProvider,preferLive:preferLive)
            transcript=loaded.transcript;hasLiveTranscript=loaded.hasLive;hasRefinedTranscript=loaded.hasRefined;showingLiveTranscript=loaded.showingLive
            liveStatus = showingLiveTranscript ? "Saved live draft · speaker identity is not inferred from the track" : ""
        }
        catch {
            transcript=nil;liveStatus="";status=error.localizedDescription
            if preferLive { showingLiveTranscript=true } // Keep an already available Refined button usable after live refusal.
            else {hasLiveTranscript=false;hasRefinedTranscript=false;showingLiveTranscript=false}
        }
    }

    func process(_ action: String) {
        guard permitMeetingWork() else { return }
        if action == "live:on" || action == "live:off" {
            guard !occupied else { return }; liveEnabled = action == "live:on"; storeMeetingPreference(liveEnabled, forKey: "meetingLiveEnabled"); return
        }
        if action == "showLive" || action == "showRefined" { guard !occupied else { return }; loadTranscript(preferLive: action == "showLive"); resetCatchUp(); return }
        if action == "cancel" {
            if processingOwner == LocalFoundationModelWork.currentOwner { processingTask?.cancel() }
            return
        }
        if action.hasPrefix("asr:"), let provider = MeetingASRProvider(rawValue: String(action.dropFirst(4))) {
            chooseASR(provider); return
        }
        guard allowProductEffect(.model) else{return}
        guard permitMeetingWork(), !occupied, canStart?() != false else { return }
        let owner = LocalFoundationModelWork.currentOwner
        if action == "export" { exportTranscript(); return }
        if action == "prepare" {
            let reason = "speaker-preparation-original-worker-" + UUID().uuidString
            let cleanup = MeetingCleanupReceipt()
            processingOwner = owner; markMeetingUnverified(reason, owner: owner)
            processing = true; status = "Preparing Nemotron 3 speakers · 199 MB download…"
            guard ownedMeetingTasks.permits(owner), !nativeClosing else {
                processing = false; resolveMeetingUnverified(reason, owner: owner); return
            }
            processingTask = Task { [self] in
                defer { processing = false; processingTask = nil; speakersReady = MeetingSpeakerEngine.ready }
                do { try Task.checkCancellation(); try await MeetingCleanupContext.$current.withValue(cleanup) { try await MeetingSpeakerEngine.prepare() }; status = "Speaker model ready · up to eight speakers per track" }
                catch { status = error is CancellationError ? "Preparation cancelled" : error.localizedDescription }
            }
            let original = processingTask
            retainMeetingTask(original, owner: owner)
            let settlement = Task { @MainActor [self] in
                await original?.value
                if let issue = cleanup.issue { markMeetingUnverified(reason + ":" + issue, owner: owner) }
                resolveMeetingUnverified(reason, owner: owner)
            }
            retainMeetingTask(settlement, owner: owner); return
        }
        if action == "prepareASR" {
            guard asrProvider != .apple else { return }
            let engine = LocalASREngine(asrProvider)
            let reason = "asr-preparation-original-worker-" + UUID().uuidString
            let cleanup = MeetingCleanupReceipt()
            processingOwner = owner; markMeetingUnverified(reason, owner: owner)
            processing = true; status = "Preparing \(engine.name) · 756 MB download…"
            guard ownedMeetingTasks.permits(owner), !nativeClosing else {
                processing = false; resolveMeetingUnverified(reason, owner: owner); return
            }
            processingTask = Task { [self] in
                defer { processing = false; processingTask = nil; parakeetReady = LocalASREngine(.parakeet).ready }
                do { try Task.checkCancellation(); try await MeetingCleanupContext.$current.withValue(cleanup) { try await engine.prepare() }; status = "\(engine.name) ready for meetings and dictation" }
                catch { status = error is CancellationError ? "Preparation cancelled" : error.localizedDescription }
            }
            let original = processingTask
            retainMeetingTask(original, owner: owner)
            let settlement = Task { @MainActor [self] in
                await original?.value
                if let issue = cleanup.issue { markMeetingUnverified(reason + ":" + issue, owner: owner) }
                resolveMeetingUnverified(reason, owner: owner)
            }
            retainMeetingTask(settlement, owner: owner); return
        }
        guard ["transcribe", "speakers"].contains(action), let selected, !selected.chunks.isEmpty, let store else { return }
        if action == "transcribe", asrProvider != .apple, !selectedASRReady {
            status = "Prepare the selected model before transcribing. Apple Speech remains available."; return
        }
        let reason = "saved-asr-or-speaker-original-worker-" + UUID().uuidString
        let cleanup = MeetingCleanupReceipt()
        processingOwner = owner; markMeetingUnverified(reason, owner: owner)
        processing = true; processProgress = 0
        guard ownedMeetingTasks.permits(owner), !nativeClosing else {
            processing = false; resolveMeetingUnverified(reason, owner: owner); return
        }
        processingTask = Task { [self] in
            await MeetingCleanupContext.$current.withValue(cleanup) { [self] in
            let temporary = store.folder(selected.id).appendingPathComponent("processing-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary); processing = false; processingTask = nil }
            do {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
                guard (try temporary.resourceValues(forKeys: [.volumeAvailableCapacityKey])).volumeAvailableCapacity ?? 0 > Int(selected.duration * 64000) + 100_000_000 else { throw VoiceProblem.message("Not enough free space to process this recording") }
                let provider = asrProvider
                let refined = action == "speakers" ? try store.transcript(selected.id, provider: provider) : nil
                let live = action == "speakers" && (showingLiveTranscript || refined == nil) ? try store.liveTranscript(selected.id, provider: provider) : nil
                let editingLive = live != nil
                let recognitionLocale=provider == .apple ? (locale?() ?? "en-US") : "auto"
                let recognitionModel=provider != .apple ? LocalASREngine(provider).revision : nil
                let recognitionRuntime=provider != .apple ? LocalASREngine(provider).runtimeRevision : nil
                var result:MeetingTranscript
                if action == "transcribe" {
                    result=try SavedMeetingTrackProcessor.prepareTranscription(store:store,meetingID:selected.id,provider:provider,locale:recognitionLocale,modelRevision:recognitionModel,runtimeRevision:recognitionRuntime)
                } else {
                    result=try live ?? refined ?? store.prepareNewTranscript(selected.id,provider:provider,locale:recognitionLocale,modelRevision:recognitionModel,runtimeRevision:recognitionRuntime)
                }
                if action == "speakers" { try result.requireResolvedTranscription() }
                showingLiveTranscript = editingLive
                func saveResult() throws {
                    if editingLive { try store.saveLiveTranscript(result, id: selected.id, provider: provider) }
                    else { result = try store.saveTranscript(result, id: selected.id, provider: provider) }
                }
                // Re-run unreviewed labels from older speaker models on every track.
                if action == "speakers" || result.speakerModelRevision != MeetingSpeakerEngine.analysisRevision { result.labelledTracks = [] }
                let tracks = Set(selected.chunks.map(\.track)).sorted()
                for (index, track) in tracks.enumerated() {
                    try Task.checkCancellation(); let label = track == "mic" ? "microphone" : "call audio"
                    status = "Preparing \(label)…"
                    try Task.checkCancellation(); guard ownedMeetingTasks.permits(owner) else { throw CancellationError() }
                    let audio = temporary.appendingPathComponent(track + ".caf")
                    if action == "transcribe", !result.completedTracks.contains(track) {
                        var checkpoint = Date.distantPast
                        let transcriptionLocale=result.locale
                        result = try await SavedMeetingTrackProcessor.run(transcript:result,meetingID:selected.id,track:track,provider:provider,
                            modelRevision: provider == .apple ? nil : LocalASREngine(provider).revision,
                            runtimeRevision: provider == .apple ? nil : LocalASREngine(provider).runtimeRevision,
                            assemble: { try await MeetingTranscription.assemble(selected,track:track,store:store,to:audio);self.status="Transcribing \(label) on this Mac…" },
                            apple: { emit in try await MeetingTranscription.transcribe(audio,track:track,locale:transcriptionLocale,result:emit) },
                            local: {
                                let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/"+LocalASREngine(provider).helperName)
                                return try await LocalASREngine(provider).transcribe(audio,track:track,helper:helper,working:temporary) { fraction in
                                    self.processProgress=(Double(index)+fraction)/Double(tracks.count)
                                }
                            },
                            checkpointDue: { if Date().timeIntervalSince(checkpoint)>2 {checkpoint=Date();return true};return false },
                            save: { try store.saveTranscript($0,id:selected.id,provider:provider) },
                            publish: { self.transcript=$0 },
                            requireCurrent: { guard self.ownedMeetingTasks.permits(owner),!self.nativeClosing else{throw CancellationError()} },
                            didReceive: { line in self.processProgress=(Double(index)+min(1,line.end/max(1,selected.duration)))/Double(tracks.count) })
                        transcript=result
                    } else {
                        try await MeetingTranscription.assemble(selected,track:track,store:store,to:audio)
                    }
                    if !result.hasPendingTranscription, MeetingSpeakerEngine.ready, (action == "speakers" || speakerSeparation), (result.completedTracks.contains(track) || result.utterances.contains(where: { $0.track == track })), (!result.labelledTracks.contains(track) || result.speakerModelRevision != MeetingSpeakerEngine.analysisRevision) {
                        status = "Separating speakers in \(label)…"
                        try Task.checkCancellation(); guard ownedMeetingTasks.permits(owner) else { throw CancellationError() }
                        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroDiarization")
                        let spans = try await MeetingSpeakerEngine.identify(audio, helper: helper, working: temporary) { fraction in
                            self.processProgress = (Double(index) + fraction) / Double(tracks.count)
                        }
                        try result.assign(spans, track: track); result.speakerModelRevision = MeetingSpeakerEngine.analysisRevision; try saveResult(); transcript = result
                    }
                    try? FileManager.default.removeItem(at: audio)
                }
                processProgress = 1; transcript = result
                if editingLive { hasLiveTranscript = true } else { hasRefinedTranscript = true }
                speakerStatus = "Room / Call speaker labels saved · review names and unassigned speech"
                status = result.hasPendingTranscription ? "Recognition complete · \(result.pendingTranscriptionCount) passages need review; your corrections are retained." : result.labelledTracks.isEmpty ? "Transcript saved. Prepare speakers to add local speaker labels." : "Transcript ready · review speaker labels and any unassigned speech"
            } catch {
                status = error is CancellationError ? "Processing stopped · saved transcript progress is retained" : error.localizedDescription
                loadTranscript()
            }
            }
        }
        let original = processingTask
        retainMeetingTask(original, owner: owner)
        let settlement = Task { @MainActor [self] in
            await original?.value
            if let issue = cleanup.issue { markMeetingUnverified(reason + ":" + issue, owner: owner) }
            resolveMeetingUnverified(reason, owner: owner)
        }
        retainMeetingTask(settlement, owner: owner)
    }
    func exportTranscript() {
        guard allowProductEffect(.externalFiles) else{return}
        guard permitMeetingWork(), exportPanel == nil, !occupied, let selected, let transcript else { return }
        let owner = LocalFoundationModelWork.currentOwner
        guard meetingFileTasks.permits(owner) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Meeting transcript.md"; panel.title = "Export meeting transcript"; panel.canCreateDirectories = true
        let completion = MeetingFileCompletion()
        exportPanel = panel; exportOwner = owner; exportCompletion = completion
        let original = Task { await completion.wait() }
        meetingFileTasks.retain(original, owner: owner)
        defer {
            if exportPanel === panel { exportPanel = nil; exportOwner = nil; exportCompletion = nil }
            completion.finish()
        }
        NSApp.activate(ignoringOtherApps: true)
        guard exportPanel === panel, meetingFileTasks.permits(owner) else { return }
        guard panel.runModal() == .OK, exportPanel === panel, meetingFileTasks.permits(owner), let url = panel.url else { return }
        var text = "# \(selected.title)\n\n\(selected.created.formatted())\n\n"
        for line in transcript.utterances.sorted(by: { $0.start < $1.start }) {
            let seconds = Int(line.start); let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            let alternative=transcript.isKeptRecognitionAlternative(line.id) ? " · " + MeetingTranscript.keptRecognitionAlternativeLabel : ""
            let name = line.speaker.flatMap { transcript.names[$0] } ?? "Unassigned (\(line.track))"
            text += "**[\(time)] \(name)\(alternative)**\n\n\(line.correction ?? line.text)\n\n"
        }
        text += transcript.pendingTranscriptionText
        text += calendarLink?.markdown ?? ""
        do { try Data(text.utf8).write(to: url, options: .atomic); status = "Transcript exported" }
        catch { meetingFileUncertain.insert(owner); status = error.localizedDescription }
    }
    func review(id: String, text: String, speaker: String, editText: Bool) {
        guard permitMeetingWork(), !occupied, let selected, let store, var transcript else { return }
        do {
            if id.hasPrefix("name:") {
                let key = String(id.dropFirst(5)); guard MeetingTranscript.validSpeaker(key), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100 else { return }
                transcript.names[key] = text
                for index in transcript.utterances.indices where transcript.utterances[index].speaker == key { transcript.utterances[index].reviewed = true }
            } else {
                guard let uuid = UUID(uuidString: id), let index = transcript.utterances.firstIndex(where: { $0.id == uuid }), text.utf8.count <= 16000,
                      speaker.isEmpty || MeetingTranscript.validSpeaker(speaker) else { return }
                if editText { transcript.utterances[index].correction = text }; transcript.utterances[index].speaker = speaker.isEmpty ? nil : speaker; transcript.utterances[index].reviewed = true
                if !speaker.isEmpty, transcript.names[speaker] == nil {
                    let number = (Int(speaker.suffix(1)) ?? 0) + 1
                    transcript.names[speaker] = "\(speaker.hasPrefix("mic-") ? "Room" : "Call") speaker \(number)"
                }
            }
            if showingLiveTranscript { try store.saveLiveTranscript(transcript, id: selected.id, provider: asrProvider) }
            else { transcript = try store.saveTranscript(transcript, id: selected.id, provider: asrProvider) }
            self.transcript = transcript; highlightedUtterance = ""; highlightedCitation = ""; highlightedSourceText = ""
            status = "Correction saved · original transcript retained"
        } catch { status = error.localizedDescription }
    }
}
