import Foundation

/// Metadata, never call contents, credentials, participant names or audio.
public struct MeetingCallSignal: Equatable, Sendable {
    public enum Evidence: String, Codable, Sendable { case callControls, microphoneActivity }
    public var source: String
    public var appName: String
    public var browserWide: Bool
    public var evidence: Evidence
    public init(source: String, appName: String, browserWide: Bool = false, evidence: Evidence) {
        self.source = source; self.appName = appName; self.browserWide = browserWide; self.evidence = evidence
    }
}
public struct MeetingCallOffer: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var signal: MeetingCallSignal
}

/// Debounce a possible call, offer once, and reject stale button clicks. No
/// transition starts recording: only the app's explicit accepted control can.
public struct MeetingCallState: Sendable {
    public private(set) var current: MeetingCallOffer?
    private var firstSeen = 0.0
    private var lastSeen = 0.0
    private var offered = false
    private var present = false
    public init() {}
    public mutating func observe(_ signal: MeetingCallSignal?, at now: Double, available: Bool) -> MeetingCallOffer? {
        guard now.isFinite else { return nil }
        present = signal != nil
        guard let signal else {
            if current != nil && now - lastSeen >= 10 { reset() }
            return nil
        }
        if current?.signal.source != signal.source {
            current = .init(id: UUID(), signal: signal); firstSeen = now; offered = false
        } else { current?.signal = signal }
        lastSeen = now
        let delay = signal.evidence == .callControls ? 2.0 : 5.0
        guard available, !offered, now - firstSeen >= delay, let current else { return nil }
        offered = true; return current
    }
    public func isFresh(_ id: UUID, at now: Double) -> Bool {
        present && now.isFinite && current?.id == id && now >= lastSeen && now - lastSeen <= 4
    }
    public mutating func dismiss(_ id: UUID) { if current?.id == id { offered = true } }
    public mutating func reset() { self = Self() }
}
