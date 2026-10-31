import Foundation

/// Reconcile tokenizer whitespace without changing a recognized character or
/// inventing time. Original transcript spacing is carried by the next word.
public enum MeetingWordAlignment {
    public static func preserving(_ text: String, words: [MeetingWord]) -> [MeetingWord]? {
        guard !words.isEmpty, words.count <= 8192, text.utf8.count <= 16000 else { return nil }
        var cursor = text.startIndex, result: [MeetingWord] = []
        for var word in words {
            guard word.start.isFinite, word.end.isFinite, word.start >= 0, word.end > word.start,
                  result.last.map({ word.start >= $0.end }) ?? true else { return nil }
            let value = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let from = cursor
            while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            guard text[cursor...].hasPrefix(value) else { return nil }
            cursor = text.index(cursor, offsetBy: value.count)
            word.text = String(text[from..<cursor]); result.append(word)
        }
        guard text[cursor...].allSatisfy(\.isWhitespace) else { return nil }
        result[result.count - 1].text += text[cursor...]
        return result
    }
}
