import Foundation

/// A generated claim and the exact transcript revision it was derived from.
/// The link verifies source availability, not whether a paraphrase is true.
public struct MeetingNoteEvidence: Codable, Equatable, Identifiable, Sendable {
    public enum Section: String, Codable, CaseIterable, Sendable { case summary, decisions, actions }
    public let id: UUID
    public let section: Section
    public let fact: String
    public let utteranceID: UUID
    public let track: String
    public let start: Double
    public let end: Double
    public let quote: String

    public init(section: Section, fact: String, source: MeetingUtterance) throws {
        id = UUID(); self.section = section; self.fact = fact; utteranceID = source.id
        track = source.track; start = source.start; end = source.end
        quote = Self.excerpt(source.correction ?? source.text)
        try validate()
    }
    private static func excerpt(_ text: String) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= 320 else { break }
            result.append(character)
        }
        return result
    }
    public func validate() throws {
        guard !fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, fact.utf8.count <= 512,
              !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, quote.utf8.count <= 320,
              ["mic", "system"].contains(track), start.isFinite, end.isFinite,
              start >= 0, end >= start, end <= 14430 else { throw VoiceProblem.message("Invalid meeting note evidence") }
    }
    public func resolve(in transcript: MeetingTranscript, digest: String?) throws -> MeetingUtterance {
        try validate()
        guard digest == MeetingNotebook.digest(transcript),
              let source = transcript.utterances.first(where: { $0.id == utteranceID }),
              source.track == track, source.start == start, source.end == end,
              Self.excerpt(source.correction ?? source.text) == quote else {
            throw VoiceProblem.message("Transcript changed. This saved source link is stale; regenerate the summary to link the current words.")
        }
        return source
    }
}
