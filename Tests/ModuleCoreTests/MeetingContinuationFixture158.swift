import Foundation
import XCTest
import NookPluginSDK
@testable import ModuleCore

// Authored files and speech only. This creates no MeetingModel, recorder,
// microphone, model, worker, account or default-profile state.
final class MeetingContinuationFixture158 {
    let root: URL
    let store: MeetingStore
    let meeting: Meeting
    let provider: MeetingASRProvider
    let protected: MeetingUtterance
    let otherTrack: MeetingUtterance
    let wideAlternative: MeetingUtterance
    let disjointAlternative: MeetingUtterance
    let initial: MeetingTranscript
    let originalV1: Data
    let citation: MeetingChatSource

    init(provider: MeetingASRProvider) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("authored-meeting-continuation-" + UUID().uuidString, isDirectory: true)
        var initialized = false
        defer { if !initialized { try? FileManager.default.removeItem(at: root) } }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored continuation", source: "none", microphone: true)
        meeting.state = "saved"; try store.save(meeting)
        var protected = MeetingUtterance(start: 4, end: 8, track: "mic", text: "Original edited phrase")
        protected.correction = "We agreed the draft"; protected.speaker = "mic-3"; protected.reviewed = true
        protected.words = [.init(text: "Original", start: 4, end: 5)]
        let otherTrack = MeetingUtterance(start: 10, end: 12, track: "system", text: "Untouched other track")
        var wideAlternative = MeetingUtterance(start: 2, end: 9, track: "mic", text: "Beginning tail, competing phrase, ending tail 🌿")
        wideAlternative.words = [.init(text: "Beginning", start: 2, end: 3), .init(text: "ending", start: 8, end: 9)]
        let disjointAlternative = MeetingUtterance(start: 13, end: 15, track: "mic", text: "Entirely new speech")
        var transcript = MeetingTranscript(locale: "en-US", provider: provider)
        transcript.utterances = [protected, otherTrack]; transcript.names["mic-3"] = "Mara"
        try store.saveTranscript(transcript, id: meeting.id, provider: provider)
        let original = try Data(contentsOf: store.folder(meeting.id).appendingPathComponent(provider.transcriptFile))
        let evidence = try MeetingChatEvidence.current(meeting: meeting, transcript: transcript, provider: provider, live: false, question: "What was agreed?", context: [])
        let citation = try XCTUnwrap(evidence.sources.first { $0.utteranceID == protected.id })
        self.root = root; self.store = store; self.meeting = meeting; self.provider = provider
        self.protected = protected; self.otherTrack = otherTrack; self.wideAlternative = wideAlternative
        self.disjointAlternative = disjointAlternative; initial = transcript; originalV1 = original; self.citation = citation
        initialized = true
    }

    // Mechanical copy of the maintained pre-158 saveTranscript operation. It
    // deliberately writes the legacy v1 file without invoking the new guard.
    func originalBlindSave(_ value: MeetingTranscript) throws {
        _ = try store.load(meeting.id); try value.validate()
        guard value.providerID == provider.rawValue || (provider == .apple && value.providerID == nil) else { throw VoiceProblem.message("Transcript provider does not match its file") }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 32_000_000 else { throw VoiceProblem.message("Transcript exceeds its limit") }
        try data.write(to: store.folder(meeting.id).appendingPathComponent(provider.transcriptFile), options: .atomic)
    }

    func assertOriginalV1Unchanged(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: store.folder(meeting.id).appendingPathComponent(provider.transcriptFile)), originalV1, file: file, line: line)
    }
    func assertCitation(_ transcript: MeetingTranscript, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try citation.resolve(meetingID: meeting.id, transcript: transcript).id, protected.id, file: file, line: line)
    }
    func cleanup() throws { try FileManager.default.removeItem(at: root) }
}
