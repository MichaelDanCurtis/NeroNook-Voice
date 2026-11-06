import Foundation
import XCTest
import ModuleCore
import NookPluginSDK
@testable import ModuleApp

// Authored data only; no MeetingModel initialization, microphone, workers,
// model, setup, grants or normal user-profile state.
final class LiveRefinementFixture159 {
    let root: URL
    let store: MeetingStore
    let meeting: Meeting
    let provider: MeetingASRProvider
    let live: MeetingTranscript
    let edited: MeetingUtterance
    let speakerOnly: MeetingUtterance
    let oldAutomatic: MeetingUtterance
    let system: MeetingUtterance
    let overlap: MeetingUtterance
    let disjoint: MeetingUtterance
    let originalLiveBytes: Data
    let liveCitation: MeetingChatSource

    init(provider: MeetingASRProvider) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("authored-live-refinement-159-" + UUID().uuidString, isDirectory: true)
        var initialized = false
        defer { if !initialized { try? FileManager.default.removeItem(at: root) } }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored live refinement", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var edited = MeetingUtterance(start: 4, end: 8, track: "mic", text: "Original edited speech")
        edited.correction = "We agreed the draft"; edited.speaker = "mic-3"; edited.reviewed = true
        edited.words = [.init(text: "Original", start: 4, end: 5)]
        var speakerOnly = MeetingUtterance(start: 10, end: 11, track: "mic", text: "Assigned speaker only")
        speakerOnly.speaker = "mic-2"; speakerOnly.reviewed = true
        let oldAutomatic = MeetingUtterance(start: 15, end: 16, track: "mic", text: "Old unreviewed draft")
        var system = MeetingUtterance(start: 18, end: 19, track: "system", text: "Other track reviewed")
        system.reviewed = true; system.speaker = "system-1"
        var live = MeetingTranscript(locale: "en-US", provider: provider, modelRevision: "live-model", runtimeRevision: "live-runtime")
        live.utterances = [edited, speakerOnly, oldAutomatic, system]; live.names = ["mic-3": "Mara", "mic-2": "Morgan", "system-1": "Taylor"]
        live.completedTracks = ["mic", "system"]; live.labelledTracks = ["mic", "system"]; live.speakerModelRevision = "live-speaker-v1"
        try store.saveLiveTranscript(live, id: meeting.id, provider: provider)
        let bytes = try Data(contentsOf: store.folder(meeting.id).appendingPathComponent("live-" + provider.transcriptFile))
        let evidence = try MeetingChatEvidence.current(meeting: meeting, transcript: live, provider: provider, live: true, question: "What was agreed?", context: [])
        let citation = try XCTUnwrap(evidence.sources.first { $0.utteranceID == edited.id })
        let overlap = MeetingUtterance(start: 2, end: 9, track: "mic", text: "Starting tail and new overlap and ending tail 🌿")
        let disjoint = MeetingUtterance(start: 20, end: 21, track: "mic", text: "Unrelated new speech")
        self.root=root; self.store=store; self.meeting=meeting; self.provider=provider; self.live=live
        self.edited=edited; self.speakerOnly=speakerOnly; self.oldAutomatic=oldAutomatic; self.system=system
        self.overlap=overlap; self.disjoint=disjoint; originalLiveBytes=bytes; liveCitation=citation
        initialized = true
    }
    func assertLiveUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: store.folder(meeting.id).appendingPathComponent("live-" + provider.transcriptFile)), originalLiveBytes, file: file, line: line)
        let actual = try XCTUnwrap(store.liveTranscript(meeting.id, provider: provider), file: file, line: line)
        XCTAssertEqual(actual.utterances, live.utterances, file: file, line: line)
        XCTAssertEqual(actual.names, live.names, file: file, line: line)
        XCTAssertEqual(try liveCitation.resolve(meetingID: meeting.id, transcript: actual).id, edited.id, file: file, line: line)
    }
    func cleanup() throws { try FileManager.default.removeItem(at: root) }
}
