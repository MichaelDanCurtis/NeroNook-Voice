import Foundation

/// Session-wide speaker IDs are source-scoped. This state indexes only committed
/// model spans, leaves overlaps unassigned and caches immutable settled turns.
public struct MeetingLiveSpeakers: Sendable {
    public private(set) var epoch = UUID()
    public private(set) var through: [String: Double] = [:]
    private var spans: [String: [MeetingSpeakerSpan]] = [:]
    private var maxEnds: [String: [Double]] = [:]
    private struct Cached: Sendable { var original: MeetingUtterance; var turns: [MeetingUtterance] }
    private var cache: [UUID: Cached] = [:]
    private var produced: [UUID: MeetingUtterance] = [:]
    private var names: [String: String] = [:]
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func receive(track: String, spans incoming: [MeetingSpeakerSpan], through end: Double, epoch: UUID) throws {
        guard self.epoch == epoch else { return }
        let previous = through[track] ?? 0
        guard ["mic", "system"].contains(track), end.isFinite, end >= previous, end <= 14430,
              incoming.count <= 4096, (spans[track]?.count ?? 0) + incoming.count <= 100000,
              incoming.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= max(0, previous - 0.001) && $0.end > $0.start && $0.end <= end + 0.001 && (0..<8).contains($0.speaker) }) else { throw VoiceProblem.message("Invalid live speaker response") }
        for span in incoming.sorted(by: { $0.start < $1.start }) {
            spans[track, default: []].append(span)
            let maximum = max(maxEnds[track]?.last ?? 0, span.end)
            maxEnds[track, default: []].append(maximum)
        }
        through[track] = end
    }
    private func relevant(_ line: MeetingUtterance) -> [MeetingSpeakerSpan] {
        let values = spans[line.track] ?? [], maxima = maxEnds[line.track] ?? []
        var lower = 0, upper = maxima.count
        while lower < upper { let middle = (lower + upper) / 2; if maxima[middle] <= line.start { lower = middle + 1 } else { upper = middle } }
        var result: [MeetingSpeakerSpan] = []
        while lower < values.count && values[lower].start < line.end {
            if values[lower].end > line.start { result.append(values[lower]) }; lower += 1
        }
        return result
    }
    public mutating func applying(to original: MeetingTranscript, final: Bool = false) throws -> MeetingTranscript {
        var result = original; var turns: [MeetingUtterance] = []
        for line in original.utterances {
            guard !line.reviewed, line.correction == nil, line.end <= (through[line.track] ?? -1) + 0.001 else { turns.append(line); continue }
            if produced[line.id] == line { turns.append(line); continue }
            if let cached = cache[line.id], cached.original == line { turns.append(contentsOf: cached.turns); continue }
            var piece = MeetingTranscript(locale: original.locale)
            piece.utterances = [line]; piece.names = original.names.merging(names) { old, _ in old }
            try piece.assign(relevant(line), track: line.track)
            if !piece.utterances.isEmpty { piece.utterances[0].id = line.id }
            names.merge(piece.names) { old, _ in old }
            for turn in piece.utterances { produced[turn.id] = turn }
            cache[line.id] = Cached(original: line, turns: piece.utterances); turns.append(contentsOf: piece.utterances)
        }
        result.utterances = turns; result.names.merge(names) { old, _ in old }
        if final {
            for track in through.keys where original.utterances.filter({ $0.track == track }).allSatisfy({ $0.end <= (through[track] ?? 0) + 0.1 }) {
                if !result.labelledTracks.contains(track) { result.labelledTracks.append(track) }
            }
        }
        try result.validate(); return result
    }
}
