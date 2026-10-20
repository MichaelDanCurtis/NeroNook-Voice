import Foundation
import XCTest
import NookPluginSDK
@testable import ModuleCore

final class MeetingChatTests: XCTestCase {
    func setupStore() throws -> MeetingStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try MeetingStore(root: url)
    }
    func fixture(_ store: MeetingStore, title: String = "Launch review", provider: MeetingASRProvider = .apple, live: Bool = false, text: String = "Launch is Friday. Alex owns the launch draft.") throws -> (Meeting, MeetingTranscript) {
        var m = Meeting(title: title, source: "none", microphone: true); m.state = "saved"; try store.save(m)
        var t = MeetingTranscript(locale: "en-US", provider: provider)
        t.utterances = [.init(start: 8.4, end: 12, track: "mic", text: text)]
        if live { try store.saveLiveTranscript(t, id: m.id, provider: provider) }
        else { try store.saveTranscript(t, id: m.id, provider: provider) }
        return (m, t)
    }
    func evidence(_ m: Meeting, _ t: MeetingTranscript) throws -> MeetingChatEvidence {
        try .current(meeting: m, transcript: t, provider: .apple, live: false, question: "When is launch?", context: [])
    }
    func testConversationSurvivesReloadWithoutChangingRecordingTranscriptOrNotes() throws {
        let store = try setupStore(), (m, t) = try fixture(store)
        var notes = MeetingNotebook(meetingID: m.id); notes.thoughts = "Private sentinel"; try store.saveNotebook(notes)
        let files = ["meeting.json", "transcript.json", "notebook.json"]
        let before = try files.map { try Data(contentsOf: store.folder(m.id).appendingPathComponent($0)) }
        XCTAssertTrue(try store.chat(m.id).turns.isEmpty)
        let snapshot = try evidence(m, t); var turn = MeetingChatTurn(evidence: snapshot, assistant: "Test assistant")
        turn.phase = "completed"; turn.answer = .init(snapshot: snapshot.question.snapshot, disposition: "answered", statements: [.init(text: "Friday.", citations: ["s1"])])
        var chat = MeetingChat(meetingID: m.id); chat.turns.append(turn); try store.saveChat(chat)
        let loaded = try MeetingStore(root: store.root).chat(m.id)
        XCTAssertEqual(loaded.turns.first?.id, turn.id); XCTAssertEqual(loaded.context().first?.answer, "Friday.")
        XCTAssertFalse(try PluginEvidenceAnswerContract.json(loaded).contains("Private sentinel"))
        XCTAssertEqual(try files.map { try Data(contentsOf: store.folder(m.id).appendingPathComponent($0)) }, before)
        XCTAssertEqual(try loaded.turns[0].evidence.sources[0].resolve(meetingID: m.id, transcript: t).id, t.utterances[0].id)
    }
    func testLibraryFindsBothMeetingsFallbackProviderAndOriginalLiveVariant() throws {
        let store = try setupStore()
        let (a, _) = try fixture(store, provider: .nemotron, text: "Launch is Friday. Alex owns the launch draft.")
        let (b, bt) = try fixture(store, title: "Budget review", provider: .parakeet, live: true, text: "Launch changed to Monday. Jordan owns the launch draft.")
        _ = try fixture(store, title: "No transcript placeholder")
        let q = try MeetingChatEvidence.library(store: store, meetings: [a, b], preferred: .nemotron, question: "How did the launch change between meetings?", context: [])
        XCTAssertEqual(q.meetingCount, 2); XCTAssertTrue(q.fullCoverage); XCTAssertEqual(q.scannedMeetings, 2)
        XCTAssertEqual(Set(q.sources.map(\.meetingID)), Set([a.id, b.id])); XCTAssertTrue(q.question.sources.contains { $0.label.contains("Budget review") })
        let source = try XCTUnwrap(q.sources.first { $0.meetingID == b.id }); XCTAssertTrue(source.live); XCTAssertEqual(source.provider, .parakeet)
        XCTAssertEqual(try source.resolve(meetingID: b.id, transcript: bt).start, 8.4)
        try q.validate()
        let copy = try JSONDecoder().decode(MeetingChatEvidence.self, from: JSONEncoder().encode(q)); try copy.validate()
    }
    func testChangedDeletedAndOtherMeetingSourcesAreRejectedButChatIsRetained() throws {
        let store = try setupStore(); let (m, t) = try fixture(store); let q = try evidence(m, t)
        var changed = t; changed.utterances[0].correction = "Monday instead."
        XCTAssertThrowsError(try q.sources[0].resolve(meetingID: m.id, transcript: changed))
        XCTAssertThrowsError(try q.sources[0].resolve(meetingID: UUID(), transcript: t))
        changed.utterances = []; XCTAssertThrowsError(try q.sources[0].resolve(meetingID: m.id, transcript: changed))
        var chat = MeetingChat(meetingID: m.id); chat.turns.append(.init(evidence: q, assistant: "Test")); try store.saveChat(chat)
        XCTAssertTrue(chat.recoverInterrupted()); XCTAssertFalse(chat.recoverInterrupted()); try store.saveChat(chat)
        XCTAssertEqual(try store.chat(m.id).turns[0].phase, "interrupted")
    }
    func testPendingRecoveryAndPreviousConversationAreLocalAndNotAutomaticallySent() throws {
        let store = try setupStore(); let (m, t) = try fixture(store); var chat = MeetingChat(meetingID: m.id)
        chat.turns.append(.init(evidence: try evidence(m, t), assistant: "Test")); try store.saveChat(chat)
        var loaded = try store.chat(m.id); XCTAssertTrue(loaded.recoverInterrupted()); try store.saveChat(loaded, previous: true)
        try store.saveChat(.init(meetingID: m.id)); XCTAssertTrue(try store.chat(m.id).turns.isEmpty)
        XCTAssertTrue(store.hasPreviousChat(m.id)); XCTAssertEqual(try store.chat(m.id, previous: true).turns[0].phase, "interrupted")
    }
    func testStoreRejectsForeignIdentitySymlinkAndCorruptChatWithoutOverwritingIt() throws {
        let store = try setupStore(); let (a, t) = try fixture(store); let (b, _) = try fixture(store)
        var chat = MeetingChat(meetingID: b.id); chat.turns.append(.init(evidence: try evidence(a, t), assistant: "Test"))
        XCTAssertThrowsError(try store.saveChat(chat))
        let url = store.folder(a.id).appendingPathComponent("chat-v1.json"), outside = store.root.appendingPathComponent("unrelated.txt")
        try Data("Do not touch".utf8).write(to: outside); try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        XCTAssertThrowsError(try store.chat(a.id)); XCTAssertThrowsError(try store.saveChat(.init(meetingID: a.id)))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "Do not touch")
        try FileManager.default.removeItem(at: url); let bad = Data("{broken".utf8); try bad.write(to: url)
        XCTAssertThrowsError(try store.chat(a.id)); XCTAssertEqual(try Data(contentsOf: url), bad)
    }
    func testFollowupUsesPriorQuestionForLocalSelectionAndHistoryNeverBecomesASource() throws {
        let store = try setupStore(); let (m, _) = try fixture(store)
        var t = MeetingTranscript(locale: "en-US"); t.utterances = (0..<300).map { .init(start: Double($0), end: Double($0 + 1), track: "mic", text: "Routine housekeeping for the meeting.") }
        t.utterances[290].text = "Jordan owns the rocket launch draft."
        let context = [PluginEvidenceExchange(question: "What is happening with the rocket launch?", answer: "Unsupported historical claim.")]
        let q = try MeetingChatEvidence.current(meeting: m, transcript: t, provider: .apple, live: false, question: "Who owns it?", context: context)
        XCTAssertTrue(q.sources.contains { $0.utteranceID == t.utterances[290].id })
        XCTAssertFalse(q.sources.contains { $0.evidence.text.contains("Unsupported historical claim") })
        let values = try PluginEvidenceChatContract.values(q.question, history: q.context)
        let decoded = try PluginEvidenceChatContract.decode(values); XCTAssertEqual(decoded.0, q.question); XCTAssertEqual(decoded.1, context)
        XCTAssertThrowsError(try PluginEvidenceQuestion(values: values)) // old contract stays unchanged
    }
    func testUnicodePreviewAndTwoExchangeHistoryFitTheCustomViewBudget() throws {
        let store = try setupStore(); var (m, t) = try fixture(store); m.title = String(repeating: "名", count: 40)
        t.utterances = (0..<25).map { .init(start: Double($0), end: Double($0+1), track: "mic", text: String(repeating: "😄 中文 \\\"\n", count: 300)) }
        let context = [PluginEvidenceExchange(question: "Earlier question", answer: String(repeating: "\\\"", count: 150))]
        let q = try MeetingChatEvidence.current(meeting: m, transcript: t, provider: .apple, live: false, question: "What happened?", context: context)
        let view = MeetingQuestionViewState(busy: false, question: q.question.question, status: "Preview", provider: "test.agent/answer_evidence_chat", providers: [], prepared: true, coverage: q.coverage, sources: q.sources.map(\.evidence), answer: nil, highlight: "", context: context)
        var state: [String: PluginValue] = ["ask": .string(try PluginEvidenceAnswerContract.json(view)), "library": .string(String(repeating: "名", count: 600))]
        for i in 0..<40 { state["field\(i)"] = .string(String(repeating: "x", count: 30)) }
        XCTAssertNoThrow(try PluginCustomView(entry: "meetings/index.html", revision: "test", state: state).validate())
        XCTAssertLessThan(try JSONEncoder().encode(state).count, 32768)
        try q.validate()
    }
    func testLibraryDoesNotClaimCoverageForMissingTranscriptsAndContextIsBounded() throws {
        let store = try setupStore(); let (m, t) = try fixture(store)
        var missing = Meeting(title: "No transcript", source: "none", microphone: false); missing.state = "saved"; try store.save(missing)
        let q = try MeetingChatEvidence.library(store: store, meetings: [m, missing], preferred: .apple, question: "Launch?", context: [])
        XCTAssertFalse(q.fullCoverage); XCTAssertEqual(q.unavailableMeetings, 1)
        var chat = MeetingChat(meetingID: m.id)
        for _ in 0..<8 { var turn = MeetingChatTurn(evidence: try evidence(m, t), assistant: "Test"); turn.phase = "completed"; turn.answer = .init(snapshot: turn.evidence.question.snapshot, disposition: "answered", statements: [.init(text: "Friday.", citations: ["s1"])]); chat.turns.append(turn) }
        XCTAssertLessThanOrEqual(chat.context().count, 4); try PluginEvidenceChatContract.validate(chat.context())
    }
}
