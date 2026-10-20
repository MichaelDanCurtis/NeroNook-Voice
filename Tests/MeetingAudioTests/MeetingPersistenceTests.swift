import XCTest
import AVFoundation
import ModuleCore
@testable import VoiceAudio

final class MeetingPersistenceTests: XCTestCase {
    private func store() throws -> MeetingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoicePersistence-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try MeetingStore(root: root)
    }
    private func audio() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let value = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        value.frameLength = 1600
        for n in 0..<1600 { value.floatChannelData![0][n] = Float(sin(Double(n) * 0.05) * 0.1) }
        return value
    }
    func testRecordingBeforeObserversAreReadySurvivesPauseResumeAndStop() async throws {
        let store = try store(), initial = Meeting(title: "Late observer", source: "none", microphone: true)
        let first = try MeetingAudioWriter(store: store, meeting: initial), live = MeetingLiveAudioFeed(), speakers = MeetingLiveAudioFeed()
        let buffer = audio()
        first.append(buffer, track: "mic", start: 0) // models still preparing
        first.attachLiveFeed(live)
        first.attachSpeakerFeed(speakers)
        first.append(buffer, track: "mic", start: 0.1)
        let paused = try await first.finish(state: "paused")
        XCTAssertEqual(paused.state, "paused")
        XCTAssertEqual(paused.duration, 0.2, accuracy: 0.001)
        var resumed = paused; resumed.state = "recording"
        let second = try MeetingAudioWriter(store: store, meeting: resumed, liveFeed: live, speakerFeed: speakers)
        second.append(buffer, track: "mic", start: paused.duration)
        let stopped = try await second.finish(state: "saved")
        XCTAssertEqual(try store.load(stopped.id), stopped)
        XCTAssertEqual(stopped.duration, 0.3, accuracy: 0.001)
        let frames = try stopped.chunks.reduce(Int64(0)) { $0 + (try AVAudioFile(forReading: store.audio($1, meeting: stopped))).length }
        XCTAssertEqual(frames, 4800) // includes audio before model readiness
        live.finish(); speakers.finish()
        for feed in [live, speakers] {
            var stamps: [Double] = []
            for try await event in feed.stream {
                feed.consumed(event)
                if case .audio(let packet) = event { stamps.append(packet.start) }
            }
            XCTAssertEqual(stamps, [0.1, 0.2]) // no warm-up backlog or clock compression
        }
    }
    func testSnapshotNeverWaitsBehindBlockedStorageQueue() async throws {
        let store = try store(), storage = DispatchQueue(label: "voice-fixture-slow-storage"), unblock = DispatchSemaphore(value: 0)
        storage.async { _ = unblock.wait(timeout: .now() + 3) }
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Storage stall", source: "none", microphone: true), storageQueue: storage)
        writer.append(audio(), track: "mic", start: 0)
        let begin = ProcessInfo.processInfo.systemUptime
        for _ in 0..<1000 { XCTAssertEqual(writer.snapshot().duration, 0) }
        let elapsed = ProcessInfo.processInfo.systemUptime - begin
        unblock.signal()
        XCTAssertLessThan(elapsed, 0.2) // old queue.sync waited for the 3-second fixture gate
        let saved = try await writer.finish(state: "saved")
        XCTAssertEqual(writer.snapshot().duration, 0.1, accuracy: 0.001)
        XCTAssertEqual(saved.duration, 0.1, accuracy: 0.001)
    }
    func testCheckpointsCoalesceBehindSlowIOAndFlushNewestDurableTranscript() async throws {
        let store = try store(), meeting = Meeting(title: "Coalescing", source: "none", microphone: true)
        try store.save(meeting)
        let probe = CheckpointProbe(), started = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        let checkpoints = MeetingTranscriptCheckpoints(persist: { transcript, id, provider in
            let count = probe.record(transcript.utterances[0].text, main: Thread.isMainThread)
            if count == 1 { started.signal(); _ = unblock.wait(timeout: .now() + 3) }
            try store.saveLiveTranscript(transcript, id: id, provider: provider)
        })
        func snapshot(_ text: String) -> MeetingTranscript {
            var value = MeetingTranscript(locale: "en-US")
            value.utterances = [.init(start: 0, end: 1, track: "mic", text: text)]
            return value
        }
        checkpoints.save(snapshot("First"), id: meeting.id, provider: .apple)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        for index in 1...100 { checkpoints.save(snapshot("Snapshot \(index)"), id: meeting.id, provider: .apple) }
        unblock.signal()
        try await checkpoints.flush()
        XCTAssertEqual(probe.texts, ["First", "Snapshot 100"])
        XCTAssertFalse(probe.usedMain)
        XCTAssertEqual(try store.liveTranscript(meeting.id, provider: .apple)?.utterances[0].text, "Snapshot 100")
    }
    func testCheckpointFailureIsReportedAndNextExplicitSaveCanRecover() async throws {
        let store = try store(), meeting = Meeting(title: "Checkpoint retry", source: "none", microphone: true)
        try store.save(meeting)
        let probe = CheckpointProbe()
        let checkpoints = MeetingTranscriptCheckpoints(persist: { transcript, id, provider in
            if probe.record("save", main: Thread.isMainThread) == 1 { throw VoiceProblem.message("Authored storage failure") }
            try store.saveLiveTranscript(transcript, id: id, provider: provider)
        }, failure: { _, message in _ = probe.record(message, main: Thread.isMainThread) })
        var transcript = MeetingTranscript(locale: "en-US")
        transcript.utterances = [.init(start: 0, end: 1, track: "mic", text: "Retained final words")]
        checkpoints.save(transcript, id: meeting.id, provider: .apple)
        do { try await checkpoints.flush(); XCTFail("Storage failure was hidden") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Authored storage failure")) }
        checkpoints.save(transcript, id: meeting.id, provider: .apple)
        try await checkpoints.flush()
        XCTAssertEqual(try store.liveTranscript(meeting.id, provider: .apple)?.utterances[0].text, "Retained final words")
    }
}

private final class CheckpointProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var main = false
    func record(_ value: String, main: Bool) -> Int { lock.lock(); defer { lock.unlock() }; values.append(value); self.main = self.main || main; return values.count }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return values }
    var usedMain: Bool { lock.lock(); defer { lock.unlock() }; return main }
}
