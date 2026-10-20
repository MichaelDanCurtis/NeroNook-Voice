import Foundation
import XCTest
@testable import ModuleCore

final class MeetingOrganizationTests: XCTestCase {
    func store() throws -> MeetingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return try MeetingStore(root: root)
    }
    func testFolderMovesRemovalAndUndoNeverMoveOrRewriteMeetingArtifacts() throws {
        let store = try store(); var meeting = Meeting(title: "Review", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var transcript = MeetingTranscript(locale: "en-US"); transcript.utterances = [.init(start: 0, end: 1, track: "mic", text: "Launch is Friday.")]; try store.saveTranscript(transcript, id: meeting.id)
        var notebook = MeetingNotebook(meetingID: meeting.id); notebook.thoughts = "Private note"; try store.saveNotebook(notebook)
        let q = try MeetingChatEvidence.current(meeting: meeting, transcript: transcript, provider: .apple, live: false, question: "When?", context: [])
        var chat = MeetingChat(meetingID: meeting.id); chat.turns = [.init(evidence: q, assistant: "Test")]; try store.saveChat(chat)
        let files = try FileManager.default.contentsOfDirectory(at: store.folder(meeting.id), includingPropertiesForKeys: nil)
        let before = try files.map { try Data(contentsOf: $0) }
        var index = try store.organization(); let folder = try index.create("Work"); try index.move(meeting.id, to: folder); try store.saveOrganization(index)
        XCTAssertTrue(index.contains(meeting.id, scope: folder.uuidString)); XCTAssertFalse(index.contains(meeting.id, scope: "unfiled"))
        try index.rename(folder, name: "Project reviews"); try store.saveOrganization(index)
        try index.remove(folder); try store.saveOrganization(index)
        XCTAssertTrue(index.contains(meeting.id, scope: "unfiled")); XCTAssertTrue(try store.organization().folders.isEmpty)
        let previous = try store.organization(previous: true); try store.saveOrganization(previous)
        XCTAssertEqual(try MeetingStore(root: store.root).organization().membership[meeting.id.uuidString], folder)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before)
        XCTAssertEqual(try store.chat(meeting.id).turns[0].evidence.sources[0].resolve(meetingID: meeting.id, transcript: transcript).id, transcript.utterances[0].id)
    }
    func testFolderLimitsDuplicateNamesUnknownMembershipAndTraversalStayInvalid() throws {
        var value = MeetingOrganization(); _ = try value.create("Work")
        XCTAssertThrowsError(try value.create(" work ")); XCTAssertEqual(value.folders.count, 1)
        for name in ["", "   ", String(repeating: "x", count: 81), "Bad\nName"] { XCTAssertThrowsError(try value.create(name)) }
        XCTAssertThrowsError(try value.move(UUID(), to: UUID())); XCTAssertTrue(value.membership.isEmpty)
        value.membership["../../elsewhere"] = value.folders[0].id; XCTAssertThrowsError(try value.validate()); value.membership = [:]
        for n in 1..<40 { _ = try value.create("Folder \(n)") }; XCTAssertThrowsError(try value.create("Too many"))
        XCTAssertTrue(value.contains(UUID(), scope: "all")); XCTAssertFalse(value.contains(UUID(), scope: "nonsense"))
    }
    func testCorruptOrLinkedOrganizationCannotOverwriteUnrelatedFiles() throws {
        let store = try store(), url = store.root.appendingPathComponent("folders-v1.json"), outside = store.root.appendingPathComponent("private.txt")
        try Data("Keep".utf8).write(to: outside); try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        XCTAssertThrowsError(try store.organization()); XCTAssertThrowsError(try store.saveOrganization(.init())); XCTAssertEqual(try Data(contentsOf: outside), Data("Keep".utf8))
        try FileManager.default.removeItem(at: url); let damaged = Data("broken".utf8); try damaged.write(to: url)
        XCTAssertThrowsError(try store.saveOrganization(.init())); XCTAssertEqual(try Data(contentsOf: url), damaged)
    }
    func testLibraryFollowupContextStaysInsideChosenFolder() throws {
        let store = try store(); var chat = MeetingChat(meetingID: nil), ids: [UUID] = []
        for title in ["Work", "Personal"] {
            var m = Meeting(title: title, source: "none", microphone: true); m.state = "saved"; try store.save(m); ids.append(m.id)
            var t = MeetingTranscript(locale: "en-US"); t.utterances = [.init(start: 0, end: 1, track: "mic", text: title + " topic")]
            let q = try MeetingChatEvidence.current(meeting: m, transcript: t, provider: .apple, live: false, question: title + " question", context: [])
            var turn = MeetingChatTurn(evidence: q, assistant: "Test"); turn.phase = "completed"; turn.answer = .init(snapshot: q.question.snapshot, disposition: "answered", statements: [.init(text: title + " answer", citations: ["s1"])]); chat.turns.append(turn)
        }
        XCTAssertEqual(chat.context().count, 2); XCTAssertEqual(chat.context(eligibleMeetings: [ids[0]]).map(\.question), ["Work question"])
        XCTAssertTrue(chat.context(eligibleMeetings: []).isEmpty)
    }
}
