import XCTest
@testable import MeetingSpeechPolicy
final class MeetingSpeechGapTests: XCTestCase {
    func testFirstPacketAndContinuousOutputDoNotInventSilence() {
        XCTAssertEqual(MeetingSpeechGap.action(previousEnd: nil, nextStart: 1), .none)
        XCTAssertEqual(MeetingSpeechGap.action(previousEnd: 1, nextStart: 1), .none)
        XCTAssertEqual(MeetingSpeechGap.action(previousEnd: 1, nextStart: 1.002), .none)
        XCTAssertEqual(MeetingSpeechGap.action(previousEnd: 1, nextStart: 0.998), .none)
    }
    func testShortMissingAudioPreservesExactSampleClockWithoutSettling() {
        XCTAssertEqual(MeetingSpeechGap.action(previousEnd: 1, nextStart: 1.2), .pad(3200))
        XCTAssertEqual(MeetingSpeechGap.action(previousEnd: 1, nextStart: 1.25), .pad(4000))
        XCTAssertEqual(MeetingSpeechGap.action(previousEnd: 1, nextStart: 1.0020625), .pad(33))
    }
    func testLongGapSettlesAndBackwardClockIsNotDiscardedAsReplay() {
        XCTAssertEqual(MeetingSpeechGap.action(previousEnd: 1, nextStart: 1.2500625), .settle)
        XCTAssertEqual(MeetingSpeechGap.action(previousEnd: 1, nextStart: 0.9), .reject)
        XCTAssertEqual(MeetingSpeechGap.action(previousEnd: 1, nextStart: 0.9979375), .reject)
    }
    func testInvalidTimesNeverBecomeAllocations() {
        for value in [Double.nan, .infinity, -1, 1e30] {
            XCTAssertEqual(MeetingSpeechGap.action(previousEnd: 1, nextStart: value), .reject)
            XCTAssertEqual(MeetingSpeechGap.action(previousEnd: value, nextStart: 1), .reject)
        }
    }
}
