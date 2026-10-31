/// A small tail of quiet PCM preceding an energy-triggered utterance. No capture,
/// model, VAD or identity inference. The worker owns one instance per source.
public struct MeetingSpeechPreroll {
    public static let capacity = 5600 // 350 ms at 16 kHz; 22,400 payload bytes.
    private var samples: [Float] = []
    private var end: Double?
    public init() {}
    public var bufferedFrames: Int { samples.count }
    public mutating func reset() { samples = []; end = nil }
    public mutating func append(_ pcm: [Float], start: Double) {
        guard start.isFinite, start >= 0, !pcm.isEmpty else { reset(); return }
        // A capture discontinuity is not silence and must never be filled with
        // stale PCM or stretched into a fictitious contiguous utterance.
        if let end, abs(start - end) > 0.002 { reset() }
        if pcm.count >= Self.capacity { samples = Array(pcm.suffix(Self.capacity)) }
        else {
            let excess = max(0, samples.count + pcm.count - Self.capacity)
            if excess > 0 { samples.removeFirst(excess) }
            samples.append(contentsOf: pcm)
        }
        end = start + Double(pcm.count) / 16000
    }
    /// Consumes the prefix once. A turn boundary calls reset even if no onset
    /// occurred, so a new conversation turn cannot inherit old quiet audio.
    public mutating func take(before start: Double) -> (start: Double, pcm: [Float])? {
        defer { reset() }
        guard start.isFinite, let end, abs(start - end) <= 0.002, !samples.isEmpty else { return nil }
        return (max(0, end - Double(samples.count) / 16000), samples)
    }
}
