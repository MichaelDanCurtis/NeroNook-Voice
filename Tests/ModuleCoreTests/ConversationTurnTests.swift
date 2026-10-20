import XCTest
@testable import ModuleCore

final class ConversationTurnTests: XCTestCase {
    func testQuickPauseRequiresFinalRecognitionAndStillWaitsForSilence() throws {
        var gate=ConversationTurn(pace:.quick);begin(&gate)
        try gate.receive(.init(track:"mic",start:0,end:1.2,text:"Hello Nero",final:false),now:1.2)
        XCTAssertFalse(gate.canCommit(at:2.0))
        try gate.receive(.init(track:"mic",start:0,end:1.9,text:"Hello, Nero.",final:true),now:1.9)
        XCTAssertFalse(gate.canCommit(at:1.99));XCTAssertTrue(gate.canCommit(at:2.05))
        _=gate.audio(rms:0.03,through:2.04,allowed:true)
        XCTAssertFalse(gate.canCommit(at:2.2))
        XCTAssertTrue(gate.canCommit(at:2.85))
    }
    func testQuickQuietAndLaterVolatileSpeechRetainProtection() throws {
        var gate=ConversationTurn(pace:.quick)
        try gate.receive(.init(track:"mic",start:0,end:0.2,text:"Yes.",final:true),now:0.3)
        XCTAssertFalse(gate.canCommit(at:0.9));XCTAssertTrue(gate.canCommit(at:1.0))
        try gate.receive(.init(track:"mic",start:0.3,end:0.9,text:"And another thought",final:false),now:1.0)
        XCTAssertFalse(gate.canCommit(at:1.3));XCTAssertTrue(gate.canCommit(at:1.9))
    }
    func testOldNoiseCannotShortenALaterQuietRecognizedTurn() throws {
        var gate=ConversationTurn();begin(&gate)
        try gate.receive(.init(track:"mic",start:10,end:10.2,text:"Yes",final:true),now:10.3)
        XCTAssertFalse(gate.canCommit(at:10.9));XCTAssertTrue(gate.canCommit(at:11.3))
    }
    func testRecognizerTrailingSilenceIsNotCountedTwice() throws {
        var gate=ConversationTurn(); begin(&gate)
        try gate.receive(.init(track:"mic",start:0,end:1.2,text:"Hello Nero",final:false),now:1.2)
        try gate.receive(.init(track:"mic",start:0,end:1.9,text:"Hello Nero",final:true),now:1.9)
        XCTAssertFalse(gate.canCommit(at:2.1));XCTAssertTrue(gate.canCommit(at:2.2))
        XCTAssertEqual(gate.commit(through:2.2),"Hello Nero")
        try gate.receive(.init(track:"mic",start:2.2,end:2.4,text:"Yes",final:true),now:2.5)
        XCTAssertFalse(gate.canCommit(at:3.2));XCTAssertTrue(gate.canCommit(at:3.5))
    }
    func testContinuedAudioAndLateWordsStillHoldTheTurn() throws {
        var gate=ConversationTurn();begin(&gate)
        try gate.receive(.init(track:"mic",start:0,end:1.2,text:"Can you",final:false),now:1.2)
        XCTAssertFalse(gate.canCommit(at:2.1))
        _=gate.audio(rms:0.03,through:2.1,allowed:true)
        try gate.receive(.init(track:"mic",start:0,end:2.8,text:"Can you help?",final:true),now:2.9)
        XCTAssertFalse(gate.canCommit(at:3.1));XCTAssertTrue(gate.canCommit(at:3.5))
    }
    func testDuplexChangesRespectThinkingAndDoNotReopenHalfCapture() {
        var state = ConversationDuplexState(mode: .full, phase: .thinking)
        XCTAssertTrue(state.listening)
        state.mode = .half; XCTAssertFalse(state.listening)
        state.phase = .speaking; XCTAssertFalse(state.listening)
        state.phase = .thinking; XCTAssertFalse(state.listening) // playback drained, caller still owns the turn
        state.phase = .listening; XCTAssertTrue(state.listening)
        state.mode = .full; state.phase = .speaking; XCTAssertTrue(state.listening)
        state.phase = .preparing; XCTAssertFalse(state.listening)
        state.phase = .closed; XCTAssertFalse(state.listening)
    }
    func testRetirementClockNeverMovesBackwardAfterModeChange() throws {
        var gate = ConversationTurn()
        gate.discard(through: 3)
        _ = gate.commit(through: 2)
        try gate.receive(.init(track:"mic",start:2,end:2.5,text:"Retired",final:true),now:3)
        XCTAssertTrue(gate.text.isEmpty)
        try gate.receive(.init(track:"mic",start:3,end:3.5,text:"Fresh",final:true),now:3.5)
        XCTAssertEqual(gate.text,"Fresh")
    }
    private func begin(_ gate: inout ConversationTurn) {
        XCTAssertFalse(gate.audio(rms: 0.03, through: 1, allowed: true))
        XCTAssertFalse(gate.audio(rms: 0.03, through: 1.1, allowed: true))
        XCTAssertTrue(gate.audio(rms: 0.03, through: 1.2, allowed: true))
    }
    func testSilenceRequiresSpeechAndStableWordsAndCommitsOnlyOnce() throws {
        var gate = ConversationTurn(); begin(&gate)
        try gate.receive(.init(track: "mic", start: 0, end: 1.2, text: "Hello Nero", final: false), now: 1.2)
        XCTAssertFalse(gate.canCommit(at: 1.8)); XCTAssertTrue(gate.canCommit(at: 2.3))
        XCTAssertEqual(gate.commit(through: 2.3), "Hello Nero"); XCTAssertFalse(gate.canCommit(at: 5))
        try gate.receive(.init(track: "mic", start: 0, end: 1.2, text: "Late replay", final: true), now: 3)
        XCTAssertEqual(gate.text, "")
    }
    func testHalfDuplexGateAndDuplicateFinalsDoNotProduceNewTurn() throws {
        var gate = ConversationTurn()
        for n in 0..<10 { XCTAssertFalse(gate.audio(rms: 0.3, through: Double(n), allowed: false)) }
        XCTAssertFalse(gate.speaking); begin(&gate)
        let update = MeetingLiveUpdate(track: "mic", start: 0, end: 1.2, text: "One sentence.", final: true)
        try gate.receive(update, now: 1.2); try gate.receive(update, now: 1.3)
        XCTAssertEqual(gate.text, "One sentence.")
        try gate.receive(.init(track: "mic", start: 1.3, end: 2, text: "Next thought", final: false), now: 2)
        XCTAssertEqual(gate.text, "One sentence. Next thought")
        XCTAssertFalse(gate.canCommit(at: 2.3))
    }
    func testOversizedTurnFailsWithoutSubmittingIt() throws {
        var gate = ConversationTurn(); begin(&gate)
        XCTAssertThrowsError(try gate.receive(.init(track: "mic", start: 0, end: 1, text: String(repeating: "a", count: 2049), final: true), now: 1))
        XCTAssertTrue(gate.text.isEmpty)
    }
    func testFinalizationReplacesOverlappingIntervalsAndRejectsLateVolatileText() throws {
        var gate = ConversationTurn(); begin(&gate)
        try gate.receive(.init(track: "mic", start: 0, end: 1.2, text: "Hello Nero", final: true), now: 1.2)
        try gate.receive(.init(track: "mic", start: 0, end: 1.25, text: "Hello, Nero.", final: true), now: 1.3)
        try gate.receive(.init(track: "mic", start: 0, end: 1.25, text: "Hello Nero", final: false), now: 1.4)
        XCTAssertEqual(gate.text, "Hello, Nero.")
    }
    func testRecognizedQuietShortReplyCanEndWithoutThreeLoudMeterTicks() throws {
        var gate=ConversationTurn()
        XCTAssertFalse(gate.audio(rms:0.002,through:0.2,allowed:true))
        try gate.receive(.init(track:"mic",start:0,end:0.2,text:"Yes.",final:true),now:0.3)
        XCTAssertTrue(gate.speaking);XCTAssertTrue(gate.canCommit(at:1.3))
        XCTAssertEqual(gate.commit(through:1.3),"Yes.")
    }
}
