import SwiftUI
import ModuleCore
import VoiceAudio
import NookPluginSDK

extension MeetingModel {
    var definition: PluginCustomView {
        func json<T: Encodable>(_ value: T) -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? "[]"
        }
        let matches = folderLibrary.filter { libraryQuery.isEmpty || (searchIDs?.contains($0.id) ?? $0.title.localizedCaseInsensitiveContains(libraryQuery)) }
        let listPage = min(max(0, libraryPage), max(0, (matches.count - 1) / 8))
        let rows = matches.dropFirst(listPage * 8).prefix(8).map { ["id": $0.id.uuidString, "title": String(decoding: $0.title.utf8.prefix(120), as: UTF8.self), "date": $0.created.formatted(date: .abbreviated, time: .shortened), "duration": String(Int($0.duration)), "state": $0.state, "calendar": String((calendarLibrary[$0.id]?.event.title ?? "").prefix(80))] }
        let lines = (transcript?.utterances ?? []).sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        let page = active ? max(0, (lines.count - 1) / 8) : min(max(0, transcriptPage), max(0, (lines.count - 1) / 8))
        let utterances = lines.dropFirst(page * 8).prefix(8).map { line -> [String: String] in
            let text = line.id.uuidString == highlightedUtterance && !highlightedSourceText.isEmpty ? highlightedSourceText : line.correction ?? line.text
            return ["id": line.id.uuidString, "start": String(line.start), "text": String(decoding: text.utf8.prefix(line.id.uuidString == highlightedUtterance ? 1100 : 700), as: UTF8.self), "speaker": line.speaker ?? "", "track": line.track, "truncated": (line.correction ?? line.text).utf8.count > 700 ? "yes" : "no", "excerpt": line.id.uuidString == highlightedUtterance && !highlightedSourceText.isEmpty ? "yes" : "no"]
        }
        // Source choice is relevant only while creating a meeting; avoid filling
        // the live/notes payload with a hidden app list. Keep the chosen app.
        let viewSources = selected == nil ? sources : sources.filter { $0.id == selected?.source }
        let ask = MeetingQuestionViewState(busy: askingQuestion, question: questionText, status: questionStatus,
            provider: questionProvider, providers: questionProviders.map { ["id": $0.address.key, "title": $0.action!.title] },
            prepared: questionSnapshot != nil, coverage: questionSnapshot?.coverage ?? "",
            sources: notebookPage == "ask" && !calendarPickerOpen ? questionSnapshot?.sources.map(\.evidence) ?? [] : [],
            answer: notebookPage == "ask" && !calendarPickerOpen ? questionAnswer : nil, highlight: highlightedCitation,
            scope: questionScope, thread: chatIdentity, canAsk: canAskMeeting, context: questionSnapshot?.context ?? [],
            history: notebookPage == "ask" && !calendarPickerOpen && questionSnapshot == nil ? chatViewTurns : [],
            historyPage: chatPage, historyPages: max(1, (meetingChat.turns.count + 1) / 2), historyCount: meetingChat.turns.count,
            canRestore: store?.hasPreviousChat(chatOwner) ?? false, filter: questionLibraryFilter)
        func eventRow(_ event: PluginCalendarEvent, id: String) -> MeetingCalendarViewState.Event {
            let from = Date(timeIntervalSince1970: event.start), to = Date(timeIntervalSince1970: event.end)
            let when = event.allDay ? from.formatted(date: .abbreviated, time: .omitted) + " · All day" : from.formatted(date: .abbreviated, time: .shortened) + " – " + to.formatted(date: .omitted, time: .shortened)
            return .init(id: id, title: event.title, calendar: event.calendarName, when: when)
        }
        let calendarView = MeetingCalendarViewState(open: calendarPickerOpen, busy: calendarBusy, day: calendarDay,
            provider: calendarProvider, providers: calendarProviders.map { ["id": $0.address.key, "title": $0.action!.title] },
            linked: calendarLink.map { eventRow($0.event, id: "linked") },
            events: calendarPickerOpen ? calendarEvents.enumerated().map { eventRow($0.element, id: String($0.offset)) } : [],
            status: calendarStatus, next: calendarNext, total: calendarTotal,
            canVerify: calendarLink.map { link in calendarReadEntries.contains { $0.address.plugin == link.provider } } ?? false,
            canOpen: calendarLink?.event.url != nil)
        let showNotes = ["thoughts", "notes"].contains(notebookPage) && !calendarPickerOpen
        let evidenceItems = notebook?.evidence ?? []
        let evidencePage = min(max(0, noteEvidencePage), max(0, (evidenceItems.count - 1) / 6))
        var state: [String: PluginValue] = [
            "organization": .string(json(organizationViewState)), "calendar": .string(json(calendarView)), "ask": .string(json(ask)), "highlight": .string(highlightedUtterance),
            "notebookPage": .string(notebookPage), "thoughts": .string(showNotes ? notebook?.thoughts ?? "" : ""), "summary": .string(showNotes ? notebook?.summary ?? "" : ""),
            "decisions": .string(showNotes ? notebook?.decisions ?? "" : ""), "actionItems": .string(showNotes ? notebook?.actions ?? "" : ""), "notesReviewed": .boolean(notebook?.reviewed ?? false),
            "actionCards": .string(json(showNotes ? notebook?.actionCards ?? [] : [])),
            "taskChanges": .string(showNotes ? notebook?.taskChanges ?? "" : ""),
            "actionCoverage": .string(showNotes && notebook?.actionResolutions != nil ? "Action draft · explicit English commitments. Check other phrasing in the transcript." : ""),
            "noteEvidence": .string(json(showNotes ? evidenceItems.dropFirst(evidencePage * 6).prefix(6).map { ["id": $0.id.uuidString, "section": $0.section.rawValue, "fact": $0.fact, "quote": $0.quote, "start": String($0.start), "track": $0.track] } : [])),
            "noteEvidencePaging": .string(json(["page": evidencePage, "pages": max(1, (evidenceItems.count + 5) / 6), "count": evidenceItems.count])),
            "liveEnabled": .boolean(liveEnabled), "liveStatus": .string(liveStatus), "liveDraft": .boolean(showingLiveTranscript),
            "hasLive": .boolean(hasLiveTranscript), "hasRefined": .boolean(hasRefinedTranscript),
            "partials": .string(json(notebookPage == "transcript" && !calendarPickerOpen ? liveState.partials.values.sorted { $0.start < $1.start }.map { ["track": $0.track, "start": String($0.start), "text": String(decoding: $0.text.utf8.prefix(700), as: UTF8.self)] } : [])),
            "catchUp": .string(json(["busy": catchingUp ? "yes" : "no", "status": catchUpStatus, "range": catchUpRange,
                                     "summary": notebookPage == "transcript" && !calendarPickerOpen ? catchUpNotes?.summary ?? "" : "", "decisions": notebookPage == "transcript" && !calendarPickerOpen ? catchUpNotes?.decisions ?? "" : "", "actions": notebookPage == "transcript" && !calendarPickerOpen ? catchUpNotes?.actions ?? "" : ""])),
            "notesStale": .boolean(notebook?.sourceDigest != nil && transcript.map { MeetingNotebook.digest($0) != notebook?.sourceDigest } != false),
            "summaryAvailable": .boolean(VoiceAudio.MeetingSummarizer.available), "summarizing": .boolean(summarizing),
        ]
        let detailState: [String: PluginValue] = [
            "phase": .string(phase), "status": .string(String(status.prefix(450))), "active": .boolean(active),
            "libraryQuery": .string(libraryQuery), "library": .string(json(rows)), "libraryPage": .number(Double(listPage)), "libraryPages": .number(Double(max(1, (matches.count + 7) / 8))), "selected": .string(selected?.id.uuidString ?? ""), "title": .string(selected?.title ?? ""),
            "duration": .number(duration), "position": .number(playhead), "playing": .boolean(playing),
            "micLevel": .number(levels["mic"] ?? 0), "systemLevel": .number(levels["system"] ?? 0),
            "sources": .string(json(viewSources.filter { $0.id.utf8.count <= 180 }.prefix(35).map { ["id": $0.id, "name": String(decoding: $0.name.utf8.prefix(80), as: UTF8.self)] })),
            "bookmarks": .string(json(selected?.marks.suffix(60) ?? [])), "issue": .string(selected?.issue ?? ""),
            "hasAudio": .boolean(!(selected?.chunks.isEmpty ?? true)),
            "busy": .boolean(occupied), "processing": .boolean(processing), "progress": .number(processProgress), "speakersReady": .boolean(speakersReady),
            "asrProvider": .string(asrProvider.rawValue), "parakeetReady": .boolean(selectedASRReady),
            "transcriptComplete": .boolean(selected.map { Set($0.chunks.map(\.track)).isSubset(of: Set(transcript?.completedTracks ?? [])) } ?? false),
            "transcript": .string(json(notebookPage == "transcript" && !calendarPickerOpen ? utterances : [])), "speakers": .string(json(transcript?.names ?? [:])),
            "page": .number(Double(page)), "pages": .number(Double(max(1, (lines.count + 7) / 8))), "hasTranscript": .boolean(!lines.isEmpty)
        ]
        state["callOffer"] = .string(json(["enabled": callOffersEnabled ? "yes" : "no", "id": callOffer?.id.uuidString ?? "", "app": callOffer?.signal.appName ?? "", "title": callOffer?.signal.evidence == .microphoneActivity ? "Teams microphone in use" : "Teams call detected", "scope": callOffer?.signal.browserWide == true ? "Microphone + browser audio (all tabs)" : "Microphone + Teams audio"]))
        state["speakerState"] = .string(json(["enabled": speakerSeparation ? "yes" : "no", "status": speakerStatus, "ready": speakersReady ? "yes" : "no"]))
        state.merge(detailState) { _, new in new }
        // Cards duplicate saved action text for reading. Keep the existing
        // editable list if that optional presentation would exceed the generic
        // SDK state budget; never drop notes or widen the plugin contract.
        if let data = try? JSONEncoder().encode(state), data.count > 32_768 {
            state["actionCards"] = .string("[]")
        }
        let events: [PluginViewEventDefinition] = [
            .init("notebook", input: .init([.init("command", .string), .init("page", .string, required: false), .init("thoughts", .string, required: false), .init("summary", .string, required: false), .init("decisions", .string, required: false), .init("actions", .string, required: false), .init("reviewed", .boolean, required: false), .init("personal", .boolean, required: false), .init("seconds", .number, required: false), .init("question", .string, required: false), .init("provider", .string, required: false), .init("citation", .string, required: false), .init("date", .string, required: false), .init("offset", .number, required: false), .init("event", .string, required: false), .init("enabled", .boolean, required: false)])),
            .init("record", input: .init([.init("title", .string), .init("mic", .boolean), .init("source", .string), .init("live", .boolean)])),
            .init("pause"), .init("resume"), .init("stop"), .init("refresh"), .init("play"),
            .init("seek", input: .init([.init("time", .number)])), .init("select", input: .init([.init("id", .string)])),
            .init("rename", input: .init([.init("title", .string)])), .init("files"), .init("delete"), .init("new"),
            .init("process", input: .init([.init("action", .string)])),
            .init("review", input: .init([.init("id", .string), .init("text", .string), .init("speaker", .string), .init("editText", .boolean)])),
            .init("page", input: .init([.init("number", .number), .init("scope", .string), .init("query", .string)]))
        ]
        return PluginCustomView(entry: "meetings/index.html", revision: selected?.viewRevision ?? "mlibrary", state: state, events: events)
    }
    func handle(_ event: PluginViewEvent) throws {
        guard event.panelID == "meetings" else { throw VoiceProblem.message("Unknown meeting view") }; try definition.validate(event)
        guard !CommandLine.arguments.contains("--protocol-test") else { return }
        if importing {
            if event.name == "notebook", case .string("cancelImport") = event.values["command"] { cancelImport() }
            return
        }
        switch event.name {
        case "notebook":
            guard case .string(let command) = event.values["command"] else { return }
            switch command {
            case "callStart", "callDismiss":
                if case .string(let value) = event.values["event"], let id = UUID(uuidString: value) {
                    if command == "callStart" { acceptDetectedCall(id) } else { dismissDetectedCall(id) }
                }
            case "callOffers": if case .boolean(let enabled) = event.values["enabled"] { chooseCallOffers(enabled) }
            case "speakerOptions": if case .boolean(let enabled) = event.values["enabled"] { chooseSpeakerSeparation(enabled) }
            case "page": if case .string(let page) = event.values["page"], ["transcript", "thoughts", "notes", "ask"].contains(page) { notebookPage = page; if page == "ask" { loadChat() } }
            case "folderSelect": if case .string(let id) = event.values["event"] { chooseFolder(id) }
            case "folderCreate", "folderRename", "folderRemove", "folderMove", "folderUndo":
                let id: String = { if case .string(let value) = event.values["event"] { return value }; return "" }()
                let name: String = { if case .string(let value) = event.values["question"] { return value }; return "" }()
                changeFolder(command: command, id: id, name: name)
            case "importRecording": chooseRecordingImport()
            case "cancelImport": cancelImport()
            case "calendarOpen": showCalendarPicker()
            case "calendarClose": cancelCalendar(); calendarPickerOpen = false
            case "calendarList": if case .string(let day) = event.values["date"], case .string(let provider) = event.values["provider"], case .number(let offset) = event.values["offset"], offset.isFinite, offset.rounded() == offset, (0...10000).contains(offset) { listCalendar(day: day, provider: provider, offset: Int(offset)) }
            case "calendarLink": if case .string(let index) = event.values["event"] { linkCalendar(index) }
            case "calendarUnlink": unlinkCalendar()
            case "calendarVerify": verifyCalendar()
            case "calendarEvent": verifyCalendar(open: true)
            case "questionPreview": if case .string(let question) = event.values["question"] { prepareQuestion(question) }
            case "questionSend": sendQuestion()
            case "questionStop": cancelQuestion(); questionStatus = "Question stopped · transcript unchanged"
            case "questionProvider": if !askingQuestion, case .string(let provider) = event.values["provider"], questionProviders.contains(where: { $0.address.key == provider }) { questionProvider = provider; questionSnapshot = nil }
            case "chatFilter": if !askingQuestion, case .string(let filter) = event.values["question"], filter.utf8.count <= 512 { questionLibraryFilter = filter; UserDefaults.standard.set(filter, forKey: "meetingChatFilter"); questionSnapshot = nil }
            case "questionSource": if case .string(let citation) = event.values["citation"] { openQuestionSource(citation, turn: { if case .string(let id) = event.values["event"] { return id }; return "" }()) }
            case "noteSource": if case .string(let citation) = event.values["citation"] { openNoteSource(citation) }
            case "noteEvidencePage": if case .number(let offset) = event.values["offset"], offset.isFinite, offset.rounded() == offset, (0...4).contains(offset) { noteEvidencePage = Int(offset) }
            case "chatScope": if case .string(let scope) = event.values["page"] { setQuestionScope(scope) }
            case "chatTurn": if case .string(let id) = event.values["event"] { inspectChatTurn(id) }
            case "chatPage": if !askingQuestion, case .number(let page) = event.values["offset"], page.isFinite { chatPage = min(max(0, Int(page)), max(0, (meetingChat.turns.count - 1) / 2)) }
            case "chatDismiss": if !askingQuestion { questionSnapshot = nil; questionText = ""; questionAnswer = nil }
            case "chatNew": newMeetingChat()
            case "chatRestore": newMeetingChat(restore: true)
            case "save": if case .string(let thoughts) = event.values["thoughts"], case .string(let summary) = event.values["summary"], case .string(let decisions) = event.values["decisions"], case .string(let actions) = event.values["actions"], case .boolean(let reviewed) = event.values["reviewed"] { try saveNotes(thoughts: thoughts, summary: summary, decisions: decisions, actions: actions, reviewed: reviewed) }
            case "summarize": summarize()
            case "catchup": if case .number(let seconds) = event.values["seconds"], [30.0, 120.0, 300.0].contains(seconds) { catchUp(seconds: seconds) }
            case "cancelCatchup": cancelCatchUp(); catchUpStatus = "Catch-up stopped · previous draft kept"
            case "cancel": summaryTask?.cancel()
            case "copy": if case .boolean(let personal) = event.values["personal"] { exportNotes(includeThoughts: personal) }
            default: throw VoiceProblem.message("Unknown note control")
            }
        case "record": if case .string(let title) = event.values["title"], case .boolean(let mic) = event.values["mic"], case .string(let source) = event.values["source"], case .boolean(let live) = event.values["live"] { start(title: title, mic: mic, source: source, live: live) }
        case "pause": if phase == "recording" { finish(paused: true) }
        case "resume": resume()
        case "stop": finish(paused: false)
        case "bookmark": bookmark()
        case "refresh": if !active { refreshSources(); refresh() }
        case "play": play()
        case "seek": if case .number(let time) = event.values["time"] { seek(time) }
        case "select": if case .string(let id) = event.values["id"], let uuid = UUID(uuidString: id) { select(uuid) }
        case "rename": if case .string(let title) = event.values["title"] { rename(title) }
        case "files": revealFiles()
        case "delete": deleteSelected()
        case "process": if case .string(let action) = event.values["action"] { if action == "bookmark" { bookmark() } else { process(action) } }
        case "review": if case .string(let id) = event.values["id"], case .string(let text) = event.values["text"], case .string(let speaker) = event.values["speaker"], case .boolean(let editText) = event.values["editText"] { review(id: id, text: text, speaker: speaker, editText: editText) }
        case "page": if case .number(let page) = event.values["number"], page.isFinite, case .string(let scope) = event.values["scope"], case .string(let query) = event.values["query"] {
            if scope == "library" { libraryQuery = String(query.prefix(120)); searchLibrary(); libraryPage = max(0, min(5000, Int(page))) }
            else { transcriptPage = max(0, min(5000, Int(page))) }
        }
        case "new": if !occupied { stopPlayback(); resetCatchUp(); resetQuestion(); selected = nil; questionScope = "meeting"; loadChat(); notebook = nil; transcript = nil; liveStatus = ""; hasLiveTranscript = false; hasRefinedTranscript = false; transcriptPage = 0; duration = 0; playhead = 0; loadCalendarLink(); status = "Choose sources, then start recording" }
        default: break
        }
    }
}
struct MeetingsView: View {
    @ObservedObject var model: MeetingModel
    var body: some View {
        PluginWebSurface(root: Bundle.main.resourceURL!.appendingPathComponent("Views"), panelID: "meetings", definition: model.definition) { event in
            do { try model.handle(event) } catch { model.status = error.localizedDescription }
        }
    }
}
struct VoiceRootView: View {
    @ObservedObject var plugin: VoicePlugin
    @ObservedObject var model: VoiceModel
    init(plugin: VoicePlugin) { self.plugin = plugin; self.model = plugin.model }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Voice mode", selection: $plugin.page) { Text("Dictate").tag("Dictate"); Text("Meetings").tag("Meetings") }.pickerStyle(.segmented).frame(width: 250)
                Spacer()
                if plugin.page == "Meetings" { Button("Voice settings", systemImage: "gearshape") { plugin.model.settings = true } }
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if plugin.page == "Meetings" { MeetingsView(model: plugin.meetings).frame(width: 820, height: 510) }
            else { VoiceView(model: plugin.model) }
        }
        
        .onAppear { if Bundle.main.object(forInfoDictionaryKey: "NeroLiveFixtureAudio") != nil { plugin.meetings.startLiveFixture() } }
        .sheet(isPresented: $model.settings) { VoiceSettings(model: model) }
    }
}
