import Foundation
import NookPluginSDK

public enum VoiceProblem: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// A session identity prevents completion from an old recording changing a new draft.
public struct VoiceSession: Sendable {
    public enum Phase: String, Sendable { case idle, preparing, listening, finishing, review }
    public private(set) var phase: Phase = .idle
    public private(set) var token = UUID()
    public private(set) var raw = ""
    public private(set) var transcript = ""
    public static let maxBytes = 2048
    public init() {}
    public var recording: Bool { [.preparing, .listening, .finishing].contains(phase) }
    @discardableResult public mutating func begin() -> UUID {
        token = UUID(); phase = .preparing; return token
    }
    public mutating func ready(_ id: UUID) -> Bool {
        guard token == id, phase == .preparing else { return false }
        raw = ""; transcript = ""; phase = .listening; return true
    }
    public mutating func partial(_ text: String, token id: UUID) throws {
        guard token == id, phase == .listening else { return }
        try Self.validate(text, allowEmpty: true); transcript = text
    }
    public mutating func finishing(_ id: UUID) -> Bool {
        guard token == id, phase == .listening else { return false }
        phase = .finishing; return true
    }
    public mutating func finish(_ text: String, token id: UUID) throws {
        guard token == id, phase == .finishing else { return }
        try Self.validate(text); raw = text; transcript = text; phase = .review
    }
    public mutating func cancel() { token = UUID(); phase = transcript.isEmpty ? .idle : .review }
    public mutating func edit(_ text: String) throws { try Self.validate(text, allowEmpty: true); transcript = text }
    public mutating func loadDraft(raw: String, text: String) throws {
        try Self.validate(raw); try Self.validate(text); token = UUID(); self.raw = raw; transcript = text; phase = .review
    }
    public mutating func restore() { transcript = raw }
    public mutating func clear() { token = UUID(); phase = .idle; transcript = ""; raw = "" }
    public static func validate(_ text: String, allowEmpty: Bool = false) throws {
        guard text.utf8.count <= maxBytes else { throw VoiceProblem.message("Keep each dictation under 2 KB. Split longer text into another recording.") }
        guard allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceProblem.message("No speech detected. Try again or type a message.") }
    }
}

public enum VoiceContract {
    public static let submit = PluginRegisteredAction("use_transcript", title: "Use reviewed transcript", input: .init([
        .init("text", .string), .init("destination", .string), .init("read_reply", .boolean)
    ]), effect: .localChange, timeoutSeconds: 30)
    /// Structural matching avoids a vendor ID dependency. A provider must offer a
    /// read-only text-in/reply-out action with no extra required inputs or outputs.
    public static func accepts(_ action: PluginRegisteredAction) -> Bool {
        action.effect == .readOnly && action.input.fields.contains { $0.name == "prompt" && $0.kind == .string && $0.required }
        && action.input.fields.allSatisfy { $0.name == "prompt" || !$0.required }
        && action.output.fields.contains { $0.name == "reply" && $0.kind == .string && $0.required }
        && action.output.fields.allSatisfy { $0.name == "reply" || !$0.required }
    }
    public static func validate(_ values: [String: PluginValue]) throws -> (String, Bool, Bool) {
        try submit.input.validate(values)
        guard case .string(let text) = values["text"], case .string(let destination) = values["destination"], ["Copy", "Ask"].contains(destination), case .boolean(let read) = values["read_reply"] else { throw VoiceProblem.message("Choose Copy or Ask.") }
        try VoiceSession.validate(text)
        return (text, destination == "Ask", read)
    }
}

/// Explicit canonical spellings only; no semantic rewriting of spoken commands.
public enum VoiceDictionary {
    public static func apply(_ text: String, terms: String) -> String {
        var output = text
        for term in terms.split(separator: "\n").prefix(64).map({ $0.trimmingCharacters(in: .whitespaces) }) where !term.isEmpty && term.count <= 60 {
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            output = regex.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: NSRegularExpression.escapedTemplate(for: term))
        }
        return output
    }
}
