import XCTest
@testable import ModuleCore

final class MeetingLiveTests: XCTestCase {
    func testInvalidAlignmentCannotConsumeTheFinalClock() throws {
        var state = MeetingLiveState(); let epoch = try state.begin(tracks: ["mic"], offset: 0)
        let bad = MeetingLiveUpdate(track: "mic", start: 0, end: 1, text: "hello", final: true,
            words: [.init(text: "hello", start: 0, end: 2)])
        XCTAssertThrowsError(try state.receive(bad, epoch: epoch)); XCTAssertTrue(state.settled.isEmpty)
        let valid = MeetingLiveUpdate(track: "mic", start: 0, end: 1, text: "hello", final: true,
            words: [.init(text: "hello", start: 0, end: 1)])
        XCTAssertTrue(try state.receive(valid, epoch: epoch)); XCTAssertEqual(state.settled.first?.words?.count, 1)
    }
    func testCatchUpCanOnlyDisplaySelectedOriginalWordsWithSafeExcerptBounds() throws {
        let lines: [MeetingUtterance] = [.init(start: 8, end: 16, track: "mic", text: "Alex will send the draft Thursday."), .init(start: 16, end: 24, track: "system", text: "We have not decided on colors.")]
        let brief = try MeetingEvidence.excerpts([1,0,0], lines: lines)
        XCTAssertEqual(brief, "[00:08] Alex will send the draft Thursday.\n[00:16] We have not decided on colors.")
        XCTAssertThrowsError(try MeetingEvidence.excerpts([2], lines: lines))
        var echoed = lines[0]; echoed.start = 30; echoed.end = 38; echoed.track = "system"
        XCTAssertEqual(try MeetingEvidence.excerpts([0,2], lines: lines+[echoed]), "[00:08] Alex will send the draft Thursday.")
        var long = lines[0]; long.text = String(repeating: "家庭 👨‍👩‍👧‍👦 ", count: 50)
        let excerpt = try MeetingEvidence.excerpts([0], lines: [long])
        XCTAssertLessThan(excerpt.utf8.count, 300); XCTAssertTrue(excerpt.hasSuffix("…")); XCTAssertFalse(excerpt.contains("�"))
    }
    func testVolatileWordsReplaceAndFinalEvidenceCannotBeReplayed() throws {
        var state = MeetingLiveState(); let epoch = try state.begin(tracks: ["mic", "system"], offset: 0)
        try state.receive(.init(track: "mic", start: 0, end: 1, text: "We should launch on", final: false), epoch: epoch)
        try state.receive(.init(track: "mic", start: 0, end: 2, text: "We agreed to launch Friday", final: false), epoch: epoch)
        XCTAssertTrue(state.settled.isEmpty); XCTAssertEqual(state.partials.count, 1)
        XCTAssertEqual(state.partials["mic"]?.text, "We agreed to launch Friday")
        XCTAssertTrue(try state.receive(.init(track: "mic", start: 0, end: 2, text: "We agreed to launch Friday.", final: true), epoch: epoch))
        XCTAssertTrue(state.partials.isEmpty)
        XCTAssertFalse(try state.receive(.init(track: "mic", start: 0, end: 2, text: "Changed replay", final: true), epoch: epoch))
        try state.receive(.init(track: "system", start: 0.5, end: 1.5, text: "I will send the draft.", final: true), epoch: epoch)
        XCTAssertEqual(state.settled.count, 2); XCTAssertEqual(state.settled[0].text, "We agreed to launch Friday.")
        state.retire(); XCTAssertFalse(try state.receive(.init(track: "mic", start: 2, end: 4, text: "Late", final: true), epoch: epoch))
    }
    func testPauseResumePreservesPriorEvidenceAndRejectsOldCaptureOrWrongTrack() throws {
        var state = MeetingLiveState(); let old = try state.begin(tracks: ["system"], offset: 0)
        try state.receive(.init(track: "system", start: 2, end: 5, text: "Before the pause", final: true), epoch: old)
        let firstID = state.settled[0].id; state.retire()
        let resumed = try state.begin(tracks: ["system"], offset: 5, prior: state.settled)
        XCTAssertFalse(try state.receive(.init(track: "system", start: 5, end: 6, text: "Old callback", final: true), epoch: old))
        XCTAssertThrowsError(try state.receive(.init(track: "mic", start: 5, end: 6, text: "Wrong source", final: true), epoch: resumed))
        XCTAssertThrowsError(try state.receive(.init(track: "system", start: 0, end: 1, text: "Wrong clock", final: true), epoch: resumed))
        XCTAssertThrowsError(try state.receive(.init(track: "system", start: .nan, end: 6, text: "Invalid", final: true), epoch: resumed))
        try state.receive(.init(track: "system", start: 5, end: 7, text: "After the pause", final: true), epoch: resumed)
        XCTAssertEqual(state.settled[0].id, firstID); XCTAssertEqual(state.settled[1].start, 5)
    }
    func testCatchUpUsesWholeSettledTurnsInsideAnImmutableBoundedWindow() throws {
        var transcript = MeetingTranscript(locale: "en-US")
        transcript.utterances = [.init(start: 0, end: 30, track: "mic", text: "Old topic"), .init(start: 100, end: 110, track: "system", text: "We agreed to launch Friday."), .init(start: 115, end: 125, track: "mic", text: "I will send the draft Thursday."), .init(start: 126, end: 130, track: "system", text: "Not yet settled at snapshot time")]
        let window = try MeetingCatchUpWindow(meetingID: UUID(), transcript: transcript, through: 125, seconds: 30)
        XCTAssertEqual(window.start, 95); XCTAssertEqual(window.transcript.utterances.count, 2)
        transcript.utterances[1].text = "Later correction"
        XCTAssertEqual(window.transcript.utterances[0].text, "We agreed to launch Friday.")
        XCTAssertEqual(window.digest, MeetingNotebook.digest(window.transcript))
        XCTAssertThrowsError(try MeetingCatchUpWindow(meetingID: UUID(), transcript: transcript, through: 90, seconds: 30))
        XCTAssertThrowsError(try MeetingCatchUpWindow(meetingID: UUID(), transcript: transcript, through: .infinity))
        XCTAssertThrowsError(try MeetingCatchUpWindow(meetingID: UUID(), transcript: transcript, through: 130, seconds: 600))
    }
    func testCatchUpContextLimitKeepsNewestWholeTurnsAndDisclosesTrimming() throws {
        var transcript = MeetingTranscript(locale: "en-US")
        transcript.utterances = (0..<60).map { .init(start: Double($0), end: Double($0+1), track: "mic", text: String(repeating: "Complete sentence. ", count: 10)) }
        let window = try MeetingCatchUpWindow(meetingID: UUID(), transcript: transcript, through: 60)
        XCTAssertTrue(window.truncated); XCTAssertEqual(window.transcript.utterances.last?.end, 60)
        XCTAssertLessThanOrEqual(window.transcript.utterances.count, 48)
        XCTAssertTrue(window.transcript.utterances.allSatisfy { $0.text == transcript.utterances[0].text })
    }
    func testLiveAndRefinedCorrectionsStayInSeparatePrivateFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root); let meeting = Meeting(title: "Synthetic", source: "none", microphone: true); try store.save(meeting)
        var live = MeetingTranscript(locale: "en-US", provider: .nemotron)
        live.utterances = [.init(start: 0, end: 1, track: "mic", text: "Live words")]
        live.utterances[0].correction = "Reviewed live words"
        try store.saveLiveTranscript(live, id: meeting.id, provider: .nemotron)
        var refined = MeetingTranscript(locale: "en-US", provider: .nemotron)
        refined.utterances = [.init(start: 0, end: 1, track: "mic", text: "Refined words")]
        try store.saveTranscript(refined, id: meeting.id, provider: .nemotron)
        XCTAssertEqual(try store.liveTranscript(meeting.id, provider: .nemotron)?.utterances[0].correction, "Reviewed live words")
        XCTAssertEqual(try store.transcript(meeting.id, provider: .nemotron)?.utterances[0].text, "Refined words")
        XCTAssertThrowsError(try store.saveLiveTranscript(live, id: meeting.id, provider: .apple))
        let path = store.folder(meeting.id).appendingPathComponent("live-" + MeetingASRProvider.nemotron.transcriptFile)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int, 0o600)
        try FileManager.default.removeItem(at: path); try FileManager.default.createSymbolicLink(at: path, withDestinationURL: store.folder(meeting.id).appendingPathComponent(MeetingASRProvider.nemotron.transcriptFile))
        XCTAssertThrowsError(try store.saveLiveTranscript(live, id: meeting.id, provider: .nemotron))
        XCTAssertThrowsError(try store.liveTranscript(meeting.id, provider: .nemotron))
    }
}
