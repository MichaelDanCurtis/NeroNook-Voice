import XCTest
import AVFoundation
import ModuleCore
@testable import VoiceAudio

final class MeetingTimelineTests: XCTestCase {
    private func buffer(_ frames: Int = 1024, rate: Double = 16000, value: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        result.frameLength = AVAudioFrameCount(frames)
        for index in 0..<frames { result.floatChannelData![0][index] = value }
        return result
    }
    private func packets(_ feed: MeetingLiveAudioFeed) async throws -> [MeetingAudioPacket] {
        feed.finish(); var result: [MeetingAudioPacket] = []
        for try await event in feed.stream { feed.consumed(event); if case .audio(let packet) = event { result.append(packet) } }
        return result
    }
    private func assembled(_ meeting: Meeting, store: MeetingStore, root: URL) async throws -> [Float] {
        let output = root.appendingPathComponent(UUID().uuidString + ".caf")
        try await MeetingTranscription.assemble(meeting, track: "mic", store: store, to: output)
        let file = try AVAudioFile(forReading: output)
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        let expectedLength = file.length
        var result: [Float] = []
        while file.framePosition < expectedLength {
            try file.read(into: pcm, frameCount: AVAudioFrameCount(min(4096, expectedLength - file.framePosition)))
            XCTAssertGreaterThan(pcm.frameLength, 0, "Reader must advance before EOF")
            if pcm.frameLength == 0 { break }
            result.append(contentsOf: UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
        }
        XCTAssertEqual(Int64(result.count), expectedLength, "Read every actual assembled frame")
        print("Authored assembly frames: file=\(expectedLength), read=\(result.count), chunks=\(meeting.chunks.map { $0.duration })")
        return result
    }
    func testCaptureGapSurvivesDurableAssemblyAndBothLiveObservers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), live = MeetingLiveAudioFeed(), speakers = MeetingLiveAudioFeed()
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Authored clock gap", source: "none", microphone: true), liveFeed: live, speakerFeed: speakers)
        writer.append(buffer(value: 0.25), track: "mic", start: 0)
        writer.append(buffer(value: 0.5), track: "mic", start: 1)
        let saved = try await writer.finish(state: "saved"), pcm = try await assembled(saved, store: store, root: root)
        XCTAssertEqual(saved.chunks.count, 2); XCTAssertEqual(saved.duration, 1.064, accuracy: 0.000001)
        XCTAssertEqual(pcm.count, 17024)
        if pcm.count == 17024 { XCTAssertEqual(pcm[0], 0.25); XCTAssertEqual(pcm[15000], 0); XCTAssertEqual(pcm[16000], 0.5) }
        let a = try await packets(live), b = try await packets(speakers)
        XCTAssertEqual(a.map(\.start), [0,1]); XCTAssertEqual(a.map(\.start), b.map(\.start)); XCTAssertEqual(a.map(\.pcm), b.map(\.pcm))
    }
    func testSmallCaptureJitterUsesDurableSampleClock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), live = MeetingLiveAudioFeed()
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Authored jitter", source: "none", microphone: true), liveFeed: live)
        writer.append(buffer(), track: "mic", start: 0); writer.append(buffer(), track: "mic", start: 0.0645)
        let saved = try await writer.finish(state: "saved"), values = try await packets(live)
        XCTAssertEqual(saved.chunks.count, 1); XCTAssertEqual(values.map(\.start), [0,0.064])
        XCTAssertEqual(saved.duration, 0.128, accuracy: 0.000001)
    }
    func testBackwardClockRefusesInsteadOfSilentlyDiscardingSpeech() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), live = MeetingLiveAudioFeed()
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Authored overlap", source: "none", microphone: true), liveFeed: live)
        writer.append(buffer(), track: "mic", start: 0); await writer.synchronize()
        writer.append(buffer(value: 0.5), track: "mic", start: 0.032)
        let saved = try await writer.finish(state: "saved"), values = try await packets(live)
        XCTAssertEqual(saved.state, "interrupted"); XCTAssertTrue(saved.issue.lowercased().contains("clock"))
        XCTAssertEqual(values.count, 1); XCTAssertEqual(saved.duration, 0.064, accuracy: 0.000001)
        let frames = try saved.chunks.reduce(Int64(0)) { $0 + (try AVAudioFile(forReading: store.audio($1, meeting: saved))).length }
        XCTAssertEqual(frames, 1024)
    }
    func testContinuousResamplingAndTailStayOnOneOutputClock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), live = MeetingLiveAudioFeed()
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Authored resampler", source: "none", microphone: true), liveFeed: live)
        writer.append(buffer(4800, rate: 48000), track: "mic", start: 0.25)
        writer.append(buffer(4800, rate: 48000), track: "mic", start: 0.35)
        let saved = try await writer.finish(state: "saved"), values = try await packets(live)
        XCTAssertEqual(saved.chunks.count, 1); XCTAssertEqual(saved.duration, 0.45, accuracy: 0.0001)
        XCTAssertEqual(values.reduce(0) { $0 + $1.pcm.count/4 }, 3200)
        for index in values.indices.dropFirst() { XCTAssertEqual(values[index].start, values[index-1].end, accuracy: 0.000001) }
    }
    func testResamplerGapDrainsOldSegmentBeforeNewTimelineOrigin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), live = MeetingLiveAudioFeed()
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Authored resampler gap", source: "none", microphone: true), liveFeed: live)
        writer.append(buffer(4800, rate: 48000), track: "mic", start: 0.25)
        writer.append(buffer(4800, rate: 48000, value: 0.5), track: "mic", start: 0.55)
        let saved = try await writer.finish(state: "saved"), values = try await packets(live)
        XCTAssertEqual(saved.chunks.count, 2); XCTAssertEqual(saved.duration, 0.65, accuracy: 0.0001)
        XCTAssertEqual(values.reduce(0) { $0 + $1.pcm.count/4 }, 3200)
        XCTAssertEqual(saved.chunks.map(\.start), [0.25,0.55])
        let pcm = try await assembled(saved, store: store, root: root)
        XCTAssertEqual(pcm.count, 10400)
        if pcm.count == 10400 { XCTAssertEqual(pcm[7000], 0); XCTAssertGreaterThan(pcm[9000], 0.4) }
    }
    func testTrackClocksAreIndependentAndResumeRetainsEachEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Authored tracks", source: "none", microphone: true))
        writer.append(buffer(), track: "mic", start: 0); writer.append(buffer(), track: "system", start: 1)
        writer.append(buffer(), track: "mic", start: 0.064)
        let paused = try await writer.finish(state: "paused"), live = MeetingLiveAudioFeed()
        let resumed = try MeetingAudioWriter(store: store, meeting: paused, liveFeed: live)
        resumed.append(buffer(), track: "mic", start: 0.1285)
        let saved = try await resumed.finish(state: "saved"), values = try await packets(live)
        XCTAssertEqual(values.map(\.start), [0.128]); XCTAssertEqual(saved.duration, 1.064, accuracy: 0.000001)
        XCTAssertEqual(saved.chunks.filter { $0.track == "mic" }.map(\.start), [0,0.128])
    }
    func testCompleteClockReplayDoesNotRefreshDurableProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), live = MeetingLiveAudioFeed()
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Authored replay", source: "none", microphone: true), liveFeed: live)
        writer.append(buffer(), track: "mic", start: 0); await writer.synchronize()
        let before = writer.snapshot()
        writer.append(buffer(value: 0.5), track: "mic", start: 0)
        let saved = try await writer.finish(state: "saved"), values = try await packets(live)
        XCTAssertEqual(saved.state, "interrupted"); XCTAssertEqual(values.count, 1)
        XCTAssertEqual(writer.snapshot().last["mic"], before.last["mic"])
        XCTAssertEqual(saved.duration, 0.064, accuracy: 0.000001)
    }
    func testRotationKeepsTheTrackClockAndLaterGap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), live = MeetingLiveAudioFeed()
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Authored rotation", source: "none", microphone: true), liveFeed: live)
        for index in 0..<31 { writer.append(buffer(8000), track: "mic", start: Double(index)/2); await writer.synchronize() }
        writer.append(buffer(), track: "mic", start: 16)
        let saved = try await writer.finish(state: "saved"), values = try await packets(live)
        XCTAssertEqual(saved.state, "saved"); XCTAssertEqual(saved.chunks.map(\.start), [0,15,16])
        XCTAssertEqual(values.last?.start, 16); XCTAssertEqual(saved.duration, 16.064, accuracy: 0.000001)
        let pcm = try await assembled(saved, store: store, root: root)
        XCTAssertEqual(pcm.count, 257024)
        if pcm.count == 257024 { XCTAssertEqual(pcm[250000], 0); XCTAssertEqual(pcm[256000], 0.25) }
    }
    func testBackwardResamplerClockRetainsTheOldConverterTail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), live = MeetingLiveAudioFeed()
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Authored backward converter", source: "none", microphone: true), liveFeed: live)
        writer.append(buffer(4800, rate: 48000), track: "mic", start: 0.25)
        writer.append(buffer(4800, rate: 48000, value: 0.5), track: "mic", start: 0.30)
        let saved = try await writer.finish(state: "saved"), values = try await packets(live)
        XCTAssertEqual(saved.state, "interrupted"); XCTAssertTrue(saved.issue.lowercased().contains("clock"))
        XCTAssertEqual(values.reduce(0) { $0 + $1.pcm.count/4 }, 1600)
        XCTAssertEqual(saved.duration, 0.35, accuracy: 0.0001)
    }
    func testFormatChangeIsRefusedEvenWhenNewFormatMatchesOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), live = MeetingLiveAudioFeed()
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Authored format change", source: "none", microphone: true), liveFeed: live)
        writer.append(buffer(4800, rate: 48000), track: "mic", start: 0)
        writer.append(buffer(1600), track: "mic", start: 0.1)
        let saved = try await writer.finish(state: "saved")
        XCTAssertEqual(saved.state, "interrupted"); XCTAssertTrue(saved.issue.contains("format changed"))
        let values = try await packets(live)
        XCTAssertEqual(values.reduce(0) { $0 + $1.pcm.count/4 }, 1600)
        XCTAssertEqual(saved.duration, 0.1, accuracy: 0.0001)
    }

}
