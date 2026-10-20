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
    public init(meetingID: UUID) {
        version = 1; self.meetingID = meetingID; thoughts = ""; summary = ""; decisions = ""; actions = ""; reviewed = false
    }
    public func validate() throws {
        guard version == 1, [thoughts, summary, decisions, actions].allSatisfy({ $0.utf8.count <= 2048 }),
              sourceProvider.map({ ["apple", "parakeet", "nemotron"].contains($0) }) ?? true,
              (sourceRevision.map({ $0.utf8.count <= 120 }) ?? true),
              sourceDigest.map({ $0.count == 64 && $0.allSatisfy { $0.isHexDigit } }) ?? true else { throw VoiceProblem.message("Notes exceed their limit. Keep each field under 2 KB.") }
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
    public var searchableText: String { [thoughts, summary, decisions, actions].joined(separator: "\n") }
    public func markdown(title: String, includeThoughts: Bool) -> String {
        var text = "# \(title)\n\n"
        if includeThoughts && !thoughts.isEmpty { text += "## My thoughts\n\n\(thoughts)\n\n" }
        if !summary.isEmpty { text += "## Summary\(reviewed ? "" : " · draft")\n\n\(summary)\n\n" }
        if !decisions.isEmpty { text += "## Decisions\n\n\(decisions)\n\n" }
        if !actions.isEmpty { text += "## Action items\n\n\(actions)\n\n" }
        return text
    }
}

extension MeetingStore {
    private func notebookURL(_ id: UUID) throws -> URL {
        let folder = folder(id), info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw VoiceProblem.message("Meeting folder unavailable") }
        let url = folder.appendingPathComponent("notebook.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 32_768 else { throw VoiceProblem.message("Meeting notes unavailable") }
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
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
