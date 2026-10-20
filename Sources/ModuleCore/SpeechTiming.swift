import Foundation
import OSLog

/// Local metadata only: no audio, transcript, account, target or model output.
/// Captured with the macOS log tool only when diagnosing speech latency.
public enum SpeechTiming {
    private static let logger = Logger(subsystem: "cafe.nero.speech-timing", category: "latency")
    public static func mark(_ stage: String, turn: Int = 0, milliseconds: Double = 0) {
        guard ["voiceReady", "endpoint", "committed", "speakReceived", "playbackStarted", "recognized", "requestStarted", "threadReady", "firstReply", "chunkSent", "replyFinished"].contains(stage),
              (0...10000).contains(turn), milliseconds.isFinite else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        logger.info("stage=\(stage, privacy: .public) turn=\(turn) uptime=\(uptime) ms=\(milliseconds)")
    }
}
