import XCTest
import NookPluginSDK
@testable import ModuleCore

final class MeetingQuestionTests: XCTestCase {
    func transcript(_ count: Int = 3) -> MeetingTranscript {
        var t = MeetingTranscript(locale: "en-US", provider: .nemotron)
        t.utterances = (0..<count).map { MeetingUtterance(start: Double($0 * 10), end: Double($0 * 10 + 5), track: "mic", text: "Passage \($0): Alex will send the launch draft on Thursday.") }
        return t
    }
    func testExactCorrectionsStableSourcesAndNoPrivateNotebookInput() throws {
        var t = transcript(); t.utterances[1].correction = "Jordan will review it on Friday."
        let id = UUID(), snapshot = try MeetingQuestionSnapshot.prepare(meetingID: id, transcript: t, provider: .nemotron, live: true, question: "Who reviews the draft?")
        XCTAssertTrue(snapshot.fullCoverage); XCTAssertEqual(snapshot.sources.count, 3)
        XCTAssertEqual(snapshot.sources[1].evidence.text, t.utterances[1].correction)
        let roundtrip = try PluginEvidenceQuestion(values: snapshot.question.values()); XCTAssertEqual(roundtrip, snapshot.question)
        let source = snapshot.sources[1]
        XCTAssertEqual(try snapshot.resolve(source.evidence.id, meetingID: id, transcript: t).id, t.utterances[1].id)
        t.utterances.append(.init(start: 40, end: 45, track: "mic", text: "New live words."))
        XCTAssertNoThrow(try snapshot.resolve(source.evidence.id, meetingID: id, transcript: t))
        t.utterances[1].correction = "Changed after answer."
        XCTAssertThrowsError(try snapshot.resolve(source.evidence.id, meetingID: id, transcript: t))
        XCTAssertThrowsError(try snapshot.resolve(source.evidence.id, meetingID: UUID(), transcript: t))
        XCTAssertThrowsError(try snapshot.resolve("s999", meetingID: id, transcript: t))
    }
    func testCitationsRejectMissingUnknownDuplicateAndWrongSnapshot() throws {
        let q = try MeetingQuestionSnapshot.prepare(meetingID: UUID(), transcript: transcript(), provider: .nemotron, live: false, question: "When?").question
        func answer(_ refs: [String], digest: String? = nil) -> PluginEvidenceAnswer { .init(snapshot: digest ?? q.snapshot, disposition: "answered", statements: [.init(text: "Thursday.", citations: refs)]) }
        XCTAssertNoThrow(try answer(["s1"]).validate(for: q))
        for refs in [[], ["s999"], ["s1", "s1"]] { XCTAssertThrowsError(try answer(refs).validate(for: q)) }
        XCTAssertThrowsError(try answer(["s1"], digest: String(repeating: "f", count: 64)).validate(for: q))
        XCTAssertNoThrow(try PluginEvidenceAnswer(snapshot: q.snapshot, disposition: "insufficient", statements: []).validate(for: q))
        XCTAssertThrowsError(try PluginEvidenceAnswer(snapshot: q.snapshot, disposition: "answered", statements: []).validate(for: q))
    }
    func testLongMeetingSelectionIsBoundedVisibleAndFindsLexicalMatch() throws {
        var t = transcript(1000)
        t.utterances[900].text = "The budget approval belongs to Morgan, not Alex."
        let snapshot = try MeetingQuestionSnapshot.prepare(meetingID: UUID(), transcript: t, provider: .nemotron, live: false, question: "Who owns budget approval?")
        XCTAssertFalse(snapshot.fullCoverage); XCTAssertLessThan(snapshot.selectedTurns, snapshot.totalTurns)
        XCTAssertTrue(snapshot.sources.contains { $0.utteranceID == t.utterances[900].id })
        XCTAssertLessThanOrEqual(try snapshot.question.values().count, 10)
        try PluginEvidenceAnswerContract.action.input.validate(snapshot.question.values())
    }
    func testUnicodeFragmentsAndEscapedPreviewFitWireBudget() throws {
        var t = transcript(15); t.utterances = t.utterances.map { line in var l = line; l.text = String(repeating: "😄 中文 \\\"\n", count: 550); return l }
        let snapshot = try MeetingQuestionSnapshot.prepare(meetingID: UUID(), transcript: t, provider: .apple, live: true, question: "What happened?")
        XCTAssertFalse(snapshot.fullCoverage); XCTAssertTrue(snapshot.sources.allSatisfy { $0.fragment && $0.evidence.text.utf8.count <= 1100 })
        let view = MeetingQuestionViewState(busy: false, question: snapshot.question.question, status: "Preview", provider: "test.agent/answer_evidence", providers: [], prepared: true, coverage: "Selected excerpt", sources: snapshot.sources.map(\.evidence), answer: nil, highlight: "")
        let state: [String: PluginValue] = ["ask": .string(try PluginEvidenceAnswerContract.json(view))]
        XCTAssertLessThan(try JSONEncoder().encode(state).count, 25_000)
        XCTAssertNoThrow(try PluginCustomView(entry: "meetings/index.html", revision: "test", state: state).validate())
    }
    func testUnicodeSpeakerLabelsFitWithoutBreakingCharacters() throws {
        var t = transcript(); t.names["mic-0"] = String(repeating: "名", count: 33); t.utterances[0].speaker = "mic-0"
        let value = try MeetingQuestionSnapshot.prepare(meetingID: UUID(), transcript: t, provider: .apple, live: false, question: "Who?")
        XCTAssertTrue(value.sources.allSatisfy { $0.evidence.label.utf8.count <= 120 && !$0.evidence.label.contains("�") })
        XCTAssertNoThrow(try value.question.values())
    }
    func testAdapterRejectsMalformedAndNonReadOnlyProviders() throws {
        var entry = PluginCatalogEntry(address: .init("test.assistant", PluginEvidenceAnswerContract.id), action: PluginEvidenceAnswerContract.action)
        XCTAssertTrue(PluginEvidenceAnswerContract.accepts(entry)); entry.action?.effect = .externalChange; XCTAssertFalse(PluginEvidenceAnswerContract.accepts(entry))
        let q = try MeetingQuestionSnapshot.prepare(meetingID: UUID(), transcript: transcript(), provider: .apple, live: false, question: "When?").question
        var values = try q.values(); values["sources_2"] = values["sources_0"]
        XCTAssertThrowsError(try PluginEvidenceQuestion(values: values))
        values = try q.values(); values["audio_path"] = .string("/private/audio")
        XCTAssertThrowsError(try PluginEvidenceQuestion(values: values))
    }
}
