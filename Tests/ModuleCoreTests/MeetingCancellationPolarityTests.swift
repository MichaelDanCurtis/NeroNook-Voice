import XCTest
@testable import ModuleCore

final class MeetingCancellationPolarityTests: XCTestCase {
    private func transcript(_ followup: String) -> MeetingTranscript {
        var value = MeetingTranscript(locale: "en-US")
        value.names = ["mic-0": "Lena"]
        for (i, text) in ["I will prepare the launch checklist by Monday.", followup].enumerated() {
            var turn = MeetingUtterance(start: Double(i * 10), end: Double(i * 10 + 8), track: "mic", text: text)
            turn.speaker = "mic-0"
            value.utterances.append(turn)
        }
        return value
    }
    func testNegatedCancellationPreservesCommitmentOwnerAndDeadline() throws {
        for text in ["Do not cancel the launch checklist.", "Don't cancel the launch checklist.",
                     "Don’t cancel the launch checklist.", "We have not cancelled the launch checklist.",
                     "We haven't canceled the launch checklist.", "The launch checklist is not cancelled.",
                     "Never cancel the launch checklist."] {
            let source = transcript(text)
            let proposals = try MeetingActionReconciler.proposals(source)
            let original = try XCTUnwrap(proposals.first { $0.task == "prepare the launch checklist" }, text)
            XCTAssertEqual(original.status, "active", text)
            let resolved = try MeetingActionResolution.resolve([original], transcript: source, allowedSources: [0, 1])
            XCTAssertEqual(resolved.first?.owner, "Lena", text)
            XCTAssertEqual(resolved.first?.deadline, "Monday", text)
        }
    }
    func testExplicitCancellationStillRemovesActiveCommitment() throws {
        for text in ["Cancel the launch checklist.", "We cancelled the launch checklist."] {
            let proposals = try MeetingActionReconciler.proposals(transcript(text))
            XCTAssertEqual(proposals.first?.status, "cancelled", text)
            XCTAssertEqual(proposals.first?.sources, [0, 1], text)
        }
    }
    func testNegationInEarlierSentenceDoesNotSuppressLaterCancellation() throws {
        let source = transcript("Do not cancel the release notes. Cancel the launch checklist.")
        let proposals = try MeetingActionReconciler.proposals(source)
        XCTAssertEqual(proposals.first?.status, "cancelled")
    }
}
