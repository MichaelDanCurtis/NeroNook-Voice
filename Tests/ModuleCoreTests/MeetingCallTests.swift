import XCTest
@testable import ModuleCore

final class MeetingCallTests: XCTestCase {
    let signal = MeetingCallSignal(source: "com.microsoft.teams2", appName: "Teams", evidence: .callControls)
    func testStableCallOffersOnceAndDismissedCallDoesNotNag() {
        var state = MeetingCallState()
        XCTAssertNil(state.observe(signal, at: 10, available: true))
        let offer = state.observe(signal, at: 12, available: true); XCTAssertNotNil(offer)
        XCTAssertNil(state.observe(signal, at: 14, available: true))
        state.dismiss(offer!.id); XCTAssertNil(state.observe(signal, at: 20, available: true))
        XCTAssertTrue(state.isFresh(offer!.id, at: 21))
        _ = state.observe(nil, at: 22, available: true); XCTAssertFalse(state.isFresh(offer!.id, at: 22))
        _ = state.observe(nil, at: 31, available: true)
        _ = state.observe(signal, at: 32, available: true)
        XCTAssertNotEqual(state.observe(signal, at: 34, available: true)?.id, offer!.id)
    }
    func testBusyReconnectionAndStaleReviewCannotStartCapture() {
        var state = MeetingCallState()
        _ = state.observe(signal, at: 0, available: false)
        XCTAssertNil(state.observe(signal, at: 2, available: false))
        let offer = state.observe(signal, at: 4, available: true)!
        XCTAssertFalse(state.isFresh(offer.id, at: 9))
        _ = state.observe(nil, at: 5, available: false)
        XCTAssertFalse(state.isFresh(offer.id, at: 5))
        XCTAssertNil(state.observe(signal, at: 6, available: true))
        var other = signal; other.source = "com.google.Chrome"; other.browserWide = true
        _ = state.observe(other, at: 7, available: true)
        XCTAssertFalse(state.isFresh(offer.id, at: 7))
        XCTAssertEqual(state.observe(other, at: 9, available: true)?.signal.browserWide, true)
    }
    func testLowerConfidenceNeedsLongerAndResetRetiresButtons() {
        var state = MeetingCallState(), possible = signal; possible.evidence = .microphoneActivity
        _ = state.observe(possible, at: 0, available: true)
        XCTAssertNil(state.observe(possible, at: 2, available: true))
        let offer = state.observe(possible, at: 5, available: true)!
        state.reset(); XCTAssertFalse(state.isFresh(offer.id, at: 5))
        XCTAssertNil(state.observe(signal, at: .nan, available: true))
    }
}
