import XCTest
@testable import ModuleCore

final class MeetingActionResolutionTests: XCTestCase {
    private func transcript() -> MeetingTranscript {
        var value = MeetingTranscript(locale: "en-US")
        value.names = ["mic-0": "Lena", "system-0": "Omar"]
        for (index, text) in ["I will prepare the launch checklist by Monday.",
                              "I will take over the launch checklist from Lena and finish it Wednesday instead.",
                              "Cancel the launch checklist. We no longer need it."].enumerated() {
            var turn = MeetingUtterance(start: Double(index * 10), end: Double(index * 10 + 8),
                                        track: index == 1 ? "system" : "mic", text: text)
            turn.speaker = index == 1 ? "system-0" : "mic-0"; value.utterances.append(turn)
        }
        return value
    }
    private var reassigned: MeetingActionProposal {
        .init(task: "prepare the launch checklist", taskSource: 0, owner: "I", ownerSource: 1,
              deadline: "Wednesday", deadlineSource: 1, sources: [0, 1])
    }
    private func resolve(_ input: [MeetingActionProposal], _ transcript: MeetingTranscript? = nil) throws -> [MeetingActionResolution] {
        try MeetingActionResolution.resolve(input, transcript: transcript ?? self.transcript(), allowedSources: [0, 1, 2])
    }
    private func notebook(_ resolutions: [MeetingActionResolution], transcript: MeetingTranscript) -> MeetingNotebook {
        var value = MeetingNotebook(meetingID: UUID()); value.actionResolutions = resolutions
        value.sourceDigest = MeetingNotebook.digest(transcript)
        value.evidence = resolutions.filter { $0.status == .active }.map { $0.evidence[0] }
        value.actions = (value.evidence ?? []).map { String(format: "[%02d:%02d] ", Int($0.start)/60, Int($0.start)%60) + $0.fact }.joined(separator: "\n")
        return value
    }
    func testReassignmentUsesQuotedCurrentOwnerAndDeadlineWithBothSources() throws {
        let source = transcript(), item = try XCTUnwrap(resolve([reassigned], source).first)
        XCTAssertEqual(item.owner, "Omar"); XCTAssertEqual(item.deadline, "Wednesday")
        XCTAssertEqual(item.evidence.map(\.utteranceID), Array(source.utterances.prefix(2)).map(\.id))
        XCTAssertTrue(item.fact.contains("Omar")); XCTAssertFalse(item.fact.contains("Monday"))
        for link in item.evidence { XCTAssertNoThrow(try link.resolve(in: source, digest: MeetingNotebook.digest(source))) }
    }
    func testCancelledTaskIsAbsentFromActiveListButRetainsNavigableChanges() throws {
        var proposal = reassigned; proposal.status = "cancelled"; proposal.sources = [0, 1, 2]
        let source = transcript(), value = notebook(try resolve([proposal], source), transcript: source)
        try value.validate(); XCTAssertTrue(value.actions.isEmpty)
        XCTAssertTrue(value.taskChanges.contains("Cancelled")); XCTAssertEqual(value.actionCards.first?.status, "cancelled")
        XCTAssertEqual(value.actionResolutions?.first?.evidence.count, 3)
        XCTAssertTrue(value.markdown(title: "Authored", includeThoughts: false).contains("Task changes"))
    }
    func testUnknownSpeakerAndPronounsNeverBecomeNamedOwners() throws {
        var source = transcript(); source.names["system-0"] = "Room speaker 2"
        XCTAssertNil(try resolve([reassigned], source).first?.owner)
        source.names = [:]; XCTAssertNil(try resolve([reassigned], source).first?.owner)
        var proposal = reassigned; proposal.owner = "We"; proposal.ownerSource = 2
        proposal.sources = [0, 1, 2]; XCTAssertNil(try resolve([proposal]).first?.owner)
    }
    func testAbsentDeadlineStaysAbsentRatherThanBorrowingAnotherTaskDate() throws {
        var proposal = reassigned; proposal.deadline = ""; proposal.deadlineSource = -1
        let result = try XCTUnwrap(resolve([proposal]).first)
        XCTAssertNil(result.deadline); XCTAssertTrue(result.fact.contains("No deadline stated"))
    }
    func testUncertainProposalIsNotAnActiveCommitment() throws {
        var proposal = reassigned; proposal.status = "uncertain"
        let source = transcript(), value = notebook(try resolve([proposal], source), transcript: source)
        try value.validate(); XCTAssertTrue(value.actions.isEmpty); XCTAssertTrue(value.taskChanges.contains("Needs review"))
    }
    func testInventedFieldsUnknownSourceAndUnsupportedStateRefuse() throws {
        var inputs: [MeetingActionProposal] = []
        var p = reassigned; p.task = "send the invoice"; inputs.append(p)
        p = reassigned; p.owner = "Invented Person"; inputs.append(p)
        p = reassigned; p.deadline = "2027-03-01"; inputs.append(p)
        p = reassigned; p.ownerSource = -1; inputs.append(p)
        p = reassigned; p.taskSource = 999; inputs.append(p)
        p = reassigned; p.sources = [0, 1, 999]; inputs.append(p)
        p = reassigned; p.sources = [0, 0, 1]; inputs.append(p)
        p = reassigned; p.sources = [0]; inputs.append(p)
        p = reassigned; p.status = "completed-by-tool"; inputs.append(p)
        for input in inputs { XCTAssertThrowsError(try resolve([input])) }
        XCTAssertThrowsError(try MeetingActionResolution.resolve([reassigned], transcript: transcript(), allowedSources: [0]))
        XCTAssertThrowsError(try resolve([reassigned, reassigned]))
        XCTAssertThrowsError(try resolve(Array(repeating: reassigned, count: 13)))
    }
    func testCorrectionAndRenamingInvalidateEveryActionSource() throws {
        let original = transcript(), item = try XCTUnwrap(resolve([reassigned], original).first)
        var changed = original; changed.utterances[1].correction = "Nobody took over."
        for evidence in item.evidence { XCTAssertThrowsError(try evidence.resolve(in: changed, digest: MeetingNotebook.digest(original))) }
        changed = original; changed.names["system-0"] = "Different name"
        XCTAssertThrowsError(try item.evidence[0].resolve(in: changed, digest: MeetingNotebook.digest(original)))
        XCTAssertThrowsError(try resolve([reassigned], { var corrected = original; corrected.utterances[1].correction = "No deadline."; return corrected }()))
    }
    func testSavedRoundTripAndManualEditRetainOrClearAllActionMetadata() throws {
        let source = transcript(); var value = notebook(try resolve([reassigned], source), transcript: source)
        try value.validate()
        let decoded = try JSONDecoder().decode(MeetingNotebook.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value); XCTAssertEqual(decoded.actionCards.first?.sources.count, 2)
        value.edit(thoughts: "Personal note", summary: "", decisions: "", actions: value.actions, reviewed: false)
        XCTAssertNotNil(value.actionResolutions)
        value.edit(thoughts: value.thoughts, summary: "", decisions: "", actions: "My manual action", reviewed: true)
        XCTAssertNil(value.actionResolutions); XCTAssertTrue(value.evidence?.isEmpty == true); try value.validate()
    }
    func testOldNotebookWithoutResolutionMetadataStillDecodes() throws {
        let value = MeetingNotebook(meetingID: UUID())
        let decoded = try JSONDecoder().decode(MeetingNotebook.self, from: JSONEncoder().encode(value))
        XCTAssertNil(decoded.actionResolutions); try decoded.validate()
    }
}
