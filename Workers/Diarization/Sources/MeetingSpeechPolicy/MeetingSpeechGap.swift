/// Keep live ASR's sample clock consistent with the durable/speaker timeline.
/// Short known gaps are silence; a backward clock is not presumed duplicate PCM.
public enum MeetingSpeechGap {
    public enum Action: Equatable { case none, pad(Int), settle, reject }
    public static func action(previousEnd: Double?, nextStart: Double) -> Action {
        guard nextStart.isFinite, nextStart >= 0, nextStart <= 14430 else { return .reject }
        guard let previousEnd else { return .none }
        guard previousEnd.isFinite, previousEnd >= 0, previousEnd <= 14430 else { return .reject }
        let frames = Int((nextStart * 16000).rounded()) - Int((previousEnd * 16000).rounded())
        if frames < -32 { return .reject }
        if frames > 4000 { return .settle }
        return frames > 32 ? .pad(frames) : .none
    }
}
