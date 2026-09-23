// Adapted from the owner's OmniVoice d3b5940; see PROVENANCE.md.
import Foundation

/// Assembles SpeechAnalyzer results into display + final transcripts.
///
/// SpeechTranscriber emits two kinds of results: *volatile* hypotheses that
/// REPLACE the current in-progress tail as the model refines it, and *final*
/// results that are settled and ACCUMULATE. Pure state machine so the merge
/// rules are unit-testable without the Speech framework.
public struct AppleSpeechTranscriptAssembler: Sendable {
    private var finalizedSegments: [String] = []
    private var volatileTail: String = ""

    public init() {}

    public mutating func receive(text: String, isFinal: Bool) {
        if isFinal {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                finalizedSegments.append(trimmed)
            }
            volatileTail = ""
        } else {
            volatileTail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Live caption text: everything settled plus the current hypothesis.
    public var displayText: String {
        joined(finalizedSegments + (volatileTail.isEmpty ? [] : [volatileTail]))
    }

    /// Only the settled segments.
    public var finalText: String {
        joined(finalizedSegments)
    }

    /// Transcript to use when the stream ends: settled segments plus any
    /// hypothesis the analyzer never got a chance to finalize.
    public var finishedText: String {
        displayText
    }

    private func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
