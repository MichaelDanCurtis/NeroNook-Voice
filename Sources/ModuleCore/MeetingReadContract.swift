import Foundation
import NookPluginSDK

/// Permission-scoped text access only. Never returns audio or local paths.
public enum MeetingReadContract {
    public static let search = PluginRegisteredAction("search_meetings", title: "Search saved meeting notes and transcripts",
        input: .init([.init("query", .string)]), output: .init([.init("matches", .string)]), timeoutSeconds: 30)
    public static let read = PluginRegisteredAction("read_meeting", title: "Read a saved meeting transcript page",
        input: .init([.init("meeting_id", .string), .init("offset", .number, minimum: 0, maximum: 2_000_000), .init("personal_notes", .boolean)]),
        output: .init([.init("text", .string), .init("next_offset", .number), .init("has_more", .boolean)]), timeoutSeconds: 30)
    public static func text(_ meeting: Meeting, notebook: MeetingNotebook?, transcript: MeetingTranscript?, personal: Bool) -> String {
        var text = "Meeting \(meeting.id.uuidString) · \(meeting.title)\n\(meeting.created.ISO8601Format())\n"
        if let notebook {
            if notebook.sourceDigest != nil {
                if let transcript {
                    if !notebook.isCurrent(for: transcript) {
                        text += "\nSaved generated notes need review: these historical notes are unverified for the current transcript because their source transcript or speaker information has changed. Use the current transcript for owners, dates and quoted words until notes are regenerated.\n\n"
                    }
                } else {
                    text += "\nSaved generated notes need review: these historical notes are unverified because their source transcript is unavailable.\n\n"
                }
            }
            text += notebook.markdown(title: meeting.title, includeThoughts: personal)
        }
        if let transcript {
            text += "\n## Transcript (\(transcript.providerID ?? "apple"))\n"
            for line in transcript.utterances.sorted(by: { $0.start < $1.start }) {
                let alternate=transcript.isKeptRecognitionAlternative(line.id) ? MeetingTranscript.keptRecognitionAlternativeLabel + " · " : ""
                let speaker = line.speaker.flatMap { transcript.names[$0] } ?? "Unassigned speaker"
                text += String(format: "[%02d:%02d]", Int(line.start)/60, Int(line.start)%60) + " \(alternate)\(speaker): \(line.correction ?? line.text)\n"
            }
        }
        text += transcript?.pendingTranscriptionText ?? ""
        return text
    }
    public static func page(_ text: String, offset: Double) throws -> [String: PluginValue] {
        guard offset.isFinite, offset.rounded() == offset, (0...2_000_000).contains(offset) else { throw VoiceProblem.message("Invalid meeting text offset") }
        let characters = Array(text)
        guard Int(offset) <= characters.count else { throw VoiceProblem.message("Meeting text changed. Start at offset zero.") }
        var result = "", next = Int(offset)
        while next < characters.count, result.utf8.count + String(characters[next]).utf8.count <= 2048 { result.append(characters[next]); next += 1 }
        guard next == characters.count || next > Int(offset) else { throw VoiceProblem.message("Meeting text exceeds the character limit") }
        return ["text": .string(result), "next_offset": .number(Double(next)), "has_more": .boolean(next < characters.count)]
    }
}
