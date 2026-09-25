import XCTest
import AVFoundation
import ModuleCore
import VoiceAudio
import NookPluginSDK

final class MeetingTests: XCTestCase {
    func testMeetingRevisionSurvivesSelectionAndHostValidation() throws {
        let meeting = Meeting(title: "View test", source: "none", microphone: true)
        let view = PluginCustomView(entry: "meetings/index.html", revision: meeting.viewRevision)
        XCTAssertNoThrow(try view.validate())
        let reloaded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(reloaded.viewRevision, meeting.viewRevision)
    }
    func testResamplerFlushAndTimelineAssembly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root); let writer = try MeetingAudioWriter(store: store, meeting: Meeting(title: "48 kHz tail", source: "none", microphone: true))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!; buffer.frameLength = 4800
        for channel in 0..<2 { for i in 0..<4800 { buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 0.05) * 0.2) } }
        writer.append(buffer, track: "mic", start: 0.25)
        let saved = try await writer.finish(state: "saved")
        let frames = try saved.chunks.reduce(Int64(0)) { $0 + (try AVAudioFile(forReading: store.audio($1, meeting: saved))).length }
        XCTAssertEqual(frames, 1600)
        let output = root.appendingPathComponent("assembled.caf")
        try await MeetingTranscription.assemble(saved, track: "mic", store: store, to: output)
        XCTAssertEqual(try AVAudioFile(forReading: output).length, 5600)
    }
    func testSpeakerAmbiguityAndCorrectionsPersist() throws {
        var transcript = MeetingTranscript(locale: "en-US")
        transcript.utterances = [.init(start: 0, end: 2, track: "system", text: "First"), .init(start: 2, end: 4, track: "system", text: "Overlap"), .init(start: 4, end: 6, track: "mic", text: "Microphone")]
        try transcript.assign([.init(start: 0, end: 4, speaker: 0), .init(start: 2, end: 4, speaker: 1)], track: "system")
        XCTAssertEqual(transcript.utterances[0].speaker, "system-0"); XCTAssertNil(transcript.utterances[1].speaker); XCTAssertNil(transcript.utterances[2].speaker)
        transcript.utterances[0].speaker = "system-1"; transcript.utterances[0].reviewed = true; transcript.utterances[0].correction = "First corrected"
        try transcript.assign([.init(start: 0, end: 4, speaker: 0)], track: "system")
        XCTAssertEqual(transcript.utterances[0].speaker, "system-1"); XCTAssertEqual(transcript.utterances[0].text, "First")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root); let meeting = Meeting(title: "Review", source: "all", microphone: true); try store.save(meeting); try store.saveTranscript(transcript, id: meeting.id)
        XCTAssertEqual(try store.transcript(meeting.id)?.utterances, transcript.utterances)
        XCTAssertThrowsError(try transcript.assign([.init(start: .nan, end: 5, speaker: 0)], track: "system"))
    }
    func testRecordingRotationPauseAndRecoveryPreserveAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let value = Meeting(title: "Synthetic recording", source: "all", microphone: true)
        let writer = try MeetingAudioWriter(store: store, meeting: value)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
        audio.frameLength = 8000
        for i in 0..<8000 { audio.floatChannelData![0][i] = Float(sin(Double(i) * 0.05) * 0.1) }
        for index in 0..<64 {
            writer.append(audio, track: "mic", start: Double(index) / 2)
            writer.append(audio, track: "system", start: Double(index) / 2 + 0.1)
            _ = writer.snapshot() // Bound this accelerated fixture like real callback pacing.
        }
        writer.mark("A decision")
        let saved = try await writer.finish(state: "paused")
        XCTAssertEqual(saved.state, "paused"); XCTAssertEqual(saved.chunks.count, 6)
        XCTAssertEqual(saved.duration, 32.1, accuracy: 0.02); XCTAssertEqual(saved.marks.count, 1)
        for track in ["mic", "system"] {
            let frames = try saved.chunks.filter { $0.track == track }.reduce(Int64(0)) { sum, chunk in sum + (try AVAudioFile(forReading: store.audio(chunk, meeting: saved))).length }
            XCTAssertEqual(frames, 512000)
        }
        // Reproduce a crash between closing an audio chunk and committing its index.
        var lostIndex = saved; let tail = lostIndex.chunks.removeLast(); lostIndex.state = "recording"; try store.save(lostIndex)
        let recovered = try MeetingAudioWriter.recover(try store.load(saved.id), store: store)
        XCTAssertEqual(recovered.state, "interrupted"); XCTAssertTrue(recovered.chunks.contains { $0.file == tail.file })
        let resumed = try MeetingAudioWriter(store: store, meeting: recovered)
        resumed.append(audio, track: "mic", start: recovered.duration)
        let finished = try await resumed.finish(state: "saved")
        XCTAssertEqual(finished.duration, 32.6, accuracy: 0.02)
        XCTAssertEqual(try store.load(finished.id), finished)
    }
    func testMetadataCannotEscapeRecordingFolder() throws {
        var value = Meeting(title: "Fixture", source: "none", microphone: true)
        value.chunks = [MeetingChunk(file: "../../private.caf", track: "mic", start: 0, duration: 1)]
        XCTAssertThrowsError(try value.validate())
        value.chunks = [MeetingChunk(file: "mic.caf", track: "mic", start: .nan, duration: 1)]
        XCTAssertThrowsError(try value.validate())
        value.chunks = [MeetingChunk(file: "mic.caf", track: "mic", start: 0, duration: 1)]
        value.chunks.append(value.chunks[0]); XCTAssertThrowsError(try value.validate())
    }
    func testFailureAndLateBuffersKeepPartialRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root); let value = Meeting(title: "Partial", source: "none", microphone: true)
        let writer = try MeetingAudioWriter(store: store, meeting: value)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!; buffer.frameLength = 1600
        memset(buffer.floatChannelData![0], 0, 6400)
        writer.append(buffer, track: "mic", start: 0); _ = writer.snapshot()
        let saved = try await writer.finish(state: "interrupted", issue: "Source disconnected")
        writer.append(buffer, track: "mic", start: 0.1); _ = writer.snapshot()
        XCTAssertEqual(try store.load(saved.id), saved); XCTAssertEqual(saved.duration, 0.1, accuracy: 0.001)
    }
}
