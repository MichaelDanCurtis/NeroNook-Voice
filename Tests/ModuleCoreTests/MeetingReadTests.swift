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
