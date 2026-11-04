import XCTest
import AVFoundation
import Speech
import ModuleCore
@testable import VoiceAudio

/// Authored PCM only: these tests exercise the actual meeting feed and Apple
/// bridge without an analyzer, model, device, app, or user meeting store.
final class MeetingBridgePacketBoundTests: XCTestCase {
    private func pcm(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = 0.25 }
        return buffer
    }

    private func assertMeetingPacket(_ frames: AVAudioFrameCount,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let input = pcm(frames), feed = MeetingLiveAudioFeed()
        feed.append(input, track: "mic", start: 2)
        feed.finish()
        var iterator = feed.stream.makeAsyncIterator()
        let next = try await iterator.next()
        let event = try XCTUnwrap(next, file: file, line: line)
        guard case .audio(let packet) = event else { return XCTFail("Expected actual accepted audio", file: file, line: line) }
        XCTAssertEqual(packet.pcm.count, Int(frames) * 4, file: file, line: line)
        feed.consumed(event)
        let reconstructed = pcm(frames)
        _ = packet.pcm.withUnsafeBytes { memcpy(reconstructed.floatChannelData![0], $0.baseAddress!, packet.pcm.count) }
        let analyzerFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let pair = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        #if MEETING_PACKET_ORIGINAL_WITNESS
        // The untouched original meeting path uses the default 8192 bridge.
        let bridge = try AudioBridge(input: input.format, output: analyzerFormat, continuation: pair.continuation)
        #else
        let bridge = try AudioBridge(input: input.format, output: analyzerFormat, continuation: pair.continuation, maxInputFrames: 16384)
        #endif
        bridge.append(reconstructed, startTime: packet.start)
        XCTAssertNil(bridge.error(), "A packet admitted by the meeting feed must reach the Apple bridge", file: file, line: line)
        bridge.finish()
        var emittedFrames = 0, peak: Float = 0
        for try await item in pair.stream {
            // macOS27 returns a new buffer copy: retain it while using sample pointers.
            let emitted = item.buffer
            withExtendedLifetime(emitted) {
                emittedFrames += Int(emitted.frameLength)
                if let channel = emitted.int16ChannelData?[0] {
                    for index in 0..<Int(emitted.frameLength) { peak = max(peak, abs(Float(channel[index]))) }
                }
            }
        }
        XCTAssertEqual(emittedFrames, Int(frames), "Every accepted same-rate PCM frame must reach analyzer input", file: file, line: line)
        XCTAssertGreaterThan(peak, 0, "The authored non-silent samples must reach analyzer input", file: file, line: line)
        XCTAssertNil(bridge.error(), file: file, line: line)
    }

    func testAcceptedMeetingPacketsCrossOldBridgeBoundary() async throws {
        try await assertMeetingPacket(8192)
        try await assertMeetingPacket(8193)
        try await assertMeetingPacket(16384)
    }

    func testOrdinaryBridgeKeepsOriginalInputLimit() throws {
        let input = pcm(8192)
        let bridge = try AudioBridge(input: input.format, output: input.format, continuation: nil)
        bridge.append(input)
        XCTAssertNil(bridge.error())
        bridge.append(pcm(8193))
        XCTAssertEqual(bridge.error(), "Unsupported microphone buffer.")
    }

    func testMeetingFeedRejectsPacketsAboveItsExistingCeiling() async throws {
        let feed = MeetingLiveAudioFeed()
        feed.append(pcm(16385), track: "mic", start: 0)
        var iterator = feed.stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("An oversized meeting packet must not be silently admitted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Unsupported live audio"))
        }
    }
}
