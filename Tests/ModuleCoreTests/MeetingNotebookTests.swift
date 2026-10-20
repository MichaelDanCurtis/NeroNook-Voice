import XCTest
@testable import ModuleCore

final class MeetingNotebookTests: XCTestCase {
    func testNotebookSurvivesReloadWithoutOverwritingTranscriptOrPrivateNotesExport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), meeting = Meeting(title: "Project review", source: "none", microphone: true)
        try store.save(meeting)
        var transcript = MeetingTranscript(locale: "en-US"); transcript.utterances = [.init(start: 1, end: 2, track: "mic", text: "Original speech")]
        try store.saveTranscript(transcript, id: meeting.id)
        var notebook = try store.notebook(meeting.id)
        notebook.thoughts = "Private concern"; notebook.summary = "Summary"; notebook.actions = "- [ ] Alex: follow up"; notebook.reviewed = true
        try store.saveNotebook(notebook)
        XCTAssertEqual(try MeetingStore(root: root).notebook(meeting.id), notebook)
        XCTAssertEqual(try store.transcript(meeting.id)?.utterances.first?.text, "Original speech")
        XCTAssertFalse(notebook.markdown(title: meeting.title, includeThoughts: false).contains("Private concern"))
        XCTAssertTrue(notebook.markdown(title: meeting.title, includeThoughts: true).contains("Private concern"))
    }
    func testInvalidOversizedOrCrossMeetingNotesCannotReplaceSavedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), meeting = Meeting(title: "Test", source: "none", microphone: true)
        try store.save(meeting); var notebook = MeetingNotebook(meetingID: meeting.id); notebook.summary = "Keep me"; try store.saveNotebook(notebook)
        var invalid = notebook; invalid.thoughts = String(repeating: "界", count: 700)
        XCTAssertThrowsError(try store.saveNotebook(invalid)); XCTAssertEqual(try store.notebook(meeting.id).summary, "Keep me")
        let other = MeetingNotebook(meetingID: UUID())
        try JSONEncoder().encode(other).write(to: store.folder(meeting.id).appendingPathComponent("notebook.json"))
        XCTAssertThrowsError(try store.notebook(meeting.id))
    }
    func testGeneratedProvenanceRejectsCorrectionsNamesAndSourceSwitches() throws {
        var transcript = MeetingTranscript(locale: "en-US")
        transcript.utterances = [.init(start: 8, end: 10, track: "mic", text: "Review Thursday.")]
        var notebook = MeetingNotebook(meetingID: UUID())
        XCTAssertFalse(notebook.isCurrent(for: transcript))
        notebook.sourceDigest = MeetingNotebook.digest(transcript)
        XCTAssertTrue(notebook.isCurrent(for: transcript))
        var corrected = transcript; corrected.utterances[0].correction = "Review Friday."
        XCTAssertFalse(notebook.isCurrent(for: corrected))
        var named = transcript; named.names["mic-0"] = "Authored speaker"
        XCTAssertFalse(notebook.isCurrent(for: named))
        var changedSource = transcript; changedSource.modelRevision = "other-source-revision"
        XCTAssertFalse(notebook.isCurrent(for: changedSource))
        let encoded = try JSONEncoder().encode(notebook)
        XCTAssertTrue(try JSONDecoder().decode(MeetingNotebook.self, from: encoded).isCurrent(for: transcript))
    }

    func testGeneratedSaveRetainsNotesAfterDurableSourceOrNotesChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(title: "Authored summary race fixture", source: "none", microphone: true)
        try store.save(meeting)
        var transcript = MeetingTranscript(locale: "en-US")
        transcript.utterances = [.init(start: 0, end: 2, track: "mic", text: "Review Thursday.")]
        try store.saveTranscript(transcript, id: meeting.id)
        var original = MeetingNotebook(meetingID: meeting.id); original.thoughts = "Keep private"; original.summary = "Keep previous"
        try store.saveNotebook(original)
        var generated = original; generated.summary = "Generated replacement"; generated.sourceDigest = MeetingNotebook.digest(transcript)
        transcript.utterances[0].correction = "Review Friday."
        try store.saveTranscript(transcript, id: meeting.id)
        XCTAssertThrowsError(try store.saveGeneratedNotebook(generated, replacing: original, provider: .apple, live: false))
        XCTAssertEqual(try store.notebook(meeting.id), original)
        generated.sourceDigest = MeetingNotebook.digest(transcript)
        var edited = original; edited.decisions = "A later manual edit"
        try store.saveNotebook(edited)
        XCTAssertThrowsError(try store.saveGeneratedNotebook(generated, replacing: original, provider: .apple, live: false))
        XCTAssertEqual(try store.notebook(meeting.id), edited)
        // Choosing the absent live variant cannot silently reuse the refined one.
        XCTAssertThrowsError(try store.saveGeneratedNotebook(generated, replacing: edited, provider: .apple, live: true))
        try store.saveGeneratedNotebook(generated, replacing: edited, provider: .apple, live: false)
        XCTAssertEqual(try store.notebook(meeting.id), generated)
        XCTAssertEqual(try store.notebook(meeting.id).thoughts, "Keep private")
    }

}
