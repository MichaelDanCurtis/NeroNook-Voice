import Foundation

public struct MeetingLiveUpdate: Codable, Equatable, Sendable {
    public var track: String
    public var start: Double
    public var end: Double
    public var text: String
    public var final: Bool
    public var words: [MeetingWord]?
    public init(track: String, start: Double, end: Double, text: String, final: Bool, words: [MeetingWord]? = nil) {
        self.track = track; self.start = start; self.end = end; self.text = text; self.final = final; self.words = words
    }
}

/// Settled evidence and replaceable hypotheses stay distinct. A retired capture
/// epoch can neither append text nor renew the evidence used by catch-up.
public struct MeetingLiveState: Sendable {
    public private(set) var epoch = UUID()
    public private(set) var active = false
    public private(set) var settled: [MeetingUtterance] = []
    public private(set) var partials: [String: MeetingLiveUpdate] = [:]
    private var tracks = Set<String>()
    private var offset = 0.0
    private var finalEnds: [String: Double] = [:]
    private var settledBytes = 0
    public init() {}
    @discardableResult public mutating func begin(tracks: Set<String>, offset: Double, prior: [MeetingUtterance] = []) throws -> UUID {
        guard !tracks.isEmpty, tracks.isSubset(of: ["mic", "system"]), offset.isFinite, offset >= 0, offset <= 14400 else { throw VoiceProblem.message("Invalid live meeting scope") }
        var check = MeetingTranscript(locale: "auto"); check.utterances = prior; try check.validate()
        epoch = UUID(); active = true; self.tracks = tracks; self.offset = offset
        settledBytes = prior.reduce(0) { $0 + $1.text.utf8.count }
        guard settledBytes <= 24000000 else { throw VoiceProblem.message("Live transcript memory limit reached") }
        settled = prior; partials = [:]; finalEnds = [:]; return epoch
    }
    @discardableResult public mutating func receive(_ value: MeetingLiveUpdate, epoch: UUID) throws -> Bool {
        guard active, self.epoch == epoch else { return false }
        guard tracks.contains(value.track), value.start.isFinite, value.end.isFinite,
              value.start >= max(0, offset - 0.1), value.end >= value.start, value.end <= 14430,
              value.text.utf8.count <= 16000 else { throw VoiceProblem.message("Invalid live transcript result") }
        let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.final {
            guard value.end > (finalEnds[value.track] ?? -1) else { return false }
            var partial = value; partial.text = text
            if text.isEmpty { partials[value.track] = nil } else { partials[value.track] = partial }
            return false
        }
        guard value.end > (finalEnds[value.track] ?? -1) + 0.0001 else { return false }
        if text.isEmpty {
            finalEnds[value.track] = value.end
            if let partial = partials[value.track], partial.end <= value.end + 0.05 { partials[value.track] = nil }
            return false
        }
        guard settled.count < 40000, settledBytes + text.utf8.count <= 24000000 else { throw VoiceProblem.message("Live transcript limit reached; audio recording continues.") }
        var line = MeetingUtterance(start: value.start, end: value.end, track: value.track, text: text)
        line.words = value.words
        var check = MeetingTranscript(locale: "auto"); check.utterances = [line]; try check.validate()
        finalEnds[value.track] = value.end
        if let partial = partials[value.track], partial.end <= value.end + 0.05 { partials[value.track] = nil }
        settledBytes += text.utf8.count; settled.append(line)
        return true
    }
    public mutating func retire() { active = false; epoch = UUID(); partials = [:] }
}

public struct MeetingCatchUpWindow: Sendable {
    public let meetingID: UUID
    public let start: Double
    public let end: Double
    public let transcript: MeetingTranscript
    public let truncated: Bool
    public let digest: String
    public init(meetingID: UUID, transcript: MeetingTranscript, through end: Double, seconds: Double = 120) throws {
        try transcript.validate();try transcript.requireResolvedTranscription()
        guard end.isFinite, end >= 0, end <= 14430, seconds.isFinite, seconds >= 30, seconds <= 300 else { throw VoiceProblem.message("Invalid catch-up range") }
        let lower = max(0, end - seconds)
        self.meetingID = meetingID; self.end = end
        let candidates = transcript.utterances.filter { $0.end > lower && $0.end <= end + 0.001 }.sorted { $0.start < $1.start }
        // Keep whole turns and newest evidence; never truncate a quoted sentence.
        var kept: [MeetingUtterance] = [], bytes = 0
        for line in candidates.reversed() {
            let cost = (line.correction ?? line.text).utf8.count + 160
            guard kept.count < 48, bytes + cost <= 5500 else { break }
            kept.append(line); bytes += cost
        }
        guard !kept.isEmpty else { throw VoiceProblem.message(candidates.isEmpty ? "No settled words in this time range yet." : "The newest transcript turn is too long for local catch-up.") }
        var snapshot = transcript; snapshot.utterances = kept.reversed(); snapshot.completedTracks = []; snapshot.labelledTracks = []; snapshot.pruneTranscriptionOrigins()
        self.transcript = snapshot; truncated = kept.count < candidates.count
        self.start = min(lower, snapshot.utterances.first?.start ?? lower)
        digest = MeetingNotebook.digest(snapshot)
    }
}

extension MeetingStore {
    public func liveTranscript(_ id: UUID, provider: MeetingASRProvider) throws -> MeetingTranscript? {
        _ = try load(id)
        let url = folder(id).appendingPathComponent("live-" + provider.transcriptFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 32000000 else { throw VoiceProblem.message("Live transcript exceeds its limit") }
        let result = try JSONDecoder().decode(MeetingTranscript.self, from: Data(contentsOf: url)); try result.validate()
        guard result.transcriptionReview==nil else{throw VoiceProblem.message("This live draft contains unsupported review metadata; saved files are retained")}
        guard result.providerID == provider.rawValue else { throw VoiceProblem.message("Live transcript provider changed") }; return result
    }
    public func saveLiveTranscript(_ transcript: MeetingTranscript, id: UUID, provider: MeetingASRProvider) throws {
        _ = try load(id); try transcript.validate()
        guard transcript.transcriptionReview==nil,transcript.transcriptionRevision==nil else{throw VoiceProblem.message("Transcription review must stay in its versioned refined file")}
        guard transcript.providerID == provider.rawValue else { throw VoiceProblem.message("Live transcript provider changed") }
        let data = try JSONEncoder().encode(transcript)
        guard data.count <= 32000000 else { throw VoiceProblem.message("Live transcript exceeds its limit") }
        let url = folder(id).appendingPathComponent("live-" + provider.transcriptFile)
        if FileManager.default.fileExists(atPath: url.path), try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw VoiceProblem.message("Live transcript file is unavailable") }
        try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
