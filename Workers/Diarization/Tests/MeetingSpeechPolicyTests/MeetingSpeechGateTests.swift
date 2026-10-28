import XCTest
@testable import MeetingSpeechPolicy

final class MeetingSpeechGateTests: XCTestCase {
    private func tone(_ amplitude: Float, _ frame: Int = 0) -> [Float] {
        (0..<1024).map { sin(Float($0 + frame * 1024) * 0.125) * amplitude }
    }
    func testQuietSignalCanStartAfterDigitalSilence() {
        var gate = MeetingSpeechGate()
        for n in 0..<100 { XCTAssertTrue(gate.isSilent(Array(repeating: 0, count: 1024), start: Double(n) * 0.064)) }
        XCTAssertFalse(gate.isSilent(tone(0.001), start: 6.4))
    }
    func testConstantOffsetDoesNotTriggerLowLevelAdmissionAndMemoryIsBounded() {
        var gate = MeetingSpeechGate()
        for n in 0..<1000 {
            XCTAssertTrue(gate.isSilent(Array(repeating: 0.001, count: 1024), start: Double(n) * 0.064))
            XCTAssertLessThanOrEqual(gate.observations, 50); XCTAssertLessThan(gate.bufferedFrames, 1024)
        }
    }
    func testSteadyLowNoiseAdaptsAndLouderSpeechRemainsAdmitted() {
        var gate = MeetingSpeechGate()
        for n in 0..<100 { _ = gate.isSilent(tone(0.0005, n), start: Double(n) * 0.064) }
        XCTAssertTrue(gate.isSilent(tone(0.0005, 100), start: 6.4))
        XCTAssertFalse(gate.isSilent(tone(0.003, 101), start: 6.464))
        XCTAssertFalse(gate.isSilent(tone(0.1, 102), start: 6.528))
    }
    func testExplicitResetAndDiscontinuityDiscardCalibration() {
        for discontinuity in [false, true] {
            var gate = MeetingSpeechGate()
            for n in 0..<100 { _ = gate.isSilent(tone(0.001, n), start: Double(n) * 0.064) }
            if !discontinuity { gate.reset() }
            XCTAssertFalse(gate.isSilent(tone(0.001), start: discontinuity ? 20 : 6.4))
            XCTAssertEqual(gate.observations, 1)
        }
    }
    func testSourcesDoNotShareNoiseEstimate() {
        var room = MeetingSpeechGate(), call = MeetingSpeechGate()
        for n in 0..<100 { _ = room.isSilent(tone(0.003, n), start: Double(n) * 0.064) }
        XCTAssertTrue(room.isSilent(tone(0.001), start: 6.4))
        XCTAssertFalse(call.isSilent(tone(0.001), start: 6.4))
    }
    func testInvalidInputResetsRatherThanPoisoningLaterSpeech() {
        var gate = MeetingSpeechGate()
        XCTAssertTrue(gate.isSilent([.nan], start: 0))
        XCTAssertTrue(gate.isSilent([1], start: .infinity))
        XCTAssertEqual(gate.observations, 0)
        XCTAssertFalse(gate.isSilent(tone(0.01), start: 0))
    }
}
