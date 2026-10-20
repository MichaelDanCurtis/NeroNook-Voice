import Foundation

public struct DictationAppStyle: Codable, Equatable, Sendable {
    public var appID: String
    public var name: String
    public var tone: DictationTone
    public init(appID: String, name: String, tone: DictationTone) { self.appID = appID; self.name = name; self.tone = tone }
}
public struct DictationSnippet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var text: String
    public init(id: UUID = UUID(), name: String, text: String) { self.id = id; self.name = name; self.text = text }
    public var words: [String] { Self.words(name) }
    public static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
}
public struct DictationPersonalization: Codable, Equatable, Sendable {
    public var version = 1
    public var apps: [DictationAppStyle] = []
    public var snippets: [DictationSnippet] = []
    public var historyEnabled = false
    public var retentionDays = 7
    public init() {}
    public static func validApp(_ id: String) -> Bool {
        id.utf8.count <= 180 && id.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }
    public func tone(for app: String?, fallback: DictationTone) -> DictationTone { apps.first { $0.appID == app }?.tone ?? fallback }
    public func validate() throws {
        guard version == 1, apps.count <= 100, snippets.count <= 100, [1, 7, 30].contains(retentionDays),
              Set(apps.map(\.appID)).count == apps.count, Set(snippets.map(\.id)).count == snippets.count,
              Set(snippets.map { $0.words.joined(separator: " ") }).count == snippets.count,
              apps.allSatisfy({ Self.validApp($0.appID) && !$0.name.isEmpty && $0.name.utf8.count <= 100 }),
              snippets.allSatisfy({ !$0.words.isEmpty && $0.words.count <= 8 && !$0.name.isEmpty && $0.name.utf8.count <= 60 && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.utf8.count <= VoiceSession.maxBytes && !$0.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) && !$0.text.contains("NRVOICE_SNIPPET_") }) else { throw VoiceProblem.message("Keep up to 100 app styles and snippets. Snippet names need 1–8 words / 60 bytes, and text up to 2 KB.") }
    }
}

