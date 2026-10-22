import XCTest
@testable import ModuleCore

final class MeetingCorrectionProtectionTests: XCTestCase {
    func testEditedSpeakerAssignmentSurvivesReanalysisWithoutReviewedFlag() throws {
        var transcript = MeetingTranscript(locale:"en-US")
        var line=MeetingUtterance(start:0,end:2,track:"mic",text:"Original")
        line.correction="Corrected text";line.speaker="mic-3";transcript.names["mic-3"]="Mara"
        transcript.utterances=[line]
        try transcript.assign([.init(start:0,end:2,speaker:0)],track:"mic")
        XCTAssertEqual(transcript.utterances[0],line)
    }
}
