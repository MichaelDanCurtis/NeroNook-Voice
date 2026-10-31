/// Bounded low-level admission experiment. Energy contrast is not a speech VAD.
/// A source owns its clock and recent noise estimate; no PCM is retained here.
public struct MeetingSpeechGate {
    public static let windowFrames = 50
    private var energyWindow: [Float] = []
    private var pending: [Float] = []
    private var end: Double?
    public init() {}
    public var bufferedFrames: Int { pending.count }
    public var observations: Int { energyWindow.count }
    public mutating func reset() { self = Self() }
    public mutating func isSilent(_ pcm: [Float], start: Double) -> Bool {
        guard start.isFinite, start >= 0, !pcm.isEmpty, pcm.allSatisfy(\.isFinite) else { reset(); return true }
        if let end, abs(start - end) > 0.002 { reset() }
        end = start + Double(pcm.count) / 16000
        // Preserve the original loud-speech path; the adaptive branch can only
        // admit additional quiet audio. DC alone cannot trigger that branch.
        let rawEnergy = pcm.reduce(Float(0)) { $0 + $1 * $1 } / Float(pcm.count)
        var admitted = rawEnergy >= 0.00004
        for sample in pcm {
            pending.append(sample)
            if pending.count == 1024 {
                let mean = pending.reduce(Float(0), +) / 1024
                let energy = pending.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / 1024
                let sorted = energyWindow.sorted()
                let noise = sorted.isEmpty ? Float(0) : sorted[min(sorted.count - 1, sorted.count / 5)]
                let threshold = min(Float(0.00004), max(Float(0.00000001), noise * 4))
                admitted = admitted || energy >= threshold
                if energyWindow.count == Self.windowFrames { energyWindow.removeFirst() }
                energyWindow.append(energy); pending.removeAll(keepingCapacity: true)
            }
        }
        return !admitted
    }
}
