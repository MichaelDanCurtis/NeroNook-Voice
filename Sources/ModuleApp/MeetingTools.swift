import Foundation
import ModuleCore
import NookPluginSDK

extension MeetingModel {
    func readTool(_ name: String, values: [String: PluginValue]) async throws -> [String: PluginValue] {
        guard let store else { throw VoiceProblem.message("Meeting library unavailable") }
        let provider = asrProvider
        if name == MeetingReadContract.read.id {
            try MeetingReadContract.read.input.validate(values)
            guard case .string(let id) = values["meeting_id"], let uuid = UUID(uuidString: id), case .number(let offset) = values["offset"], case .boolean(let personal) = values["personal_notes"] else { throw VoiceProblem.message("Invalid meeting request") }
            return try await Task.detached {
                let meeting = try store.load(uuid), notebook = try store.notebook(uuid), transcript = try store.transcript(uuid, provider: provider)
                return try MeetingReadContract.page(MeetingReadContract.text(meeting, notebook: notebook, transcript: transcript, personal: personal) + ((try? store.calendarLink(uuid))?.markdown ?? ""), offset: offset)
            }.value
        }
        try MeetingReadContract.search.input.validate(values)
        guard case .string(let query) = values["query"], query.utf8.count <= 240 else { throw VoiceProblem.message("Keep meeting searches short") }
        return try await Task.detached {
            var results: [[String: String]] = []
            for meeting in store.list().prefix(500) {
                let text = MeetingReadContract.text(meeting, notebook: try? store.notebook(meeting.id), transcript: try? store.transcript(meeting.id, provider: provider), personal: false)
                if query.isEmpty || text.localizedCaseInsensitiveContains(query) {
                    results.append(["meeting_id": meeting.id.uuidString, "title": String(meeting.title.prefix(80)), "created": meeting.created.ISO8601Format()])
                    if results.count == 6 { break }
                }
            }
            let data = try JSONEncoder().encode(results)
            guard data.count <= 2048 else { throw VoiceProblem.message("Search results exceed the page limit") }
            return ["matches": .string(String(decoding: data, as: UTF8.self))]
        }.value
    }
}
