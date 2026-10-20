import XCTest
import AVFoundation
import Speech
@testable import VoiceAudio
import ModuleCore

final class MeetingLiveAudioTests: XCTestCase {
    func testTimedWordsKeepPunctuationAndRejectInventedClocks() {
        var aligned = AttributedString("hello")
        aligned.audioTimeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 16000), duration: CMTime(seconds: 0.5, preferredTimescale: 16000))
        let text = AttributedString(" “") + aligned + AttributedString("!”")
        let words = MeetingTimedText.words(text, start: 1, end: 2)
        XCTAssertEqual(words?.first?.text, " “hello!”"); XCTAssertEqual(words?.first?.start, 1); XCTAssertEqual(words?.first?.end, 1.5)
        XCTAssertNil(MeetingTimedText.words(text, start: 1.2, end: 2))
        XCTAssertNil(MeetingTimedText.words(AttributedString("No timing"), start: 0, end: 2))
    }
    func testTimestampedResamplingNeverSendsOverlappingAnalyzerInput() async throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let pair = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let bridge = try AudioBridge(input: input, output: output, continuation: pair.continuation)
        let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1600)!; buffer.frameLength = 1600
        memset(buffer.floatChannelData![0], 0, 6400)
        for n in 0..<20 { bridge.append(buffer, startTime: 2+Double(n)/10) }
        bridge.finish(); XCTAssertNil(bridge.error())
        var previous = CMTime.zero, count = 0
        for try await item in pair.stream {
            let start = try XCTUnwrap(item.bufferStartTime)
            XCTAssertGreaterThanOrEqual(CMTimeCompare(start, previous), 0)
            previous = CMTimeAdd(start, CMTime(value: Int64(item.buffer.frameLength), timescale: 16000)); count += 1
        }
        XCTAssertGreaterThan(count, 1)
    }
    func testRecognitionQueueOverflowCannotInterruptDurableAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), feed = MeetingLiveAudioFeed()
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Synthetic overflow", source: "none", microphone: true), liveFeed: feed)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!; buffer.frameLength = 1024
        memset(buffer.floatChannelData![0], 0, 4096)
        for n in 0..<150 { writer.append(buffer, track: "mic", start: Double(n) * 1024 / 16000); await writer.synchronize() }
        let saved = try await writer.finish(state: "saved")
        XCTAssertEqual(saved.state, "saved"); XCTAssertTrue(saved.issue.isEmpty)
        XCTAssertEqual(try saved.chunks.reduce(Int64(0)) { $0 + (try AVAudioFile(forReading: store.audio($1, meeting: saved))).length }, 150*1024)
        var rejected = false
        do { for try await packet in feed.stream { feed.consumed(packet) } }
        catch { rejected = true }
        XCTAssertTrue(rejected)
    }
    func testResampledFeedAndStoredAudioHaveTheSameFramesAndClock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), feed = MeetingLiveAudioFeed(), speakers = MeetingLiveAudioFeed()
        let writer = try MeetingAudioWriter(store: store, meeting: .init(title: "Synthetic conversion", source: "none", microphone: true), liveFeed: feed, speakerFeed: speakers)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!; buffer.frameLength = 4800
        for channel in 0..<2 { for n in 0..<4800 { buffer.floatChannelData![channel][n] = Float(sin(Double(n)*0.05)*0.1) } }
        writer.append(buffer, track: "mic", start: 1.25)
        let saved = try await writer.finish(state: "paused"); feed.finish(); speakers.finish()
        var frames = 0, first: Double?
        var recognitionPackets: [MeetingAudioPacket] = []
        for try await event in feed.stream { feed.consumed(event); guard case .audio(let packet) = event else { return XCTFail("Unexpected control") }; first = first ?? packet.start; frames += packet.pcm.count/4; recognitionPackets.append(packet) }
        var speakerFrames = 0
        var index = 0
        for try await event in speakers.stream {
            speakers.consumed(event); guard case .audio(let packet) = event else { return XCTFail("Unexpected control") }; speakerFrames += packet.pcm.count/4
            XCTAssertLessThan(index, recognitionPackets.count)
            if index < recognitionPackets.count {
                XCTAssertEqual(packet.start, recognitionPackets[index].start)
                XCTAssertEqual(packet.track, recognitionPackets[index].track)
                XCTAssertEqual(packet.pcm, recognitionPackets[index].pcm)
            }
            index += 1
        }
        XCTAssertEqual(index, recognitionPackets.count)
        XCTAssertEqual(speakerFrames, frames)
        XCTAssertEqual(first, 1.25)
        XCTAssertEqual(frames, 1600)
        XCTAssertEqual(try saved.chunks.reduce(Int64(0)) { $0 + (try AVAudioFile(forReading: store.audio($1, meeting: saved))).length }, Int64(frames))
    }
    func testRetiredFeedDoesNotAcceptLateAudio() async throws {
        let feed = MeetingLiveAudioFeed(); feed.finish()
        feed.append(.init(track: "mic", start: 0, pcm: Data(repeating: 0, count: 4096)))
        var count = 0; for try await _ in feed.stream { count += 1 }; XCTAssertEqual(count, 0)
    }
}
