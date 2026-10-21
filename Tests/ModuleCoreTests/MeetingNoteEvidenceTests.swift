import XCTest
@testable import ModuleCore

final class MeetingNoteEvidenceTests: XCTestCase {
    private func fixture() throws -> (MeetingTranscript, MeetingNotebook) {
        var transcript = MeetingTranscript(locale: "en-US")
        transcript.utterances = [.init(start: 8, end: 12, track: "mic", text: "I propose Friday, but we have not agreed."),
                                 .init(start: 13, end: 17, track: "system", text: "We agreed Thursday. I will send the draft.")]
        var notebook = MeetingNotebook(meetingID: UUID())
        notebook.summary = "[00:13] Thursday was agreed."; notebook.actions = "[00:13] Send the draft."
        notebook.sourceDigest = MeetingNotebook.digest(transcript)
        notebook.evidence = [try .init(section: .summary, fact: "Thursday was agreed.", source: transcript.utterances[1]),
                             try .init(section: .actions, fact: "Send the draft.", source: transcript.utterances[1])]
        return (transcript, notebook)
    }
    func testStableIdentityNotClockOrArrayPositionResolvesSource() throws {
        let (transcript, notebook) = try fixture()
        let item = try XCTUnwrap(notebook.evidence?.first)
        XCTAssertEqual(try item.resolve(in: transcript, digest: notebook.sourceDigest).id, transcript.utterances[1].id)
        var reordered = transcript; reordered.utterances.reverse()
        XCTAssertThrowsError(try item.resolve(in: reordered, digest: notebook.sourceDigest))
        // A matching digest alone cannot authorize a missing/wrong passage.
        var substituted = transcript; substituted.utterances[1].id = UUID()
        XCTAssertThrowsError(try item.resolve(in: substituted, digest: MeetingNotebook.digest(substituted)))
        var altered = transcript; altered.utterances[1].start = 14
        XCTAssertThrowsError(try item.resolve(in: altered, digest: MeetingNotebook.digest(altered)))
    }
    func testCorrectionsAndNamesMakeEvidenceStaleAndDoNotRewriteSavedQuote() throws {
        let (transcript, notebook) = try fixture(); let item = try XCTUnwrap(notebook.evidence?.first)
        var corrected = transcript; corrected.utterances[1].correction = "We have not agreed a day."
        XCTAssertThrowsError(try item.resolve(in: corrected, digest: notebook.sourceDigest))
        XCTAssertThrowsError(try item.resolve(in: corrected, digest: MeetingNotebook.digest(corrected)))
        var named = transcript; named.names["system-0"] = "Authored name"
        XCTAssertThrowsError(try item.resolve(in: named, digest: notebook.sourceDigest))
        XCTAssertEqual(item.quote, transcript.utterances[1].text)
    }
    func testManualCategoryEditsRemoveOnlyItsLinksAndThoughtsKeepLinks() throws {
        var (_, notes) = try fixture(); let original = notes.evidence
        notes.edit(thoughts: "Private thought", summary: notes.summary, decisions: notes.decisions, actions: notes.actions, reviewed: true)
        XCTAssertEqual(notes.evidence, original)
        notes.edit(thoughts: notes.thoughts, summary: "My edited interpretation", decisions: "", actions: notes.actions, reviewed: false)
        XCTAssertEqual(notes.evidence?.map(\.section), [.actions]); XCTAssertFalse(notes.reviewed)
    }
    func testLegacyNotebookAndStructuredNotebookRoundTripWithBounds() throws {
        let (_, notebook) = try fixture(); let encoder = JSONEncoder()
        XCTAssertEqual(try JSONDecoder().decode(MeetingNotebook.self, from: encoder.encode(notebook)), notebook)
        var legacy = notebook; legacy.evidence = nil
        let decoded = try JSONDecoder().decode(MeetingNotebook.self, from: encoder.encode(legacy))
        XCTAssertNil(decoded.evidence); try decoded.validate()
        var invalid = notebook; invalid.evidence = Array(repeating: try XCTUnwrap(notebook.evidence?.first), count: 2)
        XCTAssertThrowsError(try invalid.validate())
        var mismatched = notebook; mismatched.summary = "Unrelated manual text"
        XCTAssertThrowsError(try mismatched.validate())
        let source = MeetingUtterance(start: 1, end: 2, track: "mic", text: String(repeating: "🧪", count: 100))
        let item = try MeetingNoteEvidence(section: .summary, fact: "Fixture", source: source)
        XCTAssertEqual(item.quote.utf8.count, 320)
        XCTAssertThrowsError(try MeetingNoteEvidence(section: .summary, fact: "", source: source))
    }
    func testDurableNotebookKeepsLinksAfterReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root); let meeting = Meeting(title: "Authored", source: "none", microphone: false)
        try store.save(meeting); let (transcript, draft) = try fixture()
        var notebook = MeetingNotebook(meetingID: meeting.id); notebook.summary = draft.summary; notebook.actions = draft.actions
        notebook.sourceDigest = draft.sourceDigest; notebook.evidence = draft.evidence
        try store.saveTranscript(transcript, id: meeting.id); try store.saveNotebook(notebook)
        let reopened = try MeetingStore(root: root).notebook(meeting.id)
        XCTAssertEqual(reopened, notebook)
        XCTAssertNoThrow(try reopened.evidence?.first?.resolve(in: transcript, digest: reopened.sourceDigest))
    }
}
