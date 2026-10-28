import CryptoKit
import Foundation

/// Personal notes and derived drafts never overwrite recognized speech.
public struct MeetingNotebook: Codable, Equatable, Sendable {
    public let version: Int
    public let meetingID: UUID
    public var thoughts: String
    public var summary: String
    public var decisions: String
    public var actions: String
    public var reviewed: Bool
    public var generatedAt: Date?
    public var sourceProvider: String?
    public var sourceRevision: String?
    public var sourceDigest: String?
    public var evidence: [MeetingNoteEvidence]?
    /// Optional additive metadata: old/manual notebooks keep their plain list.
    public var actionResolutions: [MeetingActionResolution]?
    public init(meetingID: UUID) {
        version = 1; self.meetingID = meetingID; thoughts = ""; summary = ""; decisions = ""; actions = ""; reviewed = false
    }
    public func validate() throws {
        guard version == 1, [thoughts, summary, decisions, actions].allSatisfy({ $0.utf8.count <= 2048 }),
              sourceProvider.map({ ["apple", "parakeet", "nemotron"].contains($0) }) ?? true,
              (sourceRevision.map({ $0.utf8.count <= 120 }) ?? true),
              sourceDigest.map({ $0.count == 64 && $0.allSatisfy { $0.isHexDigit } }) ?? true else { throw VoiceProblem.message("Notes exceed their limit. Keep each field under 2 KB.") }
        let items = evidence ?? []
        guard items.count <= 26, Set(items.map(\.id)).count == items.count,
              items.filter({ $0.section == .summary }).count <= 6,
              items.filter({ $0.section == .decisions }).count <= 8,
              items.filter({ $0.section == .actions }).count <= 12,
              items.isEmpty || sourceDigest != nil else { throw VoiceProblem.message("Invalid meeting note evidence") }
        try items.forEach { try $0.validate() }
        if let resolutions = actionResolutions {
            guard resolutions.count <= 12, sourceDigest != nil,
                  Set(resolutions.map(\.id)).count == resolutions.count else { throw VoiceProblem.message("Invalid action items") }
            try resolutions.forEach { try $0.validate() }
            let active = resolutions.filter { $0.status == .active }.map { $0.evidence[0] }
            guard active == items.filter({ $0.section == .actions }),
                  actions == active.map({ item in
                      let time = Int(item.start)
                      return String(format: "[%02d:%02d] ", time / 60, time % 60) + item.fact
                  }).joined(separator: "\n") else { throw VoiceProblem.message("Edited actions cannot retain generated action metadata") }
        }
        for (section, text) in [(MeetingNoteEvidence.Section.summary, summary), (.decisions, decisions), (.actions, actions)] {
            let linked = items.filter { $0.section == section }
            guard linked.isEmpty || text == linked.map({ item in
                let time = Int(item.start)
                return String(format: "[%02d:%02d] ", time / 60, time % 60) + item.fact
            }).joined(separator: "\n") else { throw VoiceProblem.message("Edited notes cannot retain generated source links") }
        }
    }
    /// Edited wording is manual; do not leave generated citations attached to it.
    public mutating func edit(thoughts: String, summary: String, decisions: String, actions: String, reviewed: Bool) {
        let changed: Set<MeetingNoteEvidence.Section> = Set([
            self.summary == summary ? nil : .summary,
            self.decisions == decisions ? nil : .decisions,
            self.actions == actions ? nil : .actions
        ].compactMap { $0 })
        evidence = evidence?.filter { !changed.contains($0.section) }
        if changed.contains(.actions) { actionResolutions = nil }
        self.thoughts = thoughts; self.summary = summary; self.decisions = decisions; self.actions = actions; self.reviewed = reviewed
    }
    public static func digest(_ transcript: MeetingTranscript) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(transcript)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    /// A generated draft is valid only for the exact words, names and source
    /// version it saw. Old notebooks without provenance remain manual notes.
    public func isCurrent(for transcript: MeetingTranscript) -> Bool {
        sourceDigest == Self.digest(transcript)
    }
    public var searchableText: String { [thoughts, summary, decisions, actions, taskChanges].joined(separator: "\n") }
    public func markdown(title: String, includeThoughts: Bool) -> String {
        var text = "# \(title)\n\n"
        if includeThoughts && !thoughts.isEmpty { text += "## My thoughts\n\n\(thoughts)\n\n" }
        if !summary.isEmpty { text += "## Summary\(reviewed ? "" : " · draft")\n\n\(summary)\n\n" }
        if !decisions.isEmpty { text += "## Decisions\n\n\(decisions)\n\n" }
        if !actions.isEmpty { text += "## Action items\n\n\(actions)\n\n" }
        if !taskChanges.isEmpty { text += "## Task changes and questions\n\n\(taskChanges)\n\n" }
        return text
    }
    public var taskChanges: String {
        (actionResolutions ?? []).filter { $0.status != .active }.map {
            ($0.status == .cancelled ? "Cancelled · " : "Needs review · ") + $0.task
        }.joined(separator: "\n")
    }
}

extension MeetingStore {
    private func notebookURL(_ id: UUID) throws -> URL {
        let folder = folder(id), info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw VoiceProblem.message("Meeting folder unavailable") }
        let url = folder.appendingPathComponent("notebook.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 65_536 else { throw VoiceProblem.message("Meeting notes unavailable") }
        }
        return url
    }
    public func notebook(_ id: UUID) throws -> MeetingNotebook {
        let url = try notebookURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return MeetingNotebook(meetingID: id) }
        let value = try JSONDecoder().decode(MeetingNotebook.self, from: Data(contentsOf: url)); try value.validate()
        guard value.meetingID == id else { throw VoiceProblem.message("Notes belong to another meeting") }; return value
    }
    /// Compare durable evidence and prior notes immediately before saving a
    /// generated replacement. This is synchronous within Voice, not a filesystem
    /// transaction against arbitrary external writers.
    public func saveGeneratedNotebook(_ value: MeetingNotebook, replacing original: MeetingNotebook,
                                      provider: MeetingASRProvider, live: Bool) throws {
        let source = live ? try liveTranscript(value.meetingID, provider: provider)
                          : try transcript(value.meetingID, provider: provider)
        guard value.meetingID == original.meetingID, let source, value.isCurrent(for: source),
              try notebook(value.meetingID) == original else {
            throw VoiceProblem.message("Transcript or notes changed during summary. Existing notes are retained; review the source and try again.")
        }
        try saveNotebook(value)
    }
    public func saveNotebook(_ value: MeetingNotebook) throws {
        try value.validate(); let url = try notebookURL(value.meetingID)
        let data = try JSONEncoder().encode(value)
        guard data.count <= 65_536 else { throw VoiceProblem.message("Meeting notes exceed their storage limit") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
