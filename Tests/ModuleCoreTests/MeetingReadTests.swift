import XCTest
import NookPluginSDK
@testable import ModuleCore

final class MeetingReadTests: XCTestCase {
    func testPagedReadRoundTripsUnicodeAndDoesNotExportPersonalNotesByDefault() throws {
        let meeting = Meeting(title: "Review", source: "none", microphone: false)
        var notes = MeetingNotebook(meetingID: meeting.id); notes.thoughts = "Private draft"; notes.summary = "Public summary"
        var transcript = MeetingTranscript(locale: "en-US"); transcript.utterances = [.init(start: 7, end: 20, track: "mic", text: String(repeating: "界 hello ", count: 600))]
        let text = MeetingReadContract.text(meeting, notebook: notes, transcript: transcript, personal: false)
        XCTAssertFalse(text.contains("Private draft")); XCTAssertTrue(text.contains("[00:07]"))
        var offset=0.0, combined="", more=true
        while more {
            let page=try MeetingReadContract.page(text, offset: offset)
            try MeetingReadContract.read.output.validate(page)
            if case .string(let part)=page["text"] { combined += part }
            if case .number(let next)=page["next_offset"] { XCTAssertGreaterThan(next, offset); offset=next }
            more=page["has_more"] == .boolean(true)
        }
        XCTAssertEqual(combined,text)
        XCTAssertThrowsError(try MeetingReadContract.page(text, offset: 0.5))
        XCTAssertThrowsError(try MeetingReadContract.page(text, offset: 2_000_001))
    }
    func testSummarySourceDigestDetectsCorrectionsAndSpeakerRename() {
        var transcript = MeetingTranscript(locale: "en-US"); transcript.utterances=[.init(start: 0,end: 3,track: "mic",text: "Original")]
        let original=MeetingNotebook.digest(transcript)
        XCTAssertEqual(original,MeetingNotebook.digest(transcript))
        transcript.utterances[0].correction="Correction"; XCTAssertNotEqual(original,MeetingNotebook.digest(transcript))
        let edited=MeetingNotebook.digest(transcript);transcript.names["mic-0"]="Alex";XCTAssertNotEqual(edited,MeetingNotebook.digest(transcript))
    }
}

extension MeetingReadTests {
    func testStaleGeneratedNotesAreMarkedBeforePagedReadWithoutChangingSavedNotes() throws {
        let meeting = Meeting(title: "Authored review", source: "none", microphone: false)
        var source = MeetingTranscript(locale: "en-US")
        var line = MeetingUtterance(start: 7, end: 20, track: "mic",
            text: "I will send the draft Thursday. " + String(repeating: "説明 hello ", count: 500))
        line.speaker = "mic-0"; source.utterances = [line]; source.names["mic-0"] = "Alex"
        try source.validate()
        var notes = MeetingNotebook(meetingID: meeting.id)
        notes.summary = "[00:07] Alex will send the draft Thursday."
        notes.thoughts = "Private authored thought"
        notes.reviewed = true
        notes.sourceProvider = "apple"; notes.sourceDigest = MeetingNotebook.digest(source)
        notes.evidence = [try MeetingNoteEvidence(section: .summary,
            fact: "Alex will send the draft Thursday.", source: line)]
        try notes.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let savedNotes = try encoder.encode(notes)
        let marker = "Saved generated notes need review"

        // Positive controls use the genuine formatter with its existing renderer.
        let current = MeetingReadContract.text(meeting, notebook: notes, transcript: source, personal: false)
        XCTAssertFalse(current.contains(marker))
        XCTAssertTrue(current.contains(notes.markdown(title: meeting.title, includeThoughts: false)))
        XCTAssertFalse(current.contains(notes.thoughts))
        var manual = notes
        manual.sourceDigest = nil; manual.sourceProvider = nil; manual.evidence = nil
        let manualText = MeetingReadContract.text(meeting, notebook: manual, transcript: nil, personal: false)
        XCTAssertFalse(manualText.contains(marker))
        XCTAssertTrue(manualText.contains(manual.markdown(title: meeting.title, includeThoughts: false)))

        var corrected = source; corrected.utterances[0].correction = "I will not send the draft."
        var renamed = source; renamed.names["mic-0"] = "Sam"
        let cases: [(String, MeetingTranscript?)] = [
            ("corrected recognized words", corrected),
            ("corrected speaker name", renamed),
            ("source transcript unavailable", nil)
        ]
        for (label, transcript) in cases {
            if let transcript { XCTAssertFalse(notes.isCurrent(for: transcript), label) }
            let text = MeetingReadContract.text(meeting, notebook: notes, transcript: transcript, personal: false)
            // This assertion fails on the unchanged current formatter for all
            // three cases; genuine output must not silently imply currentness.
            XCTAssertTrue(text.contains(marker), label)
            XCTAssertTrue(text.contains(notes.markdown(title: meeting.title, includeThoughts: false)), label)
            XCTAssertFalse(text.contains(notes.thoughts), label)
            if label == "corrected speaker name" { XCTAssertTrue(text.contains("Sam:"), label) }
            if label == "corrected recognized words" { XCTAssertTrue(text.contains("I will not send the draft."), label) }
            var offset = 0.0, reconstructed = "", more = true
            while more {
                let page = try MeetingReadContract.page(text, offset: offset)
                try MeetingReadContract.read.output.validate(page)
                guard case .string(let part) = page["text"], case .number(let next) = page["next_offset"],
                      case .boolean(let remaining) = page["has_more"] else {
                    XCTFail("Invalid actual read page: " + label); break
                }
                XCTAssertLessThanOrEqual(part.utf8.count, 2048, label)
                reconstructed += part; more = remaining
                if more { XCTAssertGreaterThan(next, offset, label) }
                offset = next
            }
            XCTAssertEqual(reconstructed, text, label)
        }
        XCTAssertEqual(try encoder.encode(notes), savedNotes)
        let personal = MeetingReadContract.text(meeting, notebook: notes, transcript: corrected, personal: true)
        XCTAssertTrue(personal.contains(notes.thoughts))
    }
}
