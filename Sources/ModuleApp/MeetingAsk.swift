import Foundation
import ModuleCore
import VoiceAudio
import NookPluginSDK

extension MeetingModel {
    var chatOwner: UUID? { questionScope == "library" ? nil : selected?.id }
    var chatIdentity: String { questionScope == "library" ? "library" : selected?.id.uuidString ?? "none" }
    var canAskMeeting: Bool { questionScope == "library" ? !active && !folderLibrary.isEmpty : selected != nil && !(transcript?.utterances.isEmpty ?? true) }
    var chatViewTurns: [MeetingQuestionViewState.Turn] {
        let end = max(0, meetingChat.turns.count - chatPage * 2), start = max(0, end - 2)
        return meetingChat.turns[start..<end].map { turn in
            let cited = Set(turn.answer?.statements.flatMap(\.citations) ?? [])
            return .init(id: turn.id.uuidString, question: turn.evidence.question.question, status: turn.status,
                when: turn.created.formatted(date: .abbreviated, time: .shortened), answer: turn.answer,
                sources: turn.evidence.sources.filter { cited.contains($0.evidence.id) }.map { .init(id: $0.evidence.id, label: $0.evidence.label, text: "") })
        }
    }
    func questionCatalog(_ entries: [PluginCatalogEntry]) {
        let matches = entries.filter { PluginEvidenceChatContract.accepts($0) || PluginEvidenceAnswerContract.accepts($0) }
        questionProviders = Dictionary(grouping: matches, by: { $0.address.plugin }).values.compactMap { $0.first(where: PluginEvidenceChatContract.accepts) ?? $0.first }.sorted { $0.address.key < $1.address.key }
        if let pendingQuestionProvider, !questionProviders.contains(pendingQuestionProvider) {
            cancelQuestion(); questionStatus = "Assistant access changed. Pending answer discarded; chat kept."
        }
        if !questionProviders.contains(where: { $0.address.key == questionProvider }) { questionProvider = questionProviders.first?.address.key ?? "" }
    }
    func loadChat() {
        guard !askingQuestion else { return }
        chatPage = 0; chatLoadFailed = false; currentChatTurn = nil
        guard let store, questionScope == "library" || selected != nil else { meetingChat = .init(meetingID: nil); return }
        do {
            var value = try store.chat(chatOwner)
            if value.recoverInterrupted() { try store.saveChat(value) }
            meetingChat = value
        } catch { meetingChat = .init(meetingID: chatOwner); chatLoadFailed = true; questionStatus = "Saved chat needs recovery. Original file kept. \(error.localizedDescription)" }
    }
    func setQuestionScope(_ scope: String) {
        guard permitMeetingWork(), ["meeting", "library"].contains(scope), !askingQuestion, !active, !processing, !summarizing, !calendarBusy else { return }
        resetQuestion(); questionScope = scope; notebookPage = "ask"; calendarPickerOpen = false; loadChat()
    }
    func resetQuestion() {
        cancelQuestion(); questionSnapshot = nil; questionAnswer = nil; questionText = ""; questionStatus = ""; highlightedUtterance = ""; highlightedCitation = ""; highlightedSourceText = ""
    }
    @discardableResult func finishChatTurn(_ phase: String, status: String, answer: PluginEvidenceAnswer? = nil) -> Bool {
        guard let id = currentChatTurn, let i = meetingChat.turns.firstIndex(where: { $0.id == id }) else { return true }
        meetingChat.turns[i].phase = phase; meetingChat.turns[i].status = PluginCalendarContract.bounded(status, bytes: 500); meetingChat.turns[i].answer = answer
        do { try store?.saveChat(meetingChat); currentChatTurn = nil; return true }
        catch { currentChatTurn = nil; questionStatus = "Answer retained in this window, but chat could not be saved: \(error.localizedDescription)"; return false }
    }
    func cancelQuestion(force: Bool = false) {
        if !force, (questionTask != nil || questionRequest != nil), let questionOwner,
           questionOwner != LocalFoundationModelWork.currentOwner { return }
        let originalTask = questionTask
        questionEpoch = UUID(); questionTask?.cancel(); questionTask = nil
        if let questionRequest {
            if let original = capturedMeetingProviders[questionRequest] {
                do { try original.request.cancel() }
                catch { providerCancelIssues[questionRequest] = "cancel-enqueue-failed" }
            } else if captureProviderRequest == nil { cancelQuestionInvocation?(questionRequest) }
            settleMeetingProvider(questionRequest, originalTask: originalTask)
        }
        if currentChatTurn != nil { _ = finishChatTurn("stopped", status: "Question stopped. Already-sent text cannot be recalled.") }
        questionRequest = nil; pendingQuestionProvider = nil; askingQuestion = false
    }
    func prepareQuestion(_ question: String) {
        guard permitMeetingWork() else { return }
        let owner = LocalFoundationModelWork.currentOwner
        guard !importing, !askingQuestion, !processing, !summarizing, !catchingUp, !calendarBusy, !["preparing", "finishing"].contains(phase), canAskMeeting, !chatLoadFailed,
              questionScope != "library" || !active, let store else { questionStatus = "Choose a transcript, or Ask saved meetings when recording is stopped."; return }
        cancelQuestion(); questionSnapshot = nil; questionAnswer = nil; highlightedUtterance = ""; highlightedCitation = ""; highlightedSourceText = ""
        questionOwner = owner
        questionText = question.trimmingCharacters(in: .whitespacesAndNewlines); askingQuestion = true; questionStatus = "Selecting transcript passages on this Mac…"
        let epoch = questionEpoch, provider = asrProvider, live = showingLiveTranscript, meeting = selected, transcript = transcript, identity = chatIdentity
        let scope = questionScope, filter = questionLibraryFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetings = folderLibrary.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }
        let context = questionProviders.first(where: { $0.address.key == questionProvider }).map(PluginEvidenceChatContract.accepts) == true ? meetingChat.context(eligibleMeetings: scope == "library" && folderScope != "all" ? Set(folderLibrary.map(\.id)) : nil) : []
        let text = questionText
        questionTask = Task { [weak self] in
            let worker = Task.detached { () throws -> MeetingChatEvidence in
                if scope == "library" { return try MeetingChatEvidence.library(store: store, meetings: meetings, preferred: provider, question: text, context: context) }
                guard let meeting, let transcript else { throw VoiceProblem.message("This meeting has no settled transcript yet.") }
                return try MeetingChatEvidence.current(meeting: meeting, transcript: transcript, provider: provider, live: live, question: text, context: context)
            }
            do {
                let snapshot = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.questionEpoch == epoch, self.chatIdentity == identity else { return }
                self.questionSnapshot = snapshot; self.askingQuestion = false; self.questionTask = nil
                self.questionStatus = "Ready to send · inspect selected transcripts and \(snapshot.context.count) recent exchanges"
            } catch {
                guard let self, self.questionEpoch == epoch else { return }; self.askingQuestion = false; self.questionTask = nil
                self.questionStatus = error is CancellationError ? "Question stopped" : error.localizedDescription
            }
        }
        retainMeetingTask(questionTask, owner: owner)
    }
    func sendQuestion() {
        guard allowProductEffect(.provider) else{return}
        guard permitMeetingWork() else { return }
        let owner = LocalFoundationModelWork.currentOwner
        guard permitsMeetingProvider() else { questionStatus = "Provider request limit reached; no new request was sent."; return }
        guard !askingQuestion, !chatLoadFailed, let snapshot = questionSnapshot, meetingChat.meetingID == chatOwner,
              let entry = questionProviders.first(where: { $0.address.key == questionProvider }), let invokeQuestion else {
            questionStatus = "Allow a cited-answer assistant for Voice in Nook Settings → Modules."; return
        }
        var reservedRequest: UUID?
        do {
            try snapshot.validate()
            for source in snapshot.sources { _ = try source.resolve(meetingID: source.meetingID, transcript: questionTranscript(source)) }
            let values = PluginEvidenceChatContract.accepts(entry) ? try PluginEvidenceChatContract.values(snapshot.question, history: snapshot.context) : try snapshot.question.values()
            // Reserve the actual context budget before even the local pending
            // chat write. A refused reservation has no file or provider effect.
            let request = UUID(), epoch = UUID()
            let original = captureProviderRequest?(request)
            if let original { capturedMeetingProviders[request] = (owner, original); reservedRequest = request }
            else if captureProviderRequest != nil { throw VoiceProblem.message("The original provider connection is no longer available.") }
            let turn = MeetingChatTurn(evidence: snapshot, assistant: entry.action!.title)
            var next = meetingChat; next.turns.append(turn); try store?.saveChat(next)
            meetingChat = next; currentChatTurn = turn.id; chatPage = 0
            questionOwner = owner
            if original == nil { markMeetingUnverified("provider-local-write-return-unavailable", owner: owner) }
            pendingMeetingProviders[request] = owner; providerEffectUncertain.insert(owner)
            questionEpoch = epoch; questionRequest = request; pendingQuestionProvider = entry; questionAnswer = nil; askingQuestion = true
            questionStatus = "Asking \(entry.action!.title) · previewed text sent to its service…"
            if let original { try original.invoke(address: entry.address, values: values) }
            else { invokeQuestion(request, entry.address, values) }
            questionTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(185))
                guard !Task.isCancelled, let self, self.questionEpoch == epoch, self.questionRequest == request else { return }
                self.cancelQuestion(); self.questionSnapshot = nil; self.questionStatus = "Assistant timed out. Chat and transcript are retained."
            }
            retainMeetingTask(questionTask, owner: owner)
        } catch {
            if let reservedRequest, questionRequest != reservedRequest { settleMeetingProvider(reservedRequest) }
            cancelQuestion(force: true); questionStatus = error.localizedDescription
        }
    }
    func receiveQuestion(_ request: UUID, update: PluginRunUpdate) {
        if update.phase.terminal { settleMeetingProvider(request, originalTask: questionRequest == request ? questionTask : nil) }
        guard questionRequest == request, let entry = pendingQuestionProvider, let snapshot = questionSnapshot, update.phase.terminal else { return }
        questionTask?.cancel(); questionTask = nil; questionRequest = nil; pendingQuestionProvider = nil; askingQuestion = false
        do {
            guard update.phase == .succeeded else { throw VoiceProblem.message(update.message.isEmpty ? "Assistant stopped or unavailable." : String(update.message.prefix(300))) }
            guard questionProviders.contains(entry), meetingChat.meetingID == chatOwner else { throw VoiceProblem.message("Chat or assistant access changed. Answer discarded.") }
            try entry.action!.output.validate(update.values)
            guard case .string(let text) = update.values["answer"] else { throw VoiceProblem.message("The assistant did not return a cited answer.") }
            let answer = try JSONDecoder().decode(PluginEvidenceAnswer.self, from: Data(text.utf8)); try answer.validate(for: snapshot.question)
            for citation in answer.statements.flatMap(\.citations) {
                guard let source = snapshot.sources.first(where: { $0.evidence.id == citation }) else { throw VoiceProblem.message("Unknown transcript source") }
                _ = try source.resolve(meetingID: source.meetingID, transcript: questionTranscript(source))
            }
            questionAnswer = answer
            if finishChatTurn("completed", status: "Saved on this Mac · AI answer, inspect sources", answer: answer) {
                questionStatus = "Chat saved on this Mac · inspect sources and verify important facts"
                questionSnapshot = nil; questionText = ""; questionAnswer = nil
            }
        } catch {
            questionAnswer = nil
            if finishChatTurn(update.phase == .cancelled ? "stopped" : "failed", status: error.localizedDescription) { questionStatus = error.localizedDescription }
            questionSnapshot = nil
        }
    }
    private func questionTranscript(_ source: MeetingChatSource) throws -> MeetingTranscript {
        if source.live, active, selected?.id == source.meetingID, asrProvider == source.provider, let transcript { return transcript }
        _ = try store?.load(source.meetingID)
        let value = source.live ? try store?.liveTranscript(source.meetingID, provider: source.provider) : try store?.transcript(source.meetingID, provider: source.provider)
        guard let value else { throw VoiceProblem.message("The original meeting or transcript variant is unavailable. Saved answer kept.") }; return value
    }
    func inspectChatTurn(_ id: String) {
        guard !askingQuestion, let uuid = UUID(uuidString: id), let turn = meetingChat.turns.first(where: { $0.id == uuid }) else { return }
        questionSnapshot = turn.evidence; questionText = turn.evidence.question.question; questionAnswer = nil
        questionStatus = "Saved exchange · inspect its exact original disclosure; Send asks again after source verification"
    }
    func newMeetingChat(restore: Bool = false) {
        guard permitMeetingWork(), !occupied, let store, !chatLoadFailed, questionScope == "library" || selected != nil else { return }
        do {
            if restore && !store.hasPreviousChat(chatOwner) { throw VoiceProblem.message("No previous conversation to restore.") }
            let next = restore ? try store.chat(chatOwner, previous: true) : MeetingChat(meetingID: chatOwner)
            try store.saveChat(meetingChat, previous: true); try store.saveChat(next)
            resetQuestion(); loadChat(); questionStatus = restore ? "Previous chat restored" : "New chat · previous conversation remains recoverable"
        } catch { questionStatus = error.localizedDescription }
    }
    func openQuestionSource(_ citation: String, turn: String = "") {
        guard permitMeetingWork(), !askingQuestion, !processing, !summarizing, let store else { return }
        let saved = UUID(uuidString: turn).flatMap { id in meetingChat.turns.first { $0.id == id }?.evidence }
        guard turn.isEmpty || saved != nil else { questionStatus = "Saved exchange unavailable. Its source was not opened."; return }
        guard let evidence = saved ?? questionSnapshot, let source = evidence.sources.first(where: { $0.evidence.id == citation }) else { return }
        do {
            let original = try questionTranscript(source), line = try source.resolve(meetingID: source.meetingID, transcript: original)
            highlightedCitation = citation
            guard !active else { questionSnapshot = evidence; questionStatus = "Inspect the exact excerpt; recording continues"; return }
            stopPlayback(); selected = try store.load(source.meetingID); duration = selected?.duration ?? 0
            asrProvider = source.provider; storeMeetingPreference(asrProvider.rawValue, forKey: "meetingASRProvider")
            showingLiveTranscript = source.live; transcript = original
            hasLiveTranscript = (try? store.liveTranscript(source.meetingID, provider: source.provider)) != nil
            hasRefinedTranscript = (try? store.transcript(source.meetingID, provider: source.provider)) != nil
            notebook = try? store.notebook(source.meetingID); loadCalendarLink()
            let ordered = original.utterances.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
            transcriptPage = (ordered.firstIndex(where: { $0.id == line.id }) ?? 0) / 8
            highlightedUtterance = line.id.uuidString; highlightedSourceText = source.evidence.text; notebookPage = "transcript"; seek(line.start)
            questionStatus = "Opened \(source.title) · original \(source.live ? "live draft" : "refined transcript") passage"
        } catch { questionStatus = error.localizedDescription }
    }
}
