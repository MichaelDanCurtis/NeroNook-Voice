import Foundation

/// Proposals reference original transcript turns, never intermediate summaries.
/// The app checks literal fields; these checks do not prove semantic meaning.
public struct MeetingActionProposal: Codable, Sendable {
    public var task: String
    public var taskSource: Int
    public var owner: String
    public var ownerSource: Int
    public var deadline: String
    public var deadlineSource: Int
    public var status: String
    public var sources: [Int]
    public init(task: String, taskSource: Int, owner: String = "", ownerSource: Int = -1,
                deadline: String = "", deadlineSource: Int = -1, status: String = "active", sources: [Int]) {
        self.task = task; self.taskSource = taskSource; self.owner = owner; self.ownerSource = ownerSource
        self.deadline = deadline; self.deadlineSource = deadlineSource; self.status = status; self.sources = sources
    }
}

public struct MeetingActionResolution: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case active, cancelled, uncertain }
    public let id: UUID
    public let task: String
    public let owner: String?
    public let deadline: String?
    public let status: Status
    public let evidence: [MeetingNoteEvidence]
    public var fact: String {
        (owner ?? "Unassigned") + ": " + task + (deadline.map { " · Due " + $0 } ?? " · No deadline stated")
    }
    // Read-only presentation of historical structured notes. Stored owner/fact
    // and evidence stay untouched so their validation and source links agree.
    var presentedOwner: String? { owner.flatMap(Self.personName) }
    var presentedFact: String {
        (presentedOwner ?? "Unassigned") + ": " + task + (deadline.map { " · Due " + $0 } ?? " · No deadline stated")
    }
    public func validate() throws {
        guard !task.isEmpty, task.utf8.count <= 160,
              owner.map({ !$0.isEmpty && $0.utf8.count <= 100 }) ?? true,
              deadline.map({ !$0.isEmpty && $0.utf8.count <= 80 }) ?? true,
              !evidence.isEmpty, evidence.count <= 5, evidence.first?.id == id,
              Set(evidence.map(\.utteranceID)).count == evidence.count,
              evidence.allSatisfy({ $0.section == .actions && $0.fact == fact }) else {
            throw VoiceProblem.message("Invalid action-item evidence. Existing notes are retained.")
        }
        try evidence.forEach { try $0.validate() }
    }
    public static func resolve(_ proposals: [MeetingActionProposal], transcript: MeetingTranscript,
                               allowedSources: Set<Int>) throws -> [Self] {
        try transcript.validate()
        let lines = ordered(transcript)
        guard proposals.count <= 12 else { throw problem() }
        var keys = Set<String>()
        return try proposals.map { proposal in
            let task = proposal.task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty, task.utf8.count <= 160, let status = Status(rawValue: proposal.status),
                  Set(proposal.sources).count == proposal.sources.count,
                  (1...5).contains(proposal.sources.count), proposal.sources.contains(proposal.taskSource),
                  proposal.sources.allSatisfy({ lines.indices.contains($0) && allowedSources.contains($0) }),
                  words(lines[proposal.taskSource]).contains(task),
                  keys.insert(task.lowercased()).inserted else { throw problem() }
            func literal(_ value: String, source: Int, limit: Int) throws -> String? {
                if value.isEmpty { guard source == -1 else { throw problem() }; return nil }
                guard value == value.trimmingCharacters(in: .whitespacesAndNewlines), value.utf8.count <= limit,
                      proposal.sources.contains(source), words(lines[source]).contains(value) else { throw problem() }
                return value
            }
            let ownerQuote = try literal(proposal.owner, source: proposal.ownerSource, limit: 100)
            let owner: String?
            if let ownerQuote, ownerQuote.caseInsensitiveCompare("I") == .orderedSame {
                // A room/call track or diarization label is not a person's name.
                owner = lines[proposal.ownerSource].speaker.flatMap { transcript.names[$0] }.flatMap(personName)
            } else { owner = ownerQuote.flatMap(personName) }
            let deadline = try literal(proposal.deadline, source: proposal.deadlineSource, limit: 80)
            let fact = (owner ?? "Unassigned") + ": " + task + (deadline.map { " · Due " + $0 } ?? " · No deadline stated")
            // The action's original turn stays first; retain later revisions and
            // cancellation/confirmation turns as independently navigable sources.
            let sources = [proposal.taskSource] + proposal.sources.sorted().filter { $0 != proposal.taskSource }
            let evidence = try sources.map { try MeetingNoteEvidence(section: .actions, fact: fact, source: lines[$0]) }
            let result = Self(id: evidence[0].id, task: task, owner: owner, deadline: deadline, status: status, evidence: evidence)
            try result.validate(); return result
        }
    }
    public static func ordered(_ transcript: MeetingTranscript) -> [MeetingUtterance] {
        transcript.utterances.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }
    public static func words(_ line: MeetingUtterance) -> String { line.correction ?? line.text }
    private static func personName(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 100,
              !["i", "we", "you", "he", "she", "they", "someone", "the team", "nobody"].contains(value.lowercased()),
              value.range(of: #"^(room|call|speaker|unassigned|unknown)(\s|\d|$)"#, options: [.regularExpression, .caseInsensitive]) == nil,
              // Older manual turn assignments saved these display aliases. They
              // are track/cluster labels, not explicitly named people.
              value.range(of: #"^(mic|system) speaker [0-7]$"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return value
    }
    private static func problem() -> VoiceProblem { .message("An action-item field did not match its original transcript evidence. Existing notes are retained.") }
}
