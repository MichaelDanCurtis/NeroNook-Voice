import AppKit
import ModuleCore
import VoiceAudio
import Foundation

extension MeetingModel {
    func saveNotes(thoughts: String, summary: String, decisions: String, actions: String, reviewed: Bool) throws {
        guard let selected, let store, !summarizing else { throw VoiceProblem.message("Select a meeting before saving notes.") }
        var value = notebook ?? MeetingNotebook(meetingID: selected.id)
        value.edit(thoughts: thoughts, summary: summary, decisions: decisions, actions: actions, reviewed: reviewed)
        try store.saveNotebook(value); notebook = value; status = "Notes saved on this Mac"
        searchLibrary()
    }
    func openNoteSource(_ id: String) {
        guard !occupied, let selected, let store, let notebook,
              let item = ((notebook.evidence ?? []) + (notebook.actionResolutions ?? []).flatMap(\.evidence)).first(where: { $0.id.uuidString == id }) else { return }
        do {
            // Reread the durable selected variant immediately before navigation.
            let source = showingLiveTranscript ? try store.liveTranscript(selected.id, provider: asrProvider) : try store.transcript(selected.id, provider: asrProvider)
            guard let source else { throw VoiceProblem.message("The source transcript is unavailable. Saved notes are retained.") }
            let line = try item.resolve(in: source, digest: notebook.sourceDigest)
            transcript = source
            let ordered = source.utterances.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
            transcriptPage = (ordered.firstIndex(where: { $0.id == line.id }) ?? 0) / 8
            highlightedUtterance = line.id.uuidString; highlightedSourceText = ""; notebookPage = "transcript"; seek(line.start)
            status = "Opened original source · playback is paused"
        } catch { status = error.localizedDescription }
    }
    func summarize() {
        guard !occupied, canStart?() != false, let selected, let transcript, let store, !transcript.utterances.isEmpty else { status = "Transcribe this recording first."; return }
        stopPlayback(); summarizing = true; processProgress = 0; status = "Creating a local summary · no cloud upload"
        let original = notebook ?? MeetingNotebook(meetingID: selected.id)
        let sourceProvider = asrProvider, sourceWasLive = showingLiveTranscript
        summaryTask = Task { [self] in
            defer { summarizing = false; summaryTask = nil }
            do {
                var result = try await MeetingSummarizer.draft(transcript, meetingID: selected.id) { [weak self] progress in
                    Task { @MainActor in self?.processProgress = progress; self?.changed?() }
                }
                try Task.checkCancellation()
                guard self.selected?.id == selected.id else { throw CancellationError() }
                // Recheck both the visible and durable source after asynchronous model
                // work, before replacing any notes. No stale automatic retry.
                guard self.asrProvider == sourceProvider, self.showingLiveTranscript == sourceWasLive,
                      let current = self.transcript, result.isCurrent(for: current),
                      (self.notebook ?? MeetingNotebook(meetingID: selected.id)) == original else {
                    throw VoiceProblem.message("Transcript or notes changed during summary. Existing notes are retained; review the source and try again.")
                }
                result.thoughts = original.thoughts
                try store.saveGeneratedNotebook(result, replacing: original, provider: sourceProvider, live: sourceWasLive); notebook = result; notebookPage = "notes"; status = "Summary draft saved · review facts, owners and dates"; searchLibrary()
            } catch { status = error is CancellationError ? "Summary stopped · existing notes retained" : error.localizedDescription }
        }
    }
    func searchLibrary() {
        searchTask?.cancel()
        let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines), meetings = Array(library.prefix(500)), store = store
        guard !query.isEmpty else { searchIDs = nil; return }
        searchTask = Task { [weak self] in
            let worker = Task.detached { () -> Set<UUID> in
                var result = Set<UUID>()
                for meeting in meetings {
                    if Task.isCancelled { break }
                    var text = meeting.title
                    if let link = try? store?.calendarLink(meeting.id) { text += "\n" + link.searchableText }
                    if let notebook = try? store?.notebook(meeting.id) { text += "\n" + notebook.searchableText }
                    for provider in MeetingASRProvider.allCases {
                        if let transcript = try? store?.transcript(meeting.id, provider: provider) {
                            text += "\n" + transcript.names.values.joined(separator: " ")
                            for line in transcript.utterances { text += "\n" + (line.correction ?? line.text) }
                        }
                        if let transcript = try? store?.liveTranscript(meeting.id, provider: provider) {
                            for line in transcript.utterances { text += "\n" + (line.correction ?? line.text) }
                        }
                    }
                    if text.localizedCaseInsensitiveContains(query) { result.insert(meeting.id) }
                }
                return result
            }
            let ids = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            self.searchIDs = ids; self.changed?()
        }
    }
    func exportNotes(includeThoughts: Bool) {
        guard let notebook, let selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(notebook.markdown(title: selected.title, includeThoughts: includeThoughts) + (calendarLink?.markdown ?? ""), forType: .string)
        status = includeThoughts ? "Copied notes including My thoughts" : "Copied meeting notes · My thoughts excluded"
    }
}
