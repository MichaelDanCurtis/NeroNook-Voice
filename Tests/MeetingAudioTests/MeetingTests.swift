import XCTest
import AVFoundation
import ModuleCore
@testable import VoiceAudio
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
    func testMeetingProvidersKeepIndependentCorrectionsAndLegacyAppleTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(title: "Compare ASR", source: "none", microphone: true)
        try store.save(meeting)
        var apple = MeetingTranscript(locale: "en-US")
        apple.utterances = [.init(start: 0, end: 1, track: "mic", text: "Apple heard this")]
        apple.utterances[0].correction = "Owner's correction"
        apple.utterances[0].reviewed = true
        try store.saveTranscript(apple, id: meeting.id)
        var parakeet = MeetingTranscript(locale: "auto", provider: .parakeet, modelRevision: LocalASREngine(.parakeet).revision, runtimeRevision: LocalASREngine(.parakeet).runtimeRevision)
        parakeet.utterances = [.init(start: 0, end: 1, track: "mic", text: "Parakeet heard that")]
        try store.saveTranscript(parakeet, id: meeting.id, provider: .parakeet)
        XCTAssertEqual(try store.transcript(meeting.id)?.utterances[0].correction, "Owner's correction")
        XCTAssertEqual(try store.transcript(meeting.id, provider: .parakeet)?.utterances[0].text, "Parakeet heard that")
        XCTAssertThrowsError(try store.saveTranscript(parakeet, id: meeting.id, provider: .apple))
        // Existing 0.6.x files did not carry provider metadata.
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(apple)) as! [String: Any]
        var legacy = old; legacy.removeValue(forKey: "providerID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        try legacyData.write(to: store.folder(meeting.id).appendingPathComponent("transcript.json"), options: .atomic)
        XCTAssertEqual(try store.transcript(meeting.id)?.utterances[0].correction, "Owner's correction")
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
            await writer.synchronize() // Bound this accelerated fixture like real callback pacing.
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
    func testNemotronTranscriptAndEightSpeakerBounds() throws {
        var result = MeetingTranscript(locale: "auto", provider: .nemotron,
                                       modelRevision: LocalASREngine(.nemotron).revision)
        result.utterances = [.init(start: 0, end: 2, track: "mic", text: "Speaker eight")]
        try result.assign([.init(start: 0, end: 2, speaker: 7)], track: "mic")
        XCTAssertEqual(result.utterances[0].speaker, "mic-7")
        XCTAssertThrowsError(try result.assign([.init(start: 0, end: 2, speaker: 8)], track: "mic"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), meeting = Meeting(title: "Providers", source: "none", microphone: true)
        try store.save(meeting)
        try store.saveTranscript(result, id: meeting.id, provider: .nemotron)
        XCTAssertEqual(try store.transcript(meeting.id, provider: .nemotron)?.utterances[0].speaker, "mic-7")
        XCTAssertNil(try store.transcript(meeting.id, provider: .apple))
        XCTAssertNil(try store.transcript(meeting.id, provider: .parakeet))
    }
    func testLocalCaptureFlushAndOverflowAreNotSilent() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let bridge = try AudioBridge(input: format, output: format, continuation: nil, captureLocally: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        buffer.frameLength = 8192
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * 4)
        bridge.append(buffer)
        bridge.finish()
        XCTAssertEqual(bridge.capturedAudio()?.count, 8192 * 4)
        XCTAssertNil(bridge.error())
        let overflow = try AudioBridge(input: format, output: format, continuation: nil, captureLocally: true)
        for _ in 0..<130 { overflow.append(buffer) }
        XCTAssertNotNil(overflow.error())
        XCTAssertLessThanOrEqual(overflow.capturedAudio()!.count, 4_096_000)
    }
    @MainActor func testOnlyOneLocalModelProcessCanRun() async throws {
        let first = Process(), second = Process()
        for process in [first, second] {
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["2"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        defer { LocalModelProcess.stop(first); LocalModelProcess.stop(second) }
        try LocalModelProcess.launch(first)
        XCTAssertThrowsError(try LocalModelProcess.launch(second))
        XCTAssertFalse(second.isRunning)
        LocalModelProcess.stop(first)
        for _ in 0..<30 where first.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(first.isRunning)
        try LocalModelProcess.launch(second)
        XCTAssertTrue(second.isRunning)
    }
    func testWordTimingSplitsSpeakerChangesWithoutInventingAlignment() throws {
        var result = MeetingTranscript(locale: "auto", provider: .nemotron)
        var line = MeetingUtterance(start: 0, end: 4, track: "mic", text: "Hello there how are you")
        line.words = [.init(text: "Hello", start: 0, end: 0.5), .init(text: " there", start: 0.5, end: 1),
                      .init(text: " how", start: 2, end: 2.5), .init(text: " are", start: 2.5, end: 3), .init(text: " you", start: 3, end: 4)]
        result.utterances = [line]
        try result.assign([.init(start: 0, end: 1, speaker: 0), .init(start: 2, end: 4, speaker: 1)], track: "mic")
        XCTAssertEqual(result.utterances.map(\.text), ["Hello there", "how are you"])
        XCTAssertEqual(result.utterances.map(\.speaker), ["mic-0", "mic-1"])
        XCTAssertEqual(result.utterances.flatMap { $0.words ?? [] }.map(\.text).joined(), line.text)
        line.reviewed = true; line.correction = "Keep my correction"; result.utterances = [line]
        try result.assign([.init(start: 0, end: 1, speaker: 0), .init(start: 2, end: 4, speaker: 1)], track: "mic")
        XCTAssertEqual(result.utterances.count, 1)
        XCTAssertEqual(result.utterances[0].correction, "Keep my correction")
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
        writer.append(buffer, track: "mic", start: 0); await writer.synchronize()
        let saved = try await writer.finish(state: "interrupted", issue: "Source disconnected")
        writer.append(buffer, track: "mic", start: 0.1); await writer.synchronize()
        XCTAssertEqual(try store.load(saved.id), saved); XCTAssertEqual(saved.duration, 0.1, accuracy: 0.001)
    }
}
