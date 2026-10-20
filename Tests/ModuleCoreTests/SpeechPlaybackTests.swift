import XCTest
@testable import ModuleCore

final class SpeechPlaybackTests: XCTestCase {
    func testStoppedSpeechCannotRestartOrFinishFromLateCallbacks() throws {
        var playback = SpeechPlayback()
        let old = try playback.begin("Hello")
        playback.stop()
        XCTAssertFalse(playback.started(old)); XCTAssertFalse(playback.finished(old))
        XCTAssertEqual(playback.phase, .idle)
        let current = try playback.begin("New reply")
        XCTAssertFalse(playback.finished(old)); XCTAssertTrue(playback.started(current))
        XCTAssertTrue(playback.finished(current)); XCTAssertFalse(playback.finished(current))
    }
    func testReplacementRetiresOldSpeechAndInvalidTextPreservesState() throws {
        var playback = SpeechPlayback()
        let old = try playback.begin("First")
        let current = try playback.begin("Second")
        XCTAssertFalse(playback.started(old))
        XCTAssertThrowsError(try playback.begin("  "))
        XCTAssertThrowsError(try playback.begin(String(repeating: "界", count: 700)))
        XCTAssertEqual(playback.token, current); XCTAssertTrue(playback.active)
    }
}
