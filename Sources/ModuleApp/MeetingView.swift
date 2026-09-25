import SwiftUI
import ModuleCore
import NookPluginSDK

extension MeetingModel {
    var definition: PluginCustomView {
        func json<T: Encodable>(_ value: T) -> String { String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? "[]" }
        let matches = library.filter { libraryQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(libraryQuery) }
        let listPage = min(max(0, libraryPage), max(0, (matches.count - 1) / 15))
        let rows = matches.dropFirst(listPage * 15).prefix(15).map { ["id": $0.id.uuidString, "title": String($0.title.prefix(80)), "date": $0.created.formatted(date: .abbreviated, time: .shortened), "duration": String(Int($0.duration)), "state": $0.state] }
        let lines = (transcript?.utterances ?? []).sorted { $0.start < $1.start }
        let page = min(max(0, transcriptPage), max(0, (lines.count - 1) / 8))
        let utterances = lines.dropFirst(page * 8).prefix(8).map { line -> [String: String] in
            let text = line.correction ?? line.text
            return ["id": line.id.uuidString, "start": String(line.start), "text": String(decoding: text.utf8.prefix(1600), as: UTF8.self), "speaker": line.speaker ?? "", "track": line.track, "truncated": text.utf8.count > 1600 ? "yes" : "no"]
        }
        return PluginCustomView(entry: "meetings/index.html", revision: selected?.viewRevision ?? "mlibrary", state: [
            "phase": .string(phase), "status": .string(String(status.prefix(450))), "active": .boolean(active),
            "library": .string(json(rows)), "libraryPage": .number(Double(listPage)), "libraryPages": .number(Double(max(1, (matches.count + 14) / 15))), "selected": .string(selected?.id.uuidString ?? ""), "title": .string(selected?.title ?? ""),
            "duration": .number(duration), "position": .number(playhead), "playing": .boolean(playing),
            "micLevel": .number(levels["mic"] ?? 0), "systemLevel": .number(levels["system"] ?? 0),
            "sources": .string(json(sources.prefix(35).map { ["id": $0.id, "name": $0.name] })),
            "bookmarks": .string(json(selected?.marks.suffix(60) ?? [])), "issue": .string(selected?.issue ?? ""),
            "hasAudio": .boolean(!(selected?.chunks.isEmpty ?? true)),
            "busy": .boolean(occupied), "processing": .boolean(processing), "progress": .number(processProgress), "speakersReady": .boolean(speakersReady),
            "transcript": .string(json(utterances)), "speakers": .string(json(transcript?.names ?? [:])),
            "page": .number(Double(page)), "pages": .number(Double(max(1, (lines.count + 7) / 8))), "hasTranscript": .boolean(!lines.isEmpty)
        ], events: [
            .init("record", input: .init([.init("title", .string), .init("mic", .boolean), .init("source", .string)])),
            .init("pause"), .init("resume"), .init("stop"), .init("bookmark"), .init("refresh"), .init("play"),
            .init("seek", input: .init([.init("time", .number)])), .init("select", input: .init([.init("id", .string)])),
            .init("rename", input: .init([.init("title", .string)])), .init("files"), .init("delete"), .init("new"),
            .init("process", input: .init([.init("action", .string)])),
            .init("review", input: .init([.init("id", .string), .init("text", .string), .init("speaker", .string), .init("editText", .boolean)])),
            .init("page", input: .init([.init("number", .number), .init("scope", .string), .init("query", .string)]))
        ])
    }
    func handle(_ event: PluginViewEvent) throws {
        guard event.panelID == "meetings" else { throw VoiceProblem.message("Unknown meeting view") }; try definition.validate(event)
        guard !CommandLine.arguments.contains("--protocol-test") else { return }
        switch event.name {
        case "record": if case .string(let title) = event.values["title"], case .boolean(let mic) = event.values["mic"], case .string(let source) = event.values["source"] { start(title: title, mic: mic, source: source) }
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
        case "process": if case .string(let action) = event.values["action"] { process(action) }
        case "review": if case .string(let id) = event.values["id"], case .string(let text) = event.values["text"], case .string(let speaker) = event.values["speaker"], case .boolean(let editText) = event.values["editText"] { review(id: id, text: text, speaker: speaker, editText: editText) }
        case "page": if case .number(let page) = event.values["number"], page.isFinite, case .string(let scope) = event.values["scope"], case .string(let query) = event.values["query"] {
            if scope == "library" { libraryQuery = String(query.prefix(120)); libraryPage = max(0, min(5000, Int(page))) }
            else { transcriptPage = max(0, min(5000, Int(page))) }
        }
        case "new": if !occupied { stopPlayback(); selected = nil; transcript = nil; transcriptPage = 0; duration = 0; playhead = 0; status = "Choose sources, then start recording" }
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
    @State private var tab = "Dictate"
    init(plugin: VoicePlugin) { self.plugin = plugin; self.model = plugin.model }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Voice mode", selection: $tab) { Text("Dictate").tag("Dictate"); Text("Meetings").tag("Meetings") }.pickerStyle(.segmented).frame(width: 240)
                Spacer()
                if tab == "Meetings" { Button("Voice settings", systemImage: "gearshape") { plugin.model.settings = true } }
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if tab == "Dictate" { VoiceView(model: plugin.model) }
            else { MeetingsView(model: plugin.meetings).frame(width: 820, height: 510).sheet(isPresented: $model.settings) { VoiceSettings(model: plugin.model) } }
        }.preferredColorScheme(.dark)
    }
}
