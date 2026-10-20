import Foundation

/// Playback-only barge-in guard. Quiet recognition while normally listening
/// remains valid; ASR callbacks cannot bypass acoustic evidence during output.
public struct ConversationInterruption: Sendable {
    public enum Decision: Equatable { case accept, hold, echo }
    public var sensitivity: Int
    private var playing = false
    private var tailUntil = -Double.infinity
    private var outputStarted = -Double.infinity
    private var outputEnded = -Double.infinity
    private var words: [String] = []
    private var candidate: Double?
    private var qualifiedUntil = -Double.infinity
    private var previousAudio = -Double.infinity
    private var noise = 0.001
    public init(sensitivity: Int = 50) { self.sensitivity = min(100, max(0, sensitivity)) }
    private var amount: Double { Double(min(100, max(0, sensitivity))) / 100 }
    public var requiredDuration: Double { 0.32 - 0.24 * amount }
    public func protects(at time: Double) -> Bool { playing || time < tailUntil }
    public mutating func beginPlayback(_ text: String, at time: Double) {
        playing = true; outputStarted = time; outputEnded = .infinity
        words = Array(Self.tokens(text).suffix(512)); resetEvidence()
    }
    public mutating func endPlayback(at time: Double) {
        playing = false; outputEnded = time; tailUntil = time + 0.4 - 0.2 * amount
    }
    public mutating func admitUser(at time: Double) {
        playing = false; outputEnded = time; tailUntil = -.infinity; resetEvidence()
    }
    public mutating func resetEvidence() { candidate = nil; qualifiedUntil = -.infinity }
    public mutating func audio(rms: Double, playbackLevel: Double, through time: Double, allowed: Bool) {
        guard time.isFinite, rms.isFinite, playbackLevel.isFinite, time > previousAudio else { return }
        if time - previousAudio > 0.25 { resetEvidence() }
        previousAudio = time
        guard allowed else { resetEvidence(); return }
        guard protects(at: time) else {
            if rms < 0.008 { noise = min(0.006, max(0.0002, noise * 0.9 + max(0, rms) * 0.1)) }
            resetEvidence(); return
        }
        // The output meter is normalized RMS * 8; compare actual energy units.
        let threshold = max(0.026 - 0.018 * amount, noise * (4 - 2 * amount), max(0, playbackLevel) / 8 * (0.3 - 0.2 * amount))
        if rms >= threshold {
            if candidate == nil { candidate = time }
            if time - (candidate ?? time) + 0.000001 >= requiredDuration { qualifiedUntil = time + 0.8 }
        } else { candidate = nil }
    }
    public func decision(text: String, start: Double, end: Double, now: Double) -> Decision {
        guard now.isFinite, start.isFinite, end.isFinite, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .hold }
        // Retain a bounded acoustic tail for delayed ASR callbacks. This is a
        // conservative textual echo check, not speaker identity recognition.
        if start < outputEnded + 0.4, end >= outputStarted, now <= outputEnded + 1.2 || playing {
            let tokens = Self.tokens(text)
            if tokens.count >= 4 {
                let output = Set(words)
                if Double(tokens.filter { output.contains($0) }.count) / Double(tokens.count) >= 0.85 { return .echo }
            }
        }
        if !protects(at: now) { return .accept }
        return now <= qualifiedUntil ? .accept : .hold
    }
    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
