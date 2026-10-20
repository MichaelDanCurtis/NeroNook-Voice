import Foundation

public enum SpeechDelivery: String, CaseIterable, Codable, Sendable {
    case natural, warm, relaxed
    public var title: String {
        switch self { case .natural: return "Natural"; case .warm: return "Warm & soft"; case .relaxed: return "Lower & relaxed" }
    }
    public var rate: Float { switch self { case .natural: return 0.50; case .warm: return 0.47; case .relaxed: return 0.45 } }
    public var pitch: Float { switch self { case .natural: return 1; case .warm: return 0.96; case .relaxed: return 0.90 } }
}

/// Retires callbacks after Stop or replacement; audio completion never executes an action.
public struct SpeechPlayback: Sendable {
    public enum Phase: String, Sendable { case idle, preparing, speaking, finished }
    public private(set) var token = UUID()
    public private(set) var phase: Phase = .idle
    public init() {}
    public var active: Bool { phase == .preparing || phase == .speaking }
    public mutating func begin(_ text: String) throws -> UUID {
        try VoiceSession.validate(text)
        token = UUID(); phase = .preparing; return token
    }
    @discardableResult public mutating func started(_ id: UUID) -> Bool {
        guard token == id, phase == .preparing else { return false }
        phase = .speaking; return true
    }
    @discardableResult public mutating func finished(_ id: UUID) -> Bool {
        guard token == id, active else { return false }
        phase = .finished; return true
    }
    public mutating func stop() { token = UUID(); phase = .idle }
}
