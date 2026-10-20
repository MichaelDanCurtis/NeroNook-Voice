import XCTest
@testable import ModuleCore

final class ConversationInterruptionTests: XCTestCase {
    private let reply = "The capital of Spain is Madrid and it is a beautiful city."
    func testRecognizedWordsCannotBypassAcousticEvidenceDuringPlayback() {
        var gate = ConversationInterruption(); gate.beginPlayback(reply, at: 1)
        XCTAssertEqual(gate.decision(text: "Wait a moment", start: 1.1, end: 1.4, now: 1.4), .hold)
        for i in 0..<8 { gate.audio(rms: 0.003, playbackLevel: 0.4, through: 1.1 + Double(i) * 0.1, allowed: true) }
        XCTAssertEqual(gate.decision(text: "Wait a moment", start: 1.1, end: 1.8, now: 1.8), .hold)
        for i in 0..<4 { gate.audio(rms: 0.05, playbackLevel: 0.4, through: 2 + Double(i) * 0.1, allowed: true) }
        XCTAssertEqual(gate.decision(text: "Wait a moment", start: 2, end: 2.3, now: 2.3), .accept)
        gate.admitUser(at: 2.3)
        XCTAssertFalse(gate.protects(at: 2.3))
    }
    func testOwnWordsRemainEchoEvenAfterLoudAcousticEvidence() {
        var gate = ConversationInterruption(); gate.beginPlayback(reply, at: 1)
        for i in 0..<5 { gate.audio(rms: 0.2, playbackLevel: 0.9, through: 1.1 + Double(i) * 0.1, allowed: true) }
        XCTAssertEqual(gate.decision(text: "The capital of Spain is Madrid", start: 1.1, end: 1.5, now: 1.5), .echo)
        XCTAssertEqual(gate.decision(text: "Wait, I have a different question", start: 1.1, end: 1.5, now: 1.5), .accept)
        XCTAssertEqual(gate.decision(text: "", start: 1.1, end: 1.5, now: 1.5), .hold)
    }
    func testLowerSensitivityRequiresFirmerAndLongerEvidence() {
        var low = ConversationInterruption(sensitivity: 0), high = ConversationInterruption(sensitivity: 100)
        low.beginPlayback(reply, at: 1); high.beginPlayback(reply, at: 1)
        XCTAssertGreaterThan(low.requiredDuration, high.requiredDuration)
        for i in 0..<3 {
            let time = 1.1 + Double(i) * 0.1
            low.audio(rms: 0.012, playbackLevel: 0.05, through: time, allowed: true)
            high.audio(rms: 0.012, playbackLevel: 0.05, through: time, allowed: true)
        }
        XCTAssertEqual(low.decision(text: "Stop", start: 1.1, end: 1.3, now: 1.3), .hold)
        XCTAssertEqual(high.decision(text: "Stop", start: 1.1, end: 1.3, now: 1.3), .accept)
    }
    func testRepeatedMeterSamplesAndCaptureGapsCannotAccumulateEvidence() {
        var gate = ConversationInterruption(); gate.beginPlayback(reply, at: 1)
        for _ in 0..<10 { gate.audio(rms: 0.1, playbackLevel: 0.2, through: 1.1, allowed: true) }
        XCTAssertEqual(gate.decision(text: "Wait", start: 1.1, end: 1.2, now: 1.2), .hold)
        gate.audio(rms: 0.1, playbackLevel: 0.2, through: 2, allowed: true)
        XCTAssertEqual(gate.decision(text: "Wait", start: 2, end: 2.1, now: 2.1), .hold)
        gate.audio(rms: .nan, playbackLevel: 0.2, through: 2.1, allowed: true)
        gate.audio(rms: 0.1, playbackLevel: 0.2, through: 2.2, allowed: false)
        XCTAssertEqual(gate.decision(text: "Wait", start: 2, end: 2.2, now: 2.2), .hold)
    }
    func testDelayedEchoIsRejectedButQuietRepliesOutsidePlaybackStillWork() {
        var gate = ConversationInterruption(); gate.beginPlayback(reply, at: 1); gate.endPlayback(at: 2)
        XCTAssertTrue(gate.protects(at: 2.1)); XCTAssertFalse(gate.protects(at: 2.5))
        XCTAssertEqual(gate.decision(text: "The capital of Spain is Madrid", start: 1.2, end: 2.1, now: 2.7), .echo)
        XCTAssertEqual(gate.decision(text: "Yes", start: 2.6, end: 2.7, now: 2.8), .accept)
        gate.resetEvidence()
        XCTAssertEqual(gate.decision(text: "The capital of Spain is Madrid", start: 4, end: 5, now: 5), .accept, "A later deliberate quotation must not be treated as perpetual echo")
    }
}
