import XCTest
@testable import ModuleCore

final class MeetingEvidenceTests: XCTestCase {
    func testSourceClockCannotBecomeAnInventedDateAndReferencesMustExist() throws {
        let lines = [MeetingUtterance(start: 8, end: 16, track: "mic", text: "Alex will send the draft on Thursday.")]
        XCTAssertEqual(try MeetingEvidence.line("Alex will send the draft on Thursday.", source: 0, lines: lines), "[00:08] Alex will send the draft on Thursday.")
        XCTAssertThrowsError(try MeetingEvidence.line("Send the draft.", source: 1, lines: lines))
        XCTAssertThrowsError(try MeetingEvidence.line("Send the draft.", source: -1, lines: lines))
        XCTAssertThrowsError(try MeetingEvidence.line("Send on 2023-10-03.", source: 0, lines: lines))
    }
    func testExplicitDatesArePreservedButAdditionalFabricatedDatesAreRejected() throws {
        let lines = [MeetingUtterance(start: 3608, end: 3620, track: "mic", text: "Ship on 2026-10-16.")]
        XCTAssertEqual(try MeetingEvidence.line("Ship on 2026-10-16.", source: 0, lines: lines), "[60:08] Ship on 2026-10-16.")
        XCTAssertThrowsError(try MeetingEvidence.validate("Ship on 2026-10-16 and review on 2027-01-01.", source: 0, lines: lines))
    }
    func testChunkCannotCiteUnseenButOtherwiseValidTranscriptSource() throws {
        let lines = [
            MeetingUtterance(start: 8, end: 16, track: "mic", text: "Discuss draft."),
            MeetingUtterance(start: 65, end: 70, track: "system", text: "Ship Friday.")
        ]
        // Source 1 exists globally but was not in this model request.
        XCTAssertNoThrow(try MeetingEvidence.validate("Ship Friday.", source: 1, lines: lines))
        XCTAssertThrowsError(try MeetingEvidence.validate("Ship Friday.", source: 1, lines: lines, allowedSources: [0]))
        XCTAssertNoThrow(try MeetingEvidence.validate("Discuss draft.", source: 0, lines: lines, allowedSources: [0]))
        // A reduction can only retain sources represented by its input drafts.
        XCTAssertThrowsError(try MeetingEvidence.validate("Discuss draft.", source: 0, lines: lines, allowedSources: [1]))
        XCTAssertThrowsError(try MeetingEvidence.validate("Ship Friday.", source: 1, lines: lines, allowedSources: []))
    }
    func testMalformedClocksAndEmptyFactsFailWithoutRenderingOrTrapping() throws {
        for clock in [Double.nan, Double.infinity, -1, 14431] {
            let lines = [MeetingUtterance(start: clock, end: clock, track: "mic", text: "Original")]
            XCTAssertThrowsError(try MeetingEvidence.line("Fact", source: 0, lines: lines))
        }
        let lines = [MeetingUtterance(start: 0, end: 1, track: "mic", text: "Original")]
        XCTAssertThrowsError(try MeetingEvidence.line(" \n\t", source: 0, lines: lines))
    }

}
