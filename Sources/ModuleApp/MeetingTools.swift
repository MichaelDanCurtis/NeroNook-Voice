import Foundation
import ModuleCore
import NookPluginSDK

extension MeetingModel {
    func readTool(_ name: String, values: [String: PluginValue]) async throws -> [String: PluginValue] {
        guard let store else { throw VoiceProblem.message("Meeting library unavailable") }
        return try await MeetingReadWork.read(name, values: values, store: store, provider: asrProvider)
    }
}

// The actual detached read is retained by the awaiting caller even on cancel.
// The default observation performs no work; tests inject a held authored file.
enum MeetingReadWork {
    static func read(_ name: String, values: [String: PluginValue], store: MeetingStore,
                     provider: MeetingASRProvider, beforeRead: @escaping @Sendable () -> Void = {}) async throws -> [String: PluginValue] {
        if name == MeetingReadContract.read.id {
            try MeetingReadContract.read.input.validate(values)
            guard case .string(let id) = values["meeting_id"], let uuid = UUID(uuidString: id), case .number(let offset) = values["offset"], case .boolean(let personal) = values["personal_notes"] else { throw VoiceProblem.message("Invalid meeting request") }
            let original = Task.detached { () throws -> [String: PluginValue] in
                beforeRead(); try Task.checkCancellation()
                let meeting = try store.load(uuid), notebook = try store.notebook(uuid), transcript = try store.transcript(uuid, provider: provider)
                return try MeetingReadContract.page(MeetingReadContract.text(meeting, notebook: notebook, transcript: transcript, personal: personal) + ((try? store.calendarLink(uuid))?.markdown ?? ""), offset: offset)
            }
            return try await withTaskCancellationHandler { try await original.value } onCancel: { original.cancel() }
        }
        try MeetingReadContract.search.input.validate(values)
        guard case .string(let query) = values["query"], query.utf8.count <= 240 else { throw VoiceProblem.message("Keep meeting searches short") }
        let original = Task.detached { () throws -> [String: PluginValue] in
            beforeRead(); try Task.checkCancellation()
            var results: [[String: String]] = []
            for meeting in store.list().prefix(500) {
                try Task.checkCancellation()
                let transcript:MeetingTranscript?
                do{transcript=try store.transcript(meeting.id,provider:provider)}catch{
                    if store.hasTranscriptV2(meeting.id,provider:provider){throw error};transcript=nil
                }
                let text = MeetingReadContract.text(meeting, notebook: try? store.notebook(meeting.id), transcript: transcript, personal: false)
                if query.isEmpty || text.localizedCaseInsensitiveContains(query) {
                    results.append(["meeting_id": meeting.id.uuidString, "title": String(meeting.title.prefix(transcript?.hasPendingTranscription==true ? 40 : 80))+(transcript?.hasPendingTranscription==true ? " · recognition review pending" : ""), "created": meeting.created.ISO8601Format()])
                    if results.count == 6 { break }
                }
            }
            let data = try JSONEncoder().encode(results)
            guard data.count <= 2048 else { throw VoiceProblem.message("Search results exceed the page limit") }
            return ["matches": .string(String(decoding: data, as: UTF8.self))]
        }
        return try await withTaskCancellationHandler { try await original.value } onCancel: { original.cancel() }
    }
}

// Captures actual request tasks before cancellation, seals their callback
// admission and never conflates them with conversation or a replacement ID.
@MainActor final class VoiceMeetingReadOwner {
    private struct Entry {
        let generation: UUID
        let original: Task<Void, Never>
        var retiring: Bool
    }
    private var entries: [UUID: Entry] = [:]
    var count: Int { entries.count }
    @discardableResult func start(_ id: UUID, operation: @escaping @MainActor () async throws -> [String: PluginValue],
               reply: @escaping @MainActor (Result<[String: PluginValue], Error>) -> Void) throws -> Task<Void, Never> {
        guard entries[id] == nil, entries.count < 4 else { throw VoiceProblem.message("Too many meeting reads") }
        let generation = UUID()
        let original = Task { @MainActor [self] in
            let result: Result<[String: PluginValue], Error>
            var operationAdmitted = false
            do {
                try Task.checkCancellation()
                guard let entry = self.entries[id], entry.generation == generation, !entry.retiring else { throw CancellationError() }
                operationAdmitted = true
                let value = try await operation(); try Task.checkCancellation(); result = .success(value)
            } catch { result = .failure(error) }
            guard let entry = self.entries[id], entry.generation == generation else { return }
            if !entry.retiring && (operationAdmitted || !Task.isCancelled) { reply(result) }
            if self.entries[id]?.generation == generation { self.entries[id] = nil }
        }
        entries[id] = Entry(generation: generation, original: original, retiring: false)
        return original
    }
    func cancel(_ id: UUID) { entries[id]?.original.cancel() }
    func cancelAll() { for entry in entries.values { entry.original.cancel() } }
    func beginRetirement(_ requests: Set<UUID>) -> [Task<Void, Never>] {
        var originals: [Task<Void, Never>] = []
        for id in requests {
            guard var entry = entries[id] else { continue }
            entry.retiring = true; entries[id] = entry
            originals.append(entry.original); entry.original.cancel()
        }
        return originals
    }
    func retire(_ requests: Set<UUID>) async {
        let originals = beginRetirement(requests)
        for original in originals { await original.value }
    }
}
