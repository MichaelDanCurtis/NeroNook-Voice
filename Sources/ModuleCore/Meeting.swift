import Foundation

public struct MeetingChunk: Codable, Equatable, Identifiable, Sendable {
    public var id: String { file }
    public var file: String
    public var track: String
    public var start: Double
    public var duration: Double
    public init(file: String, track: String, start: Double, duration: Double) { self.file = file; self.track = track; self.start = start; self.duration = duration }
}
public struct MeetingMark: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var time: Double
    public var text: String
    public init(time: Double, text: String) { self.time = time; self.text = text }
}
public struct Meeting: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var created: Date
    public var source: String
    public var microphone: Bool
    public var state: String
    public var issue: String
    public var chunks: [MeetingChunk]
    public var marks: [MeetingMark]
    public var viewRevision: String { "m" + id.uuidString.replacingOccurrences(of: "-", with: "") }
    public var duration: Double { chunks.map { $0.start + $0.duration }.max() ?? 0 }
    public init(title: String, source: String, microphone: Bool) {
        id = UUID(); self.title = String(title.prefix(120)); created = Date(); self.source = source; self.microphone = microphone
        state = "recording"; issue = ""; chunks = []; marks = []
    }
    public func validate() throws {
        guard title.utf8.count <= 1024, source.utf8.count <= 1024, issue.utf8.count <= 2048,
              ["recording", "paused", "saved", "interrupted"].contains(state), chunks.count <= 4096, marks.count <= 1000,
              Set(chunks.map(\.file)).count == chunks.count else { throw VoiceProblem.message("Invalid meeting metadata") }
        for chunk in chunks {
            guard ["mic", "system"].contains(chunk.track), chunk.file.hasSuffix(".caf"),
                  !chunk.file.contains("/"), !chunk.file.contains("\\"), !chunk.file.hasPrefix("."),
                  chunk.start.isFinite, chunk.duration.isFinite, chunk.start >= 0, chunk.duration > 0,
                  chunk.duration <= 20, chunk.start + chunk.duration <= 4 * 3600 + 30 else { throw VoiceProblem.message("Invalid audio chunk") }
        }
        guard marks.allSatisfy({ $0.time.isFinite && $0.time >= 0 && $0.time <= 4 * 3600 + 30 && $0.text.utf8.count <= 1024 }) else { throw VoiceProblem.message("Invalid bookmark") }
    }
}

public final class MeetingStore: @unchecked Sendable {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func save(_ meeting: Meeting) throws {
        try meeting.validate()
        if FileManager.default.fileExists(atPath: folder(meeting.id).path) { try checkFolder(meeting.id) }
        try FileManager.default.createDirectory(at: folder(meeting.id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(meeting).write(to: folder(meeting.id).appendingPathComponent("meeting.json"), options: .atomic)
    }
    public func load(_ id: UUID) throws -> Meeting {
        try checkFolder(id)
        let url = folder(id).appendingPathComponent("meeting.json")
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard size.isSymbolicLink != true, (size.fileSize ?? Int.max) <= 4_000_000 else { throw VoiceProblem.message("Meeting metadata exceeds its limit") }
        let value = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: url)); try value.validate()
        guard value.id == id else { throw VoiceProblem.message("Meeting identity changed") }; return value
    }
    public func list() -> [Meeting] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { URL in UUID(uuidString: URL.lastPathComponent).flatMap { try? load($0) } }.sorted { $0.created > $1.created }
    }
    public func audio(_ chunk: MeetingChunk, meeting: Meeting) throws -> URL {
        try checkFolder(meeting.id)
        try meeting.validate(); guard meeting.chunks.contains(chunk) else { throw VoiceProblem.message("Unknown audio chunk") }
        let url = folder(meeting.id).appendingPathComponent(chunk.file)
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw VoiceProblem.message("Audio file is unavailable") }; return url
    }
    private func checkFolder(_ id: UUID) throws {
        let value = try folder(id).resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard value.isSymbolicLink != true, value.isDirectory == true else { throw VoiceProblem.message("Meeting folder is unavailable") }
    }
}
