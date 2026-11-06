import Foundation
import XCTest
import ModuleCore
@testable import ModuleApp

final class MeetingTranscriptionResolver158Tests: XCTestCase {
    @MainActor func testActualResolverRejectsForeignAndStaleTuplesWithoutWriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-review-resolver-158-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var initial = MeetingTranscript(locale: "en-US"); var manual = MeetingUtterance(start: 2, end: 6, track: "mic", text: "Original")
        manual.correction = "Manual edit"; manual.speaker = "mic-1"; manual.reviewed = true; initial.names["mic-1"] = "Alex"; initial.utterances = [manual]
        try store.saveTranscript(initial, id: meeting.id)
        var current = try XCTUnwrap(store.transcript(meeting.id))
        let origin = MeetingTranscriptionOrigin(meetingID: meeting.id, provider: .apple, track: "mic", baseDigest: MeetingNotebook.digest(current))
        try current.beginContinuation(track: "mic", origin: origin)
        let new = MeetingUtterance(start: 1, end: 7, track: "mic", text: "New full alternative")
        try current.receiveContinuation([new], origin: origin); current = try store.saveTranscript(current, id: meeting.id)
        let revision = try XCTUnwrap(current.transcriptionRevision), digest = MeetingNotebook.digest(current)
        let file = store.folder(meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        let original = try Data(contentsOf: file)
        for tuple in [(UUID().uuidString, "apple", revision, digest), (meeting.id.uuidString, "nemotron", revision, digest),
                      (meeting.id.uuidString, "apple", UUID().uuidString, digest),
                      (meeting.id.uuidString, "apple", revision, String(repeating: "0", count: 64))] {
            XCTAssertThrowsError(try MeetingTranscriptionResolver.resolve(store: store, meetingID: meeting.id, provider: .apple, visible: current,
                submittedMeeting: tuple.0, submittedProvider: tuple.1, revision: tuple.2, candidate: new.id.uuidString, digest: tuple.3, choice: .keepBoth))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
        let resolved = try MeetingTranscriptionResolver.resolve(store: store, meetingID: meeting.id, provider: .apple, visible: current,
            submittedMeeting: meeting.id.uuidString, submittedProvider: "apple", revision: revision, candidate: new.id.uuidString, digest: digest, choice: .keepBoth)
        XCTAssertEqual(resolved.utterances.first { $0.id == manual.id }, manual)
        XCTAssertNotNil(resolved.utterances.first { $0.id == new.id }); XCTAssertEqual(resolved.pendingTranscriptionCount, 0)
        let after = try Data(contentsOf: file)
        XCTAssertThrowsError(try MeetingTranscriptionResolver.resolve(store: store, meetingID: meeting.id, provider: .apple, visible: current,
            submittedMeeting: meeting.id.uuidString, submittedProvider: "apple", revision: revision, candidate: new.id.uuidString, digest: digest, choice: .keepBoth))
        XCTAssertEqual(try Data(contentsOf: file), after)
    }
}
