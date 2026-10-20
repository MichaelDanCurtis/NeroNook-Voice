import Foundation
import Speech
import ModuleCore

/// Use Apple's reported alignment; never invent word times from text length.
public enum MeetingTimedText {
    public static func words(_ text: AttributedString, start: Double, end: Double) -> [MeetingWord]? {
        var result: [MeetingWord] = [], prefix = ""
        for run in text.runs {
            let value = String(text[run.range].characters)
            if let time = run.audioTimeRange {
                let lower = time.start.seconds, upper = CMTimeRangeGetEnd(time).seconds
                guard lower.isFinite, upper.isFinite, lower >= start - 0.001, upper >= lower, upper <= end + 0.001 else { return nil }
                result.append(.init(text: prefix + value, start: max(start, lower), end: min(end, upper))); prefix = ""
            } else if !result.isEmpty { result[result.count - 1].text += value }
            else { prefix += value }
        }
        guard !result.isEmpty, prefix.isEmpty, result.count <= 8192 else { return nil }
        return result
    }
}
