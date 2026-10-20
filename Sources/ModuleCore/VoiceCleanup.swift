import Foundation

/// Fast, local cleanup used before optional on-device language-model editing.
/// It deliberately leaves ambiguous self-corrections alone for the model or
/// manual review rather than deleting surrounding words.
public enum DictationTone: String, CaseIterable, Codable, Sendable {
    case literal = "Literal"
    case clean = "Clean"
    case formal = "Formal"
}

public enum VoiceCleanup {
    public static func baseline(_ raw: String, tone: DictationTone, dictionary: String = "") -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tone != .literal else { return text }
        text = replace(#"(?i)\b(?:um+|uh+|erm+|hmm+)\b\s*[,;]?\s*"#, in: text, with: " ")
        text = replace(#"(?i)\b(\p{L}+)\s+\1\b"#, in: text, with: "$1")
        text = resolveCompleteRestart(text)
        text = replace(#"[ \t]{2,}"#, in: text, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        text = replace(#"\bYOU\b"#, in: text, with: "you")
        text = VoiceDictionary.apply(text, terms: dictionary)
        guard !text.isEmpty else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        text = text.prefix(1).uppercased() + text.dropFirst()
        if !text.hasSuffix(".") && !text.hasSuffix("?") && !text.hasSuffix("!") {
            let first = text.split(separator: " ").first?.lowercased() ?? ""
            text += ["who", "what", "when", "where", "why", "how", "is", "are", "can", "could", "do", "does", "did", "will", "would"].contains(first) ? "?" : "."
        }
        return text
    }

    private static func resolveCompleteRestart(_ input: String) -> String {
        // "Rather" commonly expresses a preference, not a restart. Never
        // delete the beginning of "I would rather we wait until Friday".
        let markers = [#"(?i)\b(?:i mean|no wait|scratch that|correction)\b\s*[,.:;!?-]?\s*"#]
        guard let expression = try? NSRegularExpression(pattern: markers[0]),
              let match = expression.matches(in: input, range: NSRange(input.startIndex..., in: input)).last,
              let range = Range(match.range, in: input) else { return input }
        let before = String(input[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(input[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !after.isEmpty else { return input }
        let first = after.split(separator: " ").first?.lowercased() ?? ""
        let completeStarts = ["i", "you", "we", "they", "he", "she", "it", "how", "what", "where", "when", "why", "who", "please", "send", "tell", "can", "could", "do", "does", "did", "is", "are", "will", "would"]
        // Only replace the abandoned clause when the replacement sounds like
        // a complete one. "Tell Mary, I mean Sarah, ..." stays intact here.
        guard after.split(separator: " ").count >= 3, completeStarts.contains(first) else { return input }
        let boundaries = before.indices.filter { ".!?".contains(before[$0]) }
        let keepThrough = boundaries.last == before.indices.last ? boundaries.dropLast().last : boundaries.last
        guard let keepThrough else { return after }
        let retained = before[...keepThrough].trimmingCharacters(in: .whitespacesAndNewlines)
        return retained.isEmpty ? after : retained + " " + after
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
}
