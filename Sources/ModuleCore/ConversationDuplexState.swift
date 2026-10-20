import Foundation

/// Capture policy follows the whole conversation phase. Finishing playback
/// does not itself mean the caller is ready for another half-duplex turn.
public struct ConversationDuplexState: Sendable {
    public enum Mode: String, Sendable { case half, full }
    public enum Phase: Sendable { case preparing, listening, thinking, speaking, closed }
    public var mode: Mode
    public var phase: Phase
    public init(mode: Mode = .half, phase: Phase = .preparing) { self.mode = mode; self.phase = phase }
    public var listening: Bool {
        phase == .listening || (mode == .full && (phase == .thinking || phase == .speaking))
    }
}
