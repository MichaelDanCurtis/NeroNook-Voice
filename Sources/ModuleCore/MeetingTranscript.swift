import Foundation

public struct MeetingUtterance: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var track: String
    public var text: String
    public var correction: String?
    public var speaker: String?
    public var reviewed: Bool = false
    public init(start: Double, end: Double, track: String, text: String) { self.start = start; self.end = end; self.track = track; self.text = text }
}
public struct MeetingSpeakerSpan: Codable, Sendable {
    public var start: Double
    public var end: Double
    public var speaker: Int
    public init(start: Double, end: Double, speaker: Int) { self.start = start; self.end = end; self.speaker = speaker }
}
public struct MeetingTranscript: Codable, Sendable {
    public var utterances: [MeetingUtterance] = []
    public var names: [String: String] = [:]
    public var completedTracks: [String] = []
    public var labelledTracks: [String] = []
    public var locale: String
    public init(locale: String) { self.locale = locale }
    public func validate() throws {
        guard utterances.count <= 40000, names.count <= 12, locale.utf8.count <= 100,
              Set(utterances.map(\.id)).count == utterances.count,
              (completedTracks + labelledTracks).allSatisfy({ ["mic", "system"].contains($0) }),
              names.allSatisfy({ Self.validSpeaker($0.key) && !$0.value.isEmpty && $0.value.utf8.count <= 100 }) else { throw VoiceProblem.message("Invalid meeting transcript") }
        for line in utterances {
            guard line.start.isFinite, line.end.isFinite, line.start >= 0, line.end >= line.start, line.end <= 4 * 3600 + 30,
                  ["mic", "system"].contains(line.track), line.text.utf8.count <= 16000, (line.correction?.utf8.count ?? 0) <= 16000,
                  line.speaker == nil || Self.validSpeaker(line.speaker!) else { throw VoiceProblem.message("Invalid transcript segment") }
        }
    }
    public static func validSpeaker(_ id: String) -> Bool { ["mic", "system"].contains { track in (0..<4).contains { id == "\(track)-\($0)" } } }
    /// Keep ambiguous/overlapping speech unassigned. A track does not establish identity.
    public mutating func assign(_ spans: [MeetingSpeakerSpan], track: String) throws {
        guard ["mic", "system"].contains(track), spans.count <= 100000,
              spans.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 4 * 3600 + 30 && (0..<4).contains($0.speaker) }) else { throw VoiceProblem.message("Invalid speaker analysis") }
        let sorted = spans.sorted { $0.start < $1.start }; var cursor = 0
        for index in utterances.indices.sorted(by: { utterances[$0].start < utterances[$1].start }) where utterances[index].track == track && !utterances[index].reviewed {
            let line = utterances[index]; var coverage: [Int: Double] = [:]
            while cursor < sorted.count && sorted[cursor].end <= line.start { cursor += 1 }
            var next = cursor
            while next < sorted.count && sorted[next].start < line.end {
                let span = sorted[next]; coverage[span.speaker, default: 0] += max(0, min(line.end, span.end) - max(line.start, span.start)); next += 1
            }
            let order = coverage.sorted { $0.value > $1.value }; let duration = max(0.01, line.end - line.start)
            if let best = order.first, best.value / duration >= 0.55, (order.dropFirst().first?.value ?? 0) / duration < 0.2 {
                let id = "\(track)-\(best.key)"; utterances[index].speaker = id
                if names[id] == nil { names[id] = "\(track == "mic" ? "Mic" : "Call") speaker \(best.key + 1)" }
            } else { utterances[index].speaker = nil }
        }
        if !labelledTracks.contains(track) { labelledTracks.append(track) }; try validate()
    }
}
extension MeetingStore {
    public func transcript(_ id: UUID) throws -> MeetingTranscript? {
        _ = try load(id); let url = folder(id).appendingPathComponent("transcript.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 32_000_000 else { throw VoiceProblem.message("Transcript exceeds its limit") }
        let value = try JSONDecoder().decode(MeetingTranscript.self, from: Data(contentsOf: url)); try value.validate(); return value
    }
    public func saveTranscript(_ value: MeetingTranscript, id: UUID) throws {
        _ = try load(id); try value.validate(); let data = try JSONEncoder().encode(value)
        guard data.count <= 32_000_000 else { throw VoiceProblem.message("Transcript exceeds its limit") }
        try data.write(to: folder(id).appendingPathComponent("transcript.json"), options: .atomic)
    }
}
