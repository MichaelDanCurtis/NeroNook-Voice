import XCTest
@testable import ModuleCore

final class MeetingLiveSpeakerTests: XCTestCase {
    func testAlignmentPreservesExactSpacingButRejectsChangedWords() throws {
        let words = [MeetingWord(text: "Hello.", start: 0, end: 1), .init(text: " How", start: 1, end: 2), .init(text: " are you?", start: 2, end: 3)]
        let text = "Hello.  How are you?"
        let aligned = try XCTUnwrap(MeetingWordAlignment.preserving(text, words: words))
        XCTAssertEqual(aligned.map(\.text).joined(), text); XCTAssertEqual(aligned.map(\.start), words.map(\.start))
        XCTAssertNil(MeetingWordAlignment.preserving("Hello.  Who are you?", words: words))
        var transcript = MeetingTranscript(locale: "en-US")
        var line = MeetingUtterance(start: 0, end: 3, track: "mic", text: text); line.words = words; transcript.utterances = [line]
        try transcript.assign([.init(start: 0, end: 1, speaker: 0), .init(start: 1, end: 3, speaker: 1)], track: "mic")
        XCTAssertEqual(transcript.utterances.count, 2); XCTAssertEqual(Set(transcript.utterances.compactMap(\.speaker)).count, 2)
        XCTAssertEqual(transcript.utterances.map(\.text), ["Hello.", "How are you?"])
    }
    func testTwoPeoplePerSourceAndCommittedTimingStayIndependent() throws {
        var state = MeetingLiveSpeakers(); let epoch = state.epoch
        for track in ["mic", "system"] { try state.receive(track: track, spans: [.init(start: 0, end: 1, speaker: 0), .init(start: 1, end: 2, speaker: 1)], through: 2, epoch: epoch) }
        var transcript = MeetingTranscript(locale: "en-US")
        for track in ["mic", "system"] {
            var line = MeetingUtterance(start: 0, end: 2, track: track, text: "Hello. Goodbye.")
            line.words = [.init(text: "Hello. ", start: 0, end: 1), .init(text: "Goodbye.", start: 1, end: 2)]
            transcript.utterances.append(line)
        }
        let result = try state.applying(to: transcript, final: true)
        XCTAssertEqual(result.utterances.count, 4)
        XCTAssertEqual(Set(result.utterances.compactMap(\.speaker)), ["mic-0","mic-1","system-0","system-1"])
        XCTAssertEqual(result.utterances.first?.id, transcript.utterances.first?.id)
        _ = try state.applying(to: result)
        let again = try state.applying(to: transcript)
        XCTAssertEqual(result.utterances.map(\.id), again.utterances.map(\.id))
        XCTAssertEqual(Set(result.labelledTracks), ["mic","system"])
    }
    func testUnknownOverlapAndReviewedEditsArePreserved() throws {
        var state = MeetingLiveSpeakers(); let epoch = state.epoch
        try state.receive(track: "mic", spans: [.init(start:0,end:2,speaker:0),.init(start:0,end:2,speaker:1)], through:2,epoch:epoch)
        var transcript = MeetingTranscript(locale:"en-US")
        transcript.utterances = [.init(start:0,end:2,track:"mic",text:"Overlapping voices"),.init(start:2,end:3,track:"system",text:"Not analysed yet")]
        let result = try state.applying(to:transcript)
        XCTAssertTrue(result.utterances.allSatisfy{$0.speaker == nil})
        transcript.utterances[0].speaker = "mic-7"; transcript.utterances[0].reviewed = true;transcript.names["mic-7"]="Alex"
        XCTAssertEqual(try state.applying(to:transcript).utterances[0].speaker,"mic-7")
        XCTAssertEqual(try state.applying(to:transcript).names["mic-7"],"Alex")
    }
    func testLateEpochInvalidSpansAndOldClocksCannotAlterSession() throws {
        var state = MeetingLiveSpeakers();let old=state.epoch;state.reset()
        try state.receive(track:"mic",spans:[.init(start:0,end:2,speaker:0)],through:2,epoch:old)
        XCTAssertTrue(state.through.isEmpty)
        XCTAssertThrowsError(try state.receive(track:"mic",spans:[.init(start:0,end:2,speaker:8)],through:2,epoch:state.epoch))
        try state.receive(track:"mic",spans:[],through:2,epoch:state.epoch)
        XCTAssertThrowsError(try state.receive(track:"mic",spans:[],through:1,epoch:state.epoch))
        XCTAssertThrowsError(try state.receive(track:"mic",spans:[.init(start:1,end:3,speaker:0)],through:3,epoch:state.epoch))
    }
}
