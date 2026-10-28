import XCTest
@testable import ModuleCore

final class MeetingWordCoverageTests: XCTestCase {
    private func phrase(track: String = "mic") -> MeetingUtterance {
        var line = MeetingUtterance(start: 0, end: 5, track: track, text: "Hello. Thanks.")
        line.words = [.init(text: "Hello.", start: 0, end: 0.4), .init(text: " Thanks.", start: 4.6, end: 5)]
        return line
    }
    func testSilenceBetweenAlignedWordsCannotEraseTheirSpeaker() throws {
        var value = MeetingTranscript(locale: "en-US"); let line = phrase(); value.utterances = [line]
        try value.assign([.init(start: 0, end: 0.4, speaker: 0), .init(start: 4.6, end: 5, speaker: 0)], track: "mic")
        XCTAssertEqual(value.utterances.map(\.speaker), ["mic-0", "mic-0"])
        XCTAssertEqual(value.utterances.map(\.text), ["Hello.", "Thanks."])
    }
    func testAnotherPersonInTheAlignmentGapIsNotTheAuthorOfThoseWords() throws {
        var value = MeetingTranscript(locale: "en-US"); value.utterances = [phrase()]
        try value.assign([.init(start: 0, end: 0.4, speaker: 0), .init(start: 0.5, end: 4.5, speaker: 1),
                          .init(start: 4.6, end: 5, speaker: 0)], track: "mic")
        XCTAssertEqual(value.utterances.map(\.speaker), ["mic-0", "mic-0"])
    }
    func testCloseAlignedWordsIgnoreCompetingActivityOnlyBetweenThem() throws {
        var line = MeetingUtterance(start: 0, end: 1.2, track: "system", text: "One two")
        line.words = [.init(text: "One", start: 0, end: 0.1), .init(text: " two", start: 1.1, end: 1.2)]
        var value = MeetingTranscript(locale: "en-US"); value.utterances = [line]
        try value.assign([.init(start: 0, end: 0.1, speaker: 2), .init(start: 0.2, end: 1, speaker: 3),
                          .init(start: 1.1, end: 1.2, speaker: 2)], track: "system")
        XCTAssertEqual(value.utterances.count, 1); XCTAssertEqual(value.utterances.first?.speaker, "system-2")
        XCTAssertEqual(value.utterances.first?.id, line.id)
        XCTAssertEqual(value.utterances.first?.text, line.text)
    }
    func testActualWordOverlapStaysUnknown() throws {
        var line = phrase(); line.words = [.init(text: "Hello.", start: 0, end: 0.4), .init(text: " Thanks.", start: 0.5, end: 0.9)]
        var value = MeetingTranscript(locale: "en-US"); value.utterances = [line]
        try value.assign([.init(start: 0, end: 5, speaker: 0), .init(start: 0, end: 5, speaker: 1)], track: "mic")
        XCTAssertTrue(value.utterances.allSatisfy { $0.speaker == nil })
    }
    func testInvalidWordClocksCannotManufactureCoverage() throws {
        for words in [
            [MeetingWord(text: "Hello.", start: 0, end: 0), .init(text: " Thanks.", start: 5, end: 5)],
            [.init(text: "Hello.", start: 4, end: 5), .init(text: " Thanks.", start: 0, end: 1)],
            [.init(text: "Hello.", start: 0, end: 1), .init(text: " Thanks.", start: 0.5, end: 1.5)]
        ] {
            var line = phrase(); line.words = words
            var value = MeetingTranscript(locale: "en-US"); value.utterances = [line]
            try value.assign([.init(start: 0, end: 0.4, speaker: 0), .init(start: 4.6, end: 5, speaker: 0)], track: "mic")
            XCTAssertEqual(value.utterances.count, 1); XCTAssertNil(value.utterances.first?.speaker)
            XCTAssertEqual(value.utterances.first?.text, line.text)
        }
    }
    func testNoWordTimingKeepsConservativePhraseCoverage() throws {
        var line = phrase(); line.words = nil
        var value = MeetingTranscript(locale: "en-US"); value.utterances = [line]
        try value.assign([.init(start: 0, end: 0.4, speaker: 0), .init(start: 4.6, end: 5, speaker: 0)], track: "mic")
        XCTAssertNil(value.utterances.first?.speaker)
    }
    func testManualCorrectionAndOtherTrackRemainExact() throws {
        var manual = phrase(); manual.correction = "Edited words"; manual.speaker = "mic-6"
        let other = phrase(track: "system")
        var value = MeetingTranscript(locale: "en-US"); value.utterances = [manual, other]; value.names["mic-6"] = "Alex"
        try value.assign([.init(start: 0, end: 5, speaker: 0)], track: "mic")
        XCTAssertEqual(value.utterances, [manual, other]); XCTAssertEqual(value.names["mic-6"], "Alex")
    }
}
