import Foundation

public enum SelectionTransformation: String, CaseIterable, Sendable {
    case rephrase = "Rephrase", clarify = "Clarify", formal = "More formal", friendly = "More friendly", improve = "Improve writing"
    public var instruction: String {
        switch self {
        case .rephrase: "Rephrase the selection while keeping its meaning and tone."
        case .clarify: "Make the selection easier to understand without adding facts."
        case .formal: "Use a more formal tone without adding facts or commitments."
        case .friendly: "Use a warmer, friendly tone without adding facts or commitments."
        case .improve: "Improve grammar, clarity and flow while preserving tone and meaning."
        }
    }
}

/// The full field is held only in memory for exact edit validation. Only the
/// explicitly selected substring is provided to the local language model.
public struct SelectionCapture: Equatable, Sendable {
    public let id: UUID
    public let app: String
    public let value: String
    public let range: NSRange
    public var text: String { (value as NSString).substring(with: range) }
    public init(id: UUID = UUID(), app: String, value: String, range: NSRange) throws {
        guard value.utf8.count <= 131_072, range.length > 0,
              DictationEdit.valid(range, in: value) else { throw SelectionProblem.invalidSelection }
        let text = (value as NSString).substring(with: range)
        guard text.utf8.count <= 6000, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SelectionProblem.invalidSelection }
        self.id = id; self.app = app; self.value = value; self.range = range
    }
}

public enum SelectionProblem: LocalizedError {
    case invalidSelection, changed, undoChanged, unsupported, permission, unavailable, timeout, unverified, invalidResult
    public var errorDescription: String? {
        switch self {
        case .invalidSelection: "Highlight some text first (up to 6 KB), then use the Rewrite shortcut."
        case .changed: "The original text, selection or window changed. Nothing was replaced. Copy the result if you want to use it."
        case .undoChanged: "The text, cursor or window changed after replacement. Undo was not applied; the original selection is kept here for review."
        case .unsupported: "This field does not support exact selected-text editing. Use dictation or copy a draft instead."
        case .permission: "Allow Nero Voice in macOS Accessibility to edit selected text."
        case .unavailable: "Apple Intelligence is unavailable. You can edit the preview yourself; nothing is sent to the cloud."
        case .timeout: "The local model did not finish. You can edit the preview yourself. Restart Voice before trying the model again."
        case .unverified: "The editor did not confirm the change. Check the original app before trying again. Your original selection is kept here."
        case .invalidResult: "The result is empty or too long. Keep the replacement under 12 KB."
        }
    }
}
