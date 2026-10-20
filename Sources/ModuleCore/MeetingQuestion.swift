import CryptoKit
import Foundation
import NookPluginSDK

public struct MeetingQuestionSource: Sendable {
    public let evidence: PluginEvidenceSource
    public let utteranceID: UUID
    public let start: Double
    public let end: Double
    public let fingerprint: String
    public let fragment: Bool
}

/// An immutable, transcript-only disclosure. No notebook or audio input exists.
public struct MeetingQuestionSnapshot: Sendable {
    public let meetingID: UUID
    public let provider: MeetingASRProvider
    public let live: Bool
    public let question: PluginEvidenceQuestion
    public let sources: [MeetingQuestionSource]
    public let totalTurns: Int
    public let selectedTurns: Int
    public let fullCoverage: Bool
    public static func fingerprint(_ line: MeetingUtterance, names: [String: String]) -> String {
        hash(line.id.uuidString + "|\(line.start)|\(line.end)|" + line.track + "|" + (line.speaker ?? "") + "|" +
             (line.speaker.flatMap { names[$0] } ?? "") + "|" + (line.correction ?? line.text))
    }
    private static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func tokens(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "for", "was", "were", "this", "that", "what", "who", "how", "did", "does", "are", "can", "about", "with", "from", "have", "will", "meeting"]
        return Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 && !stop.contains($0) })
    }
    public static func prepare(meetingID: UUID, transcript: MeetingTranscript, provider: MeetingASRProvider, live: Bool, question: String) throws -> Self {
        try transcript.validate()
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 1024 else { throw VoiceProblem.message("Ask a question of up to 1 KB.") }
        let lines = transcript.utterances.filter { !($0.correction ?? $0.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        guard !lines.isEmpty else { throw VoiceProblem.message("This meeting has no settled transcript yet.") }
        let query = tokens(text)
        let scores = lines.map { tokens($0.correction ?? $0.text).intersection(query).count }
        let ranked = lines.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
        // Relevance first, then immediate conversational neighbors. Selection is
        // deterministic, visibly bounded, and never a claim to semantic retrieval.
        var order: [Int] = [], seen = Set<Int>()
        for i in ranked {
            for n in [i, i - 1, i + 1] where lines.indices.contains(n) && seen.insert(n).inserted { order.append(n) }
        }
        var picked: [(index: Int, part: Int, text: String, fragment: Bool)] = []
        for index in order {
            if Task.isCancelled { throw CancellationError() }
            let line = lines[index], original = line.correction ?? line.text
            var parts: [String] = [], part = ""
            for character in original {
                let value = String(character)
                // A pathological grapheme is never cut into invalid UTF-8.
                guard value.utf8.count <= 1100 else { throw VoiceProblem.message("A transcript passage contains an oversized character.") }
                if part.utf8.count + value.utf8.count > 1100 { parts.append(part); part = "" }
                part += value
            }
            if !part.isEmpty { parts.append(part) }
            let rankedParts = parts.indices.sorted {
                let a = tokens(parts[$0]).intersection(query).count, b = tokens(parts[$1]).intersection(query).count
                return a == b ? $0 < $1 : a > b
            }
            for p in rankedParts {
                let candidate = picked + [(index, p, parts[p], parts.count > 1)]
                let sources = candidate.enumerated().map { PluginEvidenceSource(id: "s\($0.offset + 1)", label: "source", text: $0.element.text) }
                let provisional = PluginEvidenceQuestion(question: text, snapshot: String(repeating: "0", count: 64), sources: sources)
                // Reserve space for final timestamp/track labels and JSON escaping.
                if candidate.count > 32 || (try? provisional.values().values.reduce(0) { $0 + $1.display.utf8.count }) ?? Int.max > 13_000 { break }
                picked = candidate
            }
            if picked.count >= 32 { break }
        }
        picked.sort { $0.index == $1.index ? $0.part < $1.part : $0.index < $1.index }
        var sources: [MeetingQuestionSource] = []
        for (i, piece) in picked.enumerated() {
            let line = lines[piece.index], speaker = line.speaker.flatMap { transcript.names[$0] } ?? (line.track == "mic" ? "Microphone" : "Call audio")
            var shortSpeaker = speaker
            while shortSpeaker.utf8.count > 80 { shortSpeaker.removeLast() }
            let clock = String(format: "%02d:%02d:%02d", Int(line.start) / 3600, Int(line.start) / 60 % 60, Int(line.start) % 60)
            let label = clock + " · " + shortSpeaker + (piece.fragment ? " · excerpt" : "")
            sources.append(.init(evidence: .init(id: "s\(i + 1)", label: label, text: piece.text), utteranceID: line.id,
                start: line.start, end: line.end, fingerprint: fingerprint(line, names: transcript.names), fragment: piece.fragment))
        }
        let unique = Set(sources.map(\.utteranceID)).count
        let full = unique == lines.count && sources.reduce(0) { $0 + $1.evidence.text.utf8.count } == lines.reduce(0) { $0 + ($1.correction ?? $1.text).utf8.count }
        let digest = hash(meetingID.uuidString + provider.rawValue + String(live) + text + (try PluginEvidenceAnswerContract.json(sources.map(\.evidence))))
        let request = PluginEvidenceQuestion(question: text, snapshot: digest, sources: sources.map(\.evidence)); _ = try request.values()
        return .init(meetingID: meetingID, provider: provider, live: live, question: request, sources: sources,
                     totalTurns: lines.count, selectedTurns: unique, fullCoverage: full)
    }
    public func resolve(_ citation: String, meetingID: UUID, transcript: MeetingTranscript) throws -> MeetingUtterance {
        guard meetingID == self.meetingID, let source = sources.first(where: { $0.evidence.id == citation }),
              let line = transcript.utterances.first(where: { $0.id == source.utteranceID }),
              Self.fingerprint(line, names: transcript.names) == source.fingerprint
        else { throw VoiceProblem.message("This source was changed or removed. Ask again using the current transcript.") }
        return line
    }
}
