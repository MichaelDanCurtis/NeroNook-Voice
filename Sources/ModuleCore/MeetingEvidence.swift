import Foundation

/// Source clocks remain deterministic; generated text cannot supply its own timestamp.
public enum MeetingEvidence {
    /// The small model selects moments; it cannot rewrite names/dates/commitments.
    public static func excerpts(_ sources: [Int], lines: [MeetingUtterance]) throws -> String {
        guard !sources.isEmpty, sources.count <= 6, sources.allSatisfy(lines.indices.contains) else { throw VoiceProblem.message("Catch-up selected an unknown source") }
        var seen = Set<String>()
        return try Set(sources).sorted().compactMap { source -> String? in
            let line = lines[source], original = line.correction ?? line.text
            guard seen.insert(original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).inserted else { return nil }
            guard line.start.isFinite, line.start >= 0, line.start <= 14430 else { throw VoiceProblem.message("Invalid catch-up source clock") }
            var quote = ""
            for character in original {
                guard quote.utf8.count + String(character).utf8.count <= 260 else { break }; quote.append(character)
            }
            guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceProblem.message("No readable catch-up source") }
            if quote != original { quote += "…" }
            let time = Int(line.start)
            return String(format: "[%02d:%02d] ", time/60, time%60) + quote
        }.joined(separator: "\n")
    }
    public static func validate(_ fact: String, source: Int, lines: [MeetingUtterance], allowedSources: Set<Int>? = nil) throws {
        guard lines.indices.contains(source), allowedSources?.contains(source) ?? true,
              !fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, fact.utf8.count <= 512,
              lines[source].start.isFinite, lines[source].start >= 0, lines[source].start <= 14430 else {
            throw VoiceProblem.message("Summary cited an unknown source or exceeded its limit. Existing notes are retained.")
        }
        let pattern = #"\b[0-9]{4}-[0-9]{2}-[0-9]{2}\b"#
        let expression = try NSRegularExpression(pattern: pattern)
        let original = lines[source].correction ?? lines[source].text
        for match in expression.matches(in: fact, range: NSRange(fact.startIndex..., in: fact)) {
            guard let range = Range(match.range, in: fact), original.contains(String(fact[range])) else {
                throw VoiceProblem.message("Summary introduced an unsupported date. Existing notes are retained.")
            }
        }
    }
    public static func line(_ fact: String, source: Int, lines: [MeetingUtterance]) throws -> String {
        try validate(fact, source: source, lines: lines)
        let time = Int(lines[source].start), stamp = String(format: "[%02d:%02d]", time / 60, time % 60)
        return "\(stamp) \(fact)"
    }
}
