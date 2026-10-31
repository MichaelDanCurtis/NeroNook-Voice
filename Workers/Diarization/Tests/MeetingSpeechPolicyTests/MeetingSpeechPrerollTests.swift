import XCTest
@testable import MeetingSpeechPolicy

final class MeetingSpeechPrerollTests: XCTestCase {
    func testQuietLeadingSyllablesArriveOnceWithTheirRealClock() throws {
        var value = MeetingSpeechPreroll()
        let quiet = (0..<4096).map { Float($0) / 1_000_000 }
        for n in 0..<4 { value.append(Array(quiet[(n*1024)..<((n+1)*1024)]), start: 2 + Double(n*1024)/16000) }
        let prefix = try XCTUnwrap(value.take(before: 2.256))
        XCTAssertEqual(prefix.start, 2, accuracy: 0.000001); XCTAssertEqual(prefix.pcm, quiet)
        XCTAssertEqual(value.bufferedFrames, 0); XCTAssertNil(value.take(before: 2.256))
    }
    func testThirtySecondsSilenceRemainsBoundedAndOnlyLatestFramesSurvive() throws {
        var value = MeetingSpeechPreroll()
        for n in 0..<480 { value.append(Array(repeating: Float(n), count: 1000), start: Double(n)/16); XCTAssertLessThanOrEqual(value.bufferedFrames, 5600) }
        let prefix = try XCTUnwrap(value.take(before: 30))
        XCTAssertEqual(prefix.start, 29.65, accuracy: 0.000001); XCTAssertEqual(prefix.pcm.count, 5600)
        XCTAssertEqual(Array(prefix.pcm.prefix(600)), Array(repeating: 474, count: 600))
        XCTAssertEqual(Array(prefix.pcm.suffix(1000)), Array(repeating: 479, count: 1000))
    }
    func testTrackStatesDoNotBorrowEachOthersAudio() throws {
        var room = MeetingSpeechPreroll(), call = MeetingSpeechPreroll()
        room.append(Array(repeating: 1, count: 1600), start: 0)
        call.append(Array(repeating: 2, count: 800), start: 0.05)
        XCTAssertEqual(try XCTUnwrap(room.take(before: 0.1)).pcm, Array(repeating: 1, count: 1600))
        XCTAssertEqual(try XCTUnwrap(call.take(before: 0.1)).pcm, Array(repeating: 2, count: 800))
    }
    func testGapOverlapAndExplicitCommitResetCannotLeakOldPCM() {
        for next in [0.5, 0.05] {
            var value = MeetingSpeechPreroll(); value.append(Array(repeating: 1, count: 1600), start: 0)
            XCTAssertNil(value.take(before: next)); XCTAssertEqual(value.bufferedFrames, 0)
        }
        var value = MeetingSpeechPreroll(); value.append(Array(repeating: 1, count: 1600), start: 0)
        value.reset(); XCTAssertNil(value.take(before: 0.1))
        value.append(Array(repeating: 2, count: 1600), start: 2)
        XCTAssertEqual(value.take(before: 2.1)?.pcm, Array(repeating: 2, count: 1600))
    }
    func testAppendAfterGapKeepsOnlyNewPCMAndLargePacketKeepsTail() throws {
        var value = MeetingSpeechPreroll(); value.append(Array(repeating: 1, count: 1600), start: 0)
        value.append(Array(repeating: 2, count: 1600), start: 2)
        XCTAssertEqual(try XCTUnwrap(value.take(before: 2.1)).pcm, Array(repeating: 2, count: 1600))
        value.append((0..<16384).map(Float.init), start: 4)
        let prefix = try XCTUnwrap(value.take(before: 5.024))
        XCTAssertEqual(prefix.pcm, (10784..<16384).map(Float.init)); XCTAssertEqual(prefix.start, 4.674, accuracy: 0.000001)
    }
}
