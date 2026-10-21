import Foundation

public enum VoiceASRProvider: String, CaseIterable, Codable, Sendable {
    case apple
    case parakeet
    case nemotron

    public var title: String {
        switch self {
        case .apple: "Apple Speech"
        case .parakeet: "Parakeet v3 · MLX"
        case .nemotron: "Nemotron 3.5 · MLX"
        }
    }
    public var transcriptFile: String {
        switch self {
        case .apple: "transcript.json" // Keep existing recordings and corrections in place.
        case .parakeet: "transcript-parakeet-v3.json"
        case .nemotron: "transcript-nemotron-3.5.json"
        }
    }
}
public typealias MeetingASRProvider = VoiceASRProvider

public struct MeetingWord: Codable, Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public init(text: String, start: Double, end: Double) { self.text = text; self.start = start; self.end = end }
}
public struct MeetingUtterance: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var start: Double
    public var end: Double
    public var track: String
    public var text: String
    public var correction: String?
    public var speaker: String?
    public var reviewed: Bool = false
    public var words: [MeetingWord]?
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
    public var providerID: String?
    public var modelRevision: String?
    public var runtimeRevision: String?
    public var speakerModelRevision: String?
    public init(locale: String, provider: MeetingASRProvider = .apple, modelRevision: String? = nil, runtimeRevision: String? = nil) {
        self.locale = locale; self.providerID = provider.rawValue; self.modelRevision = modelRevision; self.runtimeRevision = runtimeRevision
    }
    public func validate() throws {
        guard utterances.count <= 40000, names.count <= 16, locale.utf8.count <= 100,
              Set(utterances.map(\.id)).count == utterances.count,
              (completedTracks + labelledTracks).allSatisfy({ ["mic", "system"].contains($0) }),
              names.allSatisfy({ Self.validSpeaker($0.key) && !$0.value.isEmpty && $0.value.utf8.count <= 100 }),
              providerID == nil || MeetingASRProvider(rawValue: providerID!) != nil,
              (modelRevision?.utf8.count ?? 0) <= 120, (runtimeRevision?.utf8.count ?? 0) <= 120, (speakerModelRevision?.utf8.count ?? 0) <= 120 else { throw VoiceProblem.message("Invalid meeting transcript") }
        for line in utterances {
            if let words = line.words {
                guard words.count <= 8192, words.reduce(0, { $0 + $1.text.utf8.count }) <= 16000,
                      words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= line.start && $0.end >= $0.start && $0.end <= line.end + 0.001 }) else { throw VoiceProblem.message("Invalid word alignment") }
            }
            guard line.start.isFinite, line.end.isFinite, line.start >= 0, line.end >= line.start, line.end <= 4 * 3600 + 30,
                  ["mic", "system"].contains(line.track), line.text.utf8.count <= 16000, (line.correction?.utf8.count ?? 0) <= 16000,
                  line.speaker == nil || Self.validSpeaker(line.speaker!) else { throw VoiceProblem.message("Invalid transcript segment") }
        }
    }
    public static func validSpeaker(_ id: String) -> Bool { ["mic", "system"].contains { track in (0..<8).contains { id == "\(track)-\($0)" } } }
    /// Keep ambiguous/overlapping speech unassigned. A track does not establish identity.
    public mutating func assign(_ spans: [MeetingSpeakerSpan], track: String) throws {
        guard ["mic", "system"].contains(track), spans.count <= 100000,
              spans.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 4 * 3600 + 30 && (0..<8).contains($0.speaker) }) else { throw VoiceProblem.message("Invalid speaker analysis") }
        // Providers may return overlapping pieces for the same speaker at a
        // streaming/final boundary. Count each instant once for that speaker;
        // duplicate spans must not manufacture dominant coverage. Cross-speaker
        // overlap is retained so ambiguous speech remains unassigned.
        let sorted = Self.unionSpeakerSpans(spans)
        // Split unreviewed, word-aligned phrases when the dominant speaker changes.
        // Never guess word timing from text length or overwrite a manual correction.
        var splitCursor = 0
        utterances = utterances.sorted { $0.start < $1.start }.flatMap { line -> [MeetingUtterance] in
            guard line.track == track, !line.reviewed, line.correction == nil, let rawWords = line.words,
                  let words = MeetingWordAlignment.preserving(line.text, words: rawWords), words.count > 1 else { return [line] }
            while splitCursor < sorted.count && sorted[splitCursor].end <= line.start { splitCursor += 1 }
            var relevant: [MeetingSpeakerSpan] = [], next = splitCursor
            while next < sorted.count && sorted[next].start < line.end {
                if sorted[next].end > line.start { relevant.append(sorted[next]) }
                next += 1
            }
            var groups: [[MeetingWord]] = [], labels: [Int?] = []
            for word in words {
                var coverage: [Int: Double] = [:]
                for span in relevant where span.end > word.start && span.start < word.end {
                    coverage[span.speaker, default: 0] += max(0, min(word.end, span.end) - max(word.start, span.start))
                }
                let order = coverage.sorted { $0.value > $1.value }, duration = max(0.01, word.end - word.start)
                let label: Int? = order.first.flatMap { best in
                    best.value / duration >= 0.55 && (order.dropFirst().first?.value ?? 0) / duration < 0.2 ? best.key : nil
                }
                if let last = groups.last, labels.last! == label, word.start - last.last!.end < 1.5 {
                    groups[groups.count - 1].append(word)
                } else { groups.append([word]); labels.append(label) }
            }
            guard groups.count > 1 else { return [line] }
            return groups.map { group in
                var turn = MeetingUtterance(start: group.first!.start, end: group.last!.end, track: track,
                                            text: group.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines))
                turn.words = group; return turn
            }
        }
        var cursor = 0
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
                if names[id] == nil { names[id] = "\(track == "mic" ? "Room" : "Call") speaker \(best.key + 1)" }
            } else { utterances[index].speaker = nil }
        }
        if !labelledTracks.contains(track) { labelledTracks.append(track) }; try validate()
    }
    private static func unionSpeakerSpans(_ spans: [MeetingSpeakerSpan]) -> [MeetingSpeakerSpan] {
        var result: [MeetingSpeakerSpan] = []
        for speaker in Set(spans.map(\.speaker)).sorted() {
            var merged: [MeetingSpeakerSpan] = []
            for span in spans.filter({ $0.speaker == speaker }).sorted(by: { $0.start < $1.start }) where span.end > span.start {
                if let prior = merged.last, span.start <= prior.end {
                    merged[merged.count - 1].end = max(prior.end, span.end)
                } else { merged.append(span) }
            }
            result.append(contentsOf: merged)
        }
        return result.sorted { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }
    }
}
extension MeetingStore {
    public func transcript(_ id: UUID, provider: MeetingASRProvider = .apple) throws -> MeetingTranscript? {
        _ = try load(id); let url = folder(id).appendingPathComponent(provider.transcriptFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 32_000_000 else { throw VoiceProblem.message("Transcript exceeds its limit") }
        let value = try JSONDecoder().decode(MeetingTranscript.self, from: Data(contentsOf: url)); try value.validate()
        guard value.providerID == provider.rawValue || (provider == .apple && value.providerID == nil) else { throw VoiceProblem.message("Transcript provider does not match its file") }
        return value
    }
    public func saveTranscript(_ value: MeetingTranscript, id: UUID, provider: MeetingASRProvider = .apple) throws {
        _ = try load(id); try value.validate()
        guard value.providerID == provider.rawValue || (provider == .apple && value.providerID == nil) else { throw VoiceProblem.message("Transcript provider does not match its file") }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 32_000_000 else { throw VoiceProblem.message("Transcript exceeds its limit") }
        try data.write(to: folder(id).appendingPathComponent(provider.transcriptFile), options: .atomic)
    }
}