/// Explicit spoken commands, longest match first, expanded once. Literal text
/// never enters a language model and is never recursively expanded.
public struct DictationSnippetPlan: Sendable {
    public let prepared: String
    public let snippets: [DictationSnippet]
    public let exactText: String?
    private let markers: [String]
    public init(raw: String, snippets: [DictationSnippet]) throws {
        try VoiceSession.validate(raw); var config = DictationPersonalization(); config.snippets = snippets; try config.validate()
        guard !raw.contains("NRVOICE_SNIPPET_") else { throw VoiceProblem.message("This dictation contains a reserved snippet marker. Use the original draft.") }
        let source = raw as NSString
        var candidates: [(NSRange, DictationSnippet)] = []
        for snippet in snippets {
            let name = snippet.words.map(NSRegularExpression.escapedPattern).joined(separator: #"[\s\p{P}]+"#)
            let pattern = #"(?<![\p{L}\p{N}_])insert[\s\p{P}]+snippet[\s\p{P}]+"# + name + #"(?![\p{L}\p{N}_])"#
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            candidates += regex.matches(in: raw, range: NSRange(location: 0, length: source.length)).map { ($0.range, snippet) }
        }
        candidates.sort { $0.0.location == $1.0.location ? $0.0.length > $1.0.length : $0.0.location < $1.0.location }
        var chosen: [(NSRange, DictationSnippet)] = [], end = 0
        for candidate in candidates where candidate.0.location >= end {
            guard chosen.count < 8 else { throw VoiceProblem.message("Use up to eight snippets in one dictation") }
            chosen.append(candidate); end = NSMaxRange(candidate.0)
        }
        var prepared = "", cursor = 0, markers: [String] = []
        for (index, match) in chosen.enumerated() {
            let marker = "NRVOICE_SNIPPET_" + String(UnicodeScalar(65 + index)!)
            prepared += source.substring(with: NSRange(location: cursor, length: match.0.location - cursor)) + marker
            markers.append(marker); cursor = NSMaxRange(match.0)
        }
        prepared += source.substring(from: cursor)
        self.prepared = prepared; self.markers = markers; self.snippets = chosen.map { $0.1 }
        let outside = chosen.count == 1 ? source.substring(to: chosen[0].0.location) + source.substring(from: NSMaxRange(chosen[0].0)) : raw
        exactText = chosen.count == 1 && outside.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty ? chosen[0].1.text : nil
    }
    public func render(_ polished: String, fallback: String) throws -> String {
        if let exactText { return exactText }
        func valid(_ value: String) -> Bool {
            guard value.components(separatedBy: "NRVOICE_SNIPPET_").count - 1 == markers.count else { return false }
            var end = value.startIndex
            for marker in markers {
                guard value.components(separatedBy: marker).count == 2, let range = value.range(of: marker, range: end..<value.endIndex),
                      range.upperBound == value.endIndex || !value[range.upperBound].isLetter && !value[range.upperBound].isNumber && value[range.upperBound] != "_" else { return false }; end = range.upperBound
            }
            return true
        }
        var result = valid(polished) ? polished : fallback
        guard valid(result) else { throw VoiceProblem.message("The snippet marker changed. Original dictation retained.") }
        for (marker, snippet) in zip(markers, snippets) { result = result.replacingOccurrences(of: marker, with: snippet.text) }
        try VoiceSession.validate(result); return result
    }
}

public struct DictationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var created: Date
    public var raw: String
    public var text: String
    public var appID: String
    public var appName: String
    public var tone: DictationTone
    public var recognizer: String
    public var outcome: String
    public init(raw: String, text: String, appID: String, appName: String, tone: DictationTone, recognizer: String, created: Date = Date()) {
        self.created = created; self.raw = raw; self.text = text; self.appID = appID; self.appName = appName; self.tone = tone; self.recognizer = recognizer; outcome = "Draft ready"
    }
}
public struct DictationHistory: Codable, Equatable, Sendable {
    public var version = 1
    public var entries: [DictationHistoryEntry] = []
    public init() {}
    public func validate() throws {
        guard version == 1, entries.count <= 200, Set(entries.map(\.id)).count == entries.count else { throw VoiceProblem.message("Dictation history exceeds its limit") }
        for entry in entries {
            try VoiceSession.validate(entry.raw); try VoiceSession.validate(entry.text)
            guard entry.created.timeIntervalSince1970.isFinite, entry.appID.isEmpty || DictationPersonalization.validApp(entry.appID), entry.appName.utf8.count <= 100,
                  ["apple", "nemotron", "parakeet"].contains(entry.recognizer), ["Draft ready", "Paste sent", "Paste failed"].contains(entry.outcome) else { throw VoiceProblem.message("Invalid dictation history entry") }
        }
    }
    public mutating func prune(days: Int, now: Date = Date()) {
        entries = Array(entries.filter { $0.created >= now.addingTimeInterval(-Double(days) * 86400) && $0.created <= now.addingTimeInterval(300) }.sorted { $0.created > $1.created }.prefix(200))
    }
    @discardableResult public mutating func append(_ entry: DictationHistoryEntry, enabled: Bool, days: Int, now: Date = Date()) throws -> Bool {
        guard enabled else { return false }; var next = self; next.entries.append(entry); next.prune(days: days, now: now); try next.validate(); self = next; return true
    }
}

public final class DictationPersonalizationStore {
    public let root: URL
    public init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); _ = try url("personalization-v1.json", limit: 512000) }
    private func url(_ name: String, limit: Int) throws -> URL {
        let parent = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]); guard parent.isDirectory == true, parent.isSymbolicLink != true else { throw VoiceProblem.message("Dictation storage unavailable") }
        let value = root.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: value.path) {
            let attrs = try value.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= limit else { throw VoiceProblem.message("Dictation file unavailable or oversized") }
        }
        return value
    }
    private func write<T: Encodable>(_ value: T, name: String, limit: Int) throws {
        let url = try url(name, limit: limit), data = try JSONEncoder().encode(value); guard data.count <= limit else { throw VoiceProblem.message("Dictation storage limit reached") }
        try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func configuration() throws -> DictationPersonalization {
        let url = try url("personalization-v1.json", limit: 512000); guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let value = try JSONDecoder().decode(DictationPersonalization.self, from: Data(contentsOf: url)); try value.validate(); return value
    }
    public func save(_ value: DictationPersonalization) throws { try value.validate(); try write(value, name: "personalization-v1.json", limit: 512000) }
    public func history() throws -> DictationHistory {
        let url = try url("history-v1.json", limit: 2_000_000); guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let value = try JSONDecoder().decode(DictationHistory.self, from: Data(contentsOf: url)); try value.validate(); return value
    }
    public func save(_ value: DictationHistory) throws { try value.validate(); try write(value, name: "history-v1.json", limit: 2_000_000) }
    public func clearHistory() throws { let url = try url("history-v1.json", limit: 2_000_000); if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}
