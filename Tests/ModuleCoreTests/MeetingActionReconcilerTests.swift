import XCTest
@testable import ModuleCore

final class MeetingActionReconcilerTests: XCTestCase {
    private func transcript(_ turns: [(String, String)], names: [String: String] = ["mic-0": "Alice", "system-0": "Ben"]) -> MeetingTranscript {
        var value = MeetingTranscript(locale: "en-US"); value.names = names
        for (index, pair) in turns.enumerated() {
            var turn = MeetingUtterance(start: Double(index * 10), end: Double(index * 10 + 8), track: pair.0, text: pair.1)
            turn.speaker = pair.0 + "-0"; value.utterances.append(turn)
        }
        return value
    }
    private func resolved(_ source: MeetingTranscript) throws -> [MeetingActionResolution] {
        try MeetingActionResolution.resolve(MeetingActionReconciler.proposals(source), transcript: source,
                                            allowedSources: Set(source.utterances.indices))
    }
    func testFrozenEightOriginalEvidenceCasesWithoutModelOrGoldInInputs() throws {
        struct Active: Decodable { var taskContains: String; var owner: String?; var deadlineContains: String? }
        struct Gold: Decodable { var active: [Active]; var cancelled: [String] }
        struct Fixture: Decodable { var id: String; var names: [String: String]; var turns: [[String?]]; var gold: Gold }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/meeting-action-cases.json")
        let cases = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: path))
        XCTAssertEqual(cases.count, 8)
        for fixture in cases {
            var source = MeetingTranscript(locale: "en-US"); source.names = fixture.names
            for (index, turn) in fixture.turns.enumerated() {
                var line = MeetingUtterance(start: Double(index * 8), end: Double(index * 8 + 7), track: turn[0]!, text: turn[2]!)
                line.speaker = turn[1]; source.utterances.append(line)
            }
            let tasks = try resolved(source), active = tasks.filter { $0.status == .active }
            XCTAssertEqual(active.count, fixture.gold.active.count, fixture.id)
            for expected in fixture.gold.active {
                let task = try XCTUnwrap(active.first { $0.task.localizedCaseInsensitiveContains(expected.taskContains) }, fixture.id)
                XCTAssertEqual(task.owner, expected.owner, fixture.id)
                if let deadline = expected.deadlineContains { XCTAssertTrue(task.deadline?.contains(deadline) == true, fixture.id) }
                else { XCTAssertNil(task.deadline, fixture.id) }
            }
            for cancelled in fixture.gold.cancelled {
                XCTAssertTrue(tasks.contains { $0.status == .cancelled && $0.task.contains(cancelled) }, fixture.id)
            }
            for task in tasks { for link in task.evidence { XCTAssertNoThrow(try link.resolve(in: source, digest: MeetingNotebook.digest(source))) } }
        }
    }
    func testSharedWorkWithoutExplicitTakeoverNeedsReview() throws {
        let tasks = try resolved(transcript([("mic", "I will send the invoice by Friday."), ("system", "I will send the invoice by Friday.")]))
        XCTAssertEqual(tasks.count, 1); XCTAssertEqual(tasks[0].status, .uncertain); XCTAssertNil(tasks[0].owner)
    }
    func testFormerOwnerWithdrawalDoesNotCancelCurrentOwner() throws {
        let tasks = try resolved(transcript([("mic", "I will prepare the report by Friday."),
                                            ("system", "I will take over the report from Alice by Monday instead."),
                                            ("mic", "I am no longer responsible for the report.")]))
        XCTAssertEqual(tasks[0].status, .active); XCTAssertEqual(tasks[0].owner, "Ben"); XCTAssertEqual(tasks[0].deadline, "Monday")
    }
    func testAmbiguousCancellationDoesNotPickOneOfTwoTasksWithSameObject() throws {
        let tasks = try resolved(transcript([("mic", "I will write the report. I will review the report."),
                                            ("system", "Cancel the report.")]))
        XCTAssertEqual(tasks.count, 2); XCTAssertTrue(tasks.allSatisfy { $0.status == .uncertain })
    }
    func testExplicitNewPromiseCanReopenCancelledTaskWithoutOldDeadline() throws {
        let tasks = try resolved(transcript([("mic", "I will send the invoice by Friday."), ("mic", "Cancel the invoice."),
                                            ("system", "I will send the invoice.")]))
        XCTAssertEqual(tasks.count, 1); XCTAssertEqual(tasks[0].status, .active); XCTAssertEqual(tasks[0].owner, "Ben"); XCTAssertNil(tasks[0].deadline)
    }
    func testReportedQuotesAndConditionalsAreNotActiveCommitments() throws {
        for text in ["If I will send the report tomorrow, let me know.", "For example, I will send the report tomorrow.", "Yesterday she said, ‘I will send the report tomorrow.’"] {
            let tasks = try resolved(transcript([("mic", text)])); XCTAssertFalse(tasks.contains { $0.status == .active }, text)
        }
    }
    func testAnotherPersonsRefusalDoesNotCancelTheOwner() throws {
        let tasks = try resolved(transcript([("mic", "I will send the invoice by Friday."), ("system", "I will not send the invoice.")]))
        XCTAssertEqual(tasks[0].status, .active); XCTAssertEqual(tasks[0].owner, "Alice")
    }
    func testConditionalOrReportedCancellationKeepsActualPromiseActive() throws {
        for text in ["If we cancel the report, we can save time.", "For example, cancel the report.", "She said cancel the report yesterday."] {
            let tasks = try resolved(transcript([("mic", "I will write the report by Friday."), ("system", text)]))
            XCTAssertEqual(tasks.filter { $0.status == .active }.count, 1, text)
            XCTAssertEqual(tasks.first?.owner, "Alice"); XCTAssertEqual(tasks.first?.deadline, "Friday")
        }
    }
    func testExplicitConfirmationOfPreviouslyConditionalPromise() throws {
        let tasks = try resolved(transcript([("mic", "If I will write the report, let me know."), ("mic", "I will write the report.")]))
        XCTAssertEqual(tasks.first?.status, .active); XCTAssertEqual(tasks.first?.owner, "Alice")
    }
    func testUnsupportedPhrasingBecomesReviewCandidateAndBoundsRefuse() throws {
        let tasks = try resolved(transcript([("mic", "Zara could perhaps redesign the interface.")]))
        XCTAssertEqual(tasks[0].status, .uncertain); XCTAssertNil(tasks[0].owner)
        XCTAssertThrowsError(try MeetingActionReconciler.proposals(transcript((0..<13).map { ("mic", "I will write document \($0).") })))
    }
    func testLiteralTimesRelativeDatesAndReportedRevision() throws {
        let time = try resolved(transcript([("mic", "I will call the client at 2 PM.")]))
        XCTAssertEqual(time.first?.task, "call the client"); XCTAssertEqual(time.first?.deadline, "2 PM")
        let relative = try resolved(transcript([("mic", "I will send the proposal in two weeks.")]))
        XCTAssertEqual(relative.first?.deadline, "in two weeks")
        let reported = try resolved(transcript([("mic", "I will send the board pack by Monday."),
                                               ("system", "I heard Friday replaces Monday for the board pack.")]))
        XCTAssertEqual(reported.first?.deadline, "Monday")
    }
}
