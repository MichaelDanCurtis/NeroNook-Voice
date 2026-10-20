import Foundation

public enum ConversationPace: String, CaseIterable, Sendable {
    case quick, balanced
    public var title: String { self == .quick ? "Quicker turn-taking" : "More pause time" }
}

/// Bounded turn assembly. Recognition timing, silence and a stable transcript
/// jointly end a turn. A source clock never makes a retired turn fresh again.
public struct ConversationTurn: Sendable {
    public private(set) var text = ""
    public private(set) var speaking = false
    public private(set) var lastVoice = 0.0
    private var voiceCount = 0
    private var lastAcousticVoice: Double?
    private var cutoff = -1.0
    private var finals: [MeetingLiveUpdate] = []
    private var partial: MeetingLiveUpdate?
    private var changed = 0.0
    private let pace: ConversationPace
    public init(pace: ConversationPace = .balanced) { self.pace = pace }
    public mutating func audio(rms: Double, through: Double, allowed: Bool) -> Bool {
        guard through.isFinite, rms.isFinite, allowed else { return false }
        if rms > 0.008 { voiceCount += 1; lastVoice = through; lastAcousticVoice = through } else { voiceCount = 0 }
        if !speaking && voiceCount >= 3 { speaking = true; return true }; return false
    }
    public mutating func receive(_ update: MeetingLiveUpdate, now: Double) throws {
        guard update.start >= cutoff - 0.15, update.end > cutoff, now.isFinite else { return }
        guard update.text.utf8.count <= 2048, finals.count < 64 else { throw VoiceProblem.message("Keep a spoken turn under 2 KB; pause between turns.") }
        if update.final {
            if finals.contains(where: { $0.start == update.start && $0.end == update.end && $0.text == update.text }) { return }
            // Explicit finalization can revise the same acoustic interval. It is
            // a replacement, not another sentence to append to the user's turn.
            finals.removeAll { min($0.end, update.end) - max($0.start, update.start) > 0.1 }
            finals.append(update)
            if (partial?.start ?? 0) < update.end { partial = nil }
        } else {
            // Late volatile callbacks may repeat a newly finalized interval.
            guard update.start >= (finals.map(\.end).max() ?? 0) - 0.1,
                  update.end > (finals.map(\.end).max() ?? -1) + 0.01 else { return }
            partial = update
        }
        let value = (finals.map(\.text) + (partial.map { [$0.text] } ?? [])).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 2048 else { throw VoiceProblem.message("Spoken turn is too long. Start another turn.") }
        if value != text { text = value; changed = now }
        // Segment ends include the recognizer's trailing silence. Acoustic
        // speech already supplies its own clock; do not count that pause twice.
        // Quiet recognized speech retains its conservative timestamp fallback.
        if !value.isEmpty {
            speaking = true
            if (lastAcousticVoice ?? -1) < update.start - 0.15 { lastVoice = max(lastVoice, update.end) }
        }
    }
    public func canCommit(at now: Double) -> Bool {
        // Only finalized recognition earns the shorter turn-taking pause.
        // Volatile words, including in Quick mode, retain conservative timing.
        let settled = partial == nil && !finals.isEmpty
        let quick = pace == .quick && settled
        return speaking && !text.isEmpty && now - lastVoice >= (quick ? 0.75 : 0.95) && now - changed >= (quick ? 0.1 : 0.5)
    }
    public mutating func commit(through: Double) -> String {
        let result = text; cutoff = max(cutoff, through); finals = []; partial = nil; text = ""; speaking = false; voiceCount = 0; lastAcousticVoice = nil; return result
    }
    public mutating func discard(through: Double) { _ = commit(through: through) }
}
