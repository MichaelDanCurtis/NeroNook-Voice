import CryptoKit
import Foundation
import NookPluginSDK

public struct MeetingChatSource: Codable, Sendable {
    public var evidence: PluginEvidenceSource
    public let meetingID: UUID
    public let title: String
    public let created: Date
    public let provider: MeetingASRProvider
    public let live: Bool
    public let utteranceID: UUID
    public let start: Double
    public let end: Double
    public let fingerprint: String
    public let fragment: Bool
    public func resolve(meetingID: UUID, transcript: MeetingTranscript) throws -> MeetingUtterance {
        guard meetingID == self.meetingID, let line = transcript.utterances.first(where: { $0.id == utteranceID }),
              MeetingQuestionSnapshot.fingerprint(line, names: transcript.names) == fingerprint else {
            throw VoiceProblem.message("This transcript source was changed or removed. The saved answer is retained; ask again for current evidence.")
        }
        return line
    }
}

/// Portable local provenance. Neither audio, notebooks nor account state enter
/// this type. The service receives only question, recent context and evidence.
public struct MeetingChatEvidence: Codable, Sendable {
    public let question: PluginEvidenceQuestion
    public let sources: [MeetingChatSource]
    public let context: [PluginEvidenceExchange]
    public let totalTurns: Int
    public let scannedMeetings: Int
    public let availableMeetings: Int
    public let unavailableMeetings: Int
    public let fullCoverage: Bool
    public var meetingCount: Int { Set(sources.map(\.meetingID)).count }
    public var coverage: String {
        "\(fullCoverage ? "Full transcript coverage" : "Selected transcript excerpts") · \(meetingCount) \(meetingCount == 1 ? "meeting" : "meetings") · \(sources.count) \(sources.count == 1 ? "excerpt" : "excerpts") · searched \(scannedMeetings) of \(availableMeetings) recordings" +
        (unavailableMeetings > 0 ? " · \(unavailableMeetings) without usable transcripts" : "")
    }
    private static func digest(question: String, sources: [MeetingChatSource], context: [PluginEvidenceExchange]) throws -> String {
        let data = question + (try PluginEvidenceAnswerContract.json(sources)) + (try PluginEvidenceAnswerContract.json(context))
        return SHA256.hash(data: Data(data.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws {
        _ = try question.values(); try PluginEvidenceChatContract.validate(context)
        guard sources.map(\.evidence) == question.sources, sources.count <= 32,
              (0...100000).contains(totalTurns), (0...500).contains(scannedMeetings), availableMeetings >= scannedMeetings, (0...scannedMeetings).contains(unavailableMeetings),
              sources.allSatisfy({ $0.title.utf8.count <= 180 && $0.created.timeIntervalSince1970.isFinite && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 14430 && $0.fingerprint.count == 64 && $0.fingerprint.allSatisfy { $0.isHexDigit } }),
              question.snapshot == (try Self.digest(question: question.question, sources: sources, context: context)) else {
            throw VoiceProblem.message("Invalid saved conversation evidence")
        }
    }
    private static func make(question: String, sources: [MeetingChatSource], context: [PluginEvidenceExchange], total: Int, scanned: Int, available: Int, unavailable: Int, full: Bool) throws -> Self {
        let q = PluginEvidenceQuestion(question: question, snapshot: try digest(question: question, sources: sources, context: context), sources: sources.map(\.evidence))
        let value = Self(question: q, sources: sources, context: context, totalTurns: total, scannedMeetings: scanned, availableMeetings: available, unavailableMeetings: unavailable, fullCoverage: full)
        try value.validate(); return value
    }
    private static func convert(_ source: MeetingQuestionSource, meeting: Meeting, provider: MeetingASRProvider, live: Bool, library: Bool) -> MeetingChatSource {
        let title = PluginCalendarContract.bounded(meeting.title, bytes: 180)
        let label = library ? PluginCalendarContract.bounded(title, bytes: 55) + " · " + MeetingCalendarDay.text(meeting.created) + " · " + PluginCalendarContract.bounded(source.evidence.label, bytes: 45) : source.evidence.label
        return .init(evidence: .init(id: source.evidence.id, label: label, text: source.evidence.text), meetingID: meeting.id, title: title, created: meeting.created, provider: provider, live: live, utteranceID: source.utteranceID, start: source.start, end: source.end, fingerprint: source.fingerprint, fragment: source.fragment)
    }
    public static func current(meeting: Meeting, transcript: MeetingTranscript, provider: MeetingASRProvider, live: Bool, question: String, context: [PluginEvidenceExchange]) throws -> Self {
        let query = retrievalQuestion(question, context: context)
        let selection = try MeetingQuestionSnapshot.prepare(meetingID: meeting.id, transcript: transcript, provider: provider, live: live, question: query)
        let tokens = MeetingQuestionSnapshot.tokens(query)
        let ranked = selection.sources.sorted {
            let a = MeetingQuestionSnapshot.tokens($0.evidence.text).intersection(tokens).count, b = MeetingQuestionSnapshot.tokens($1.evidence.text).intersection(tokens).count
            return a == b ? $0.start < $1.start : a > b
        }
        var picked: [MeetingChatSource] = []
        for source in ranked {
            let candidate = convert(source, meeting: meeting, provider: provider, live: live, library: false)
            if try PluginEvidenceAnswerContract.json((picked + [candidate]).map(\.evidence)).utf8.count <= 8000 { picked.append(candidate) }
        }
        picked.sort { $0.start < $1.start }
        for i in picked.indices { picked[i].evidence = .init(id: "s\(i + 1)", label: picked[i].evidence.label, text: picked[i].evidence.text) }
        return try make(question: question, sources: picked, context: context, total: selection.totalTurns, scanned: 1, available: 1, unavailable: 0, full: selection.fullCoverage && picked.count == selection.sources.count)
    }
    private static func retrievalQuestion(_ question: String, context: [PluginEvidenceExchange]) -> String {
        // Resolve short follow-ups with prior user questions, not unsupported AI
        // claims. Whole-context transport is separately previewed by the caller.
        PluginCalendarContract.bounded(question + " " + context.suffix(2).map(\.question).joined(separator: " "), bytes: 1024)
    }
    public static func library(store: MeetingStore, meetings: [Meeting], preferred: MeetingASRProvider, question: String, context: [PluginEvidenceExchange]) throws -> Self {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, question.utf8.count <= 1024 else { throw VoiceProblem.message("Ask a question of up to 1 KB.") }
        let saved = meetings.filter { ["saved", "interrupted"].contains($0.state) }
        let queryText = retrievalQuestion(question, context: context), query = MeetingQuestionSnapshot.tokens(queryText)
        var pool: [(source: MeetingChatSource, score: Int)] = [], total = 0, scanned = 0, unavailable = 0, bytes = 0, complete = saved.count <= 500
        for meeting in saved.prefix(500) {
            try Task.checkCancellation()
            var chosen: (MeetingTranscript, MeetingASRProvider, Bool)?
            for provider in [preferred] + MeetingASRProvider.allCases.filter({ $0 != preferred }) {
                for live in [false, true] {
                    let name = live ? "live-" + provider.transcriptFile : provider.transcriptFile
                    let url = store.folder(meeting.id).appendingPathComponent(name)
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
                    guard bytes + size <= 64_000_000 else { complete = false; continue }
                    bytes += size
                    let t = live ? try? store.liveTranscript(meeting.id, provider: provider) : try? store.transcript(meeting.id, provider: provider)
                    if let t, !t.utterances.isEmpty { chosen = (t, provider, live); break }
                }
                if chosen != nil { break }
            }
            scanned += 1
            guard let (transcript, provider, live) = chosen else { unavailable += 1; complete = false; continue }
            if total + transcript.utterances.count > 100_000 { complete = false; break }
            total += transcript.utterances.count
            let selected = try MeetingQuestionSnapshot.prepare(meetingID: meeting.id, transcript: transcript, provider: provider, live: live, question: queryText)
            complete = complete && selected.fullCoverage
            for source in selected.sources {
                let candidate = convert(source, meeting: meeting, provider: provider, live: live, library: true)
                let score = MeetingQuestionSnapshot.tokens(source.evidence.text).intersection(query).count * 3 + MeetingQuestionSnapshot.tokens(meeting.title).intersection(query).count
                pool.append((candidate, score))
            }
            // One transcript at a time; retain only bounded leading candidates.
            pool.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.source.created != $1.source.created { return $0.source.created > $1.source.created }
                if $0.source.meetingID != $1.source.meetingID { return $0.source.meetingID.uuidString < $1.source.meetingID.uuidString }
                if $0.source.start != $1.source.start { return $0.source.start < $1.source.start }
                if $0.source.utteranceID != $1.source.utteranceID { return $0.source.utteranceID.uuidString < $1.source.utteranceID.uuidString }
                return $0.source.evidence.text < $1.source.evidence.text
            }
            if pool.count > 256 { pool = Array(pool.prefix(256)); complete = false }
        }
        guard !pool.isEmpty else { throw VoiceProblem.message("No saved meetings have a readable transcript yet. Transcribe a recording first.") }
        // Give the strongest passage from each matching meeting a turn before
        // filling neighbors. This avoids a long meeting monopolizing comparisons.
        var order: [MeetingChatSource] = [], ids = Set<UUID>()
        for item in pool where ids.insert(item.source.meetingID).inserted { order.append(item.source) }
        order += pool.map(\.source).filter { value in !order.contains { $0.meetingID == value.meetingID && $0.utteranceID == value.utteranceID && $0.evidence.text == value.evidence.text } }
        var picked: [MeetingChatSource] = []
        for var source in order {
            source.evidence = .init(id: "s\(picked.count + 1)", label: source.evidence.label, text: source.evidence.text)
            let trial = picked + [source]
            let q = PluginEvidenceQuestion(question: question, snapshot: String(repeating: "0", count: 64), sources: trial.map(\.evidence))
            guard trial.count <= 32, try PluginEvidenceAnswerContract.json(trial.map(\.evidence)).utf8.count <= 8000,
                  let values = try? q.values(), values.values.reduce(0, { $0 + $1.display.utf8.count }) <= 12_000 else { complete = false; continue }
            picked = trial
        }
        return try make(question: question, sources: picked, context: context, total: total, scanned: scanned, available: saved.count, unavailable: unavailable, full: complete && picked.count == pool.count)
    }
}

public struct MeetingChatTurn: Codable, Identifiable, Sendable {
    public let id: UUID
    public let created: Date
    public let evidence: MeetingChatEvidence
    public let assistant: String
    public var phase: String
    public var status: String
    public var answer: PluginEvidenceAnswer?
    public init(evidence: MeetingChatEvidence, assistant: String) { id = UUID(); created = Date(); self.evidence = evidence; self.assistant = assistant; phase = "pending"; status = "Waiting for assistant" }
}
public struct MeetingChat: Codable, Sendable {
    public let version: Int
    public let meetingID: UUID?
    public var turns: [MeetingChatTurn]
    public init(meetingID: UUID?) { version = 1; self.meetingID = meetingID; turns = [] }
    public func validate() throws {
        guard version == 1, turns.count <= 50, Set(turns.map(\.id)).count == turns.count else { throw VoiceProblem.message("Conversation exceeds its limit. Start a new chat; the previous chat remains recoverable.") }
        for turn in turns {
            try turn.evidence.validate(); try turn.answer?.validate(for: turn.evidence.question)
            guard ["pending", "completed", "stopped", "failed", "interrupted"].contains(turn.phase), turn.status.utf8.count <= 500, turn.assistant.utf8.count <= 200, turn.created.timeIntervalSince1970.isFinite,
                  turn.phase != "completed" || turn.answer != nil,
                  meetingID.map({ id in turn.evidence.sources.allSatisfy { $0.meetingID == id } }) ?? true else { throw VoiceProblem.message("Conversation identity or state changed") }
        }
    }
    public func context(eligibleMeetings: Set<UUID>? = nil) -> [PluginEvidenceExchange] {
        var result: [PluginEvidenceExchange] = []
        for turn in turns.reversed().filter({ turn in turn.phase == "completed" && (eligibleMeetings.map { ids in turn.evidence.sources.allSatisfy { ids.contains($0.meetingID) } } ?? true) }).prefix(4) {
            let item = PluginEvidenceExchange(question: PluginCalendarContract.bounded(turn.evidence.question.question, bytes: 700), answer: PluginCalendarContract.bounded(turn.answer?.statements.map(\.text).joined(separator: "\n") ?? "Insufficient transcript evidence", bytes: 1000))
            let trial = [item] + result
            guard (try? PluginEvidenceChatContract.validate(trial)) != nil else { break }; result = trial
        }
        return result
    }
    @discardableResult public mutating func recoverInterrupted() -> Bool {
        var recovered = false
        for i in turns.indices where turns[i].phase == "pending" {
            turns[i].phase = "interrupted"; turns[i].status = "Interrupted before completion. Nothing was automatically retried."; recovered = true
        }
        return recovered
    }
}

extension MeetingStore {
    public func hasPreviousChat(_ id: UUID?) -> Bool { (try? chatURL(id, previous: true)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    private func chatURL(_ id: UUID?, previous: Bool = false) throws -> URL {
        if let id { _ = try load(id) }
        let parent = id.map(folder) ?? root
        let attrs = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attrs.isDirectory == true, attrs.isSymbolicLink != true else { throw VoiceProblem.message("Conversation folder unavailable") }
        let url = parent.appendingPathComponent((id == nil ? "library-chat" : "chat") + (previous ? ".previous" : "") + "-v1.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 2_000_000 else { throw VoiceProblem.message("Conversation file unavailable or oversized") }
        }
        return url
    }
    public func chat(_ id: UUID?, previous: Bool = false) throws -> MeetingChat {
        let url = try chatURL(id, previous: previous)
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(meetingID: id) }
        let value = try JSONDecoder().decode(MeetingChat.self, from: Data(contentsOf: url)); try value.validate()
        guard value.meetingID == id else { throw VoiceProblem.message("Conversation belongs to a different meeting") }; return value
    }
    public func saveChat(_ value: MeetingChat, previous: Bool = false) throws {
        try value.validate(); let url = try chatURL(value.meetingID, previous: previous), data = try JSONEncoder().encode(value)
        guard data.count <= 2_000_000 else { throw VoiceProblem.message("Conversation exceeds its storage limit") }
        try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
