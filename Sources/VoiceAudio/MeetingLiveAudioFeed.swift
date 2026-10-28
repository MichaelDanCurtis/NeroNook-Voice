import Foundation
import AVFoundation
import ModuleCore

public struct MeetingAudioPacket: Sendable {
    public let track: String
    public let start: Double
    public let pcm: Data
    public var end: Double { start + Double(pcm.count / 4) / 16000 }
    public init(track: String, start: Double, pcm: Data) { self.track = track; self.start = start; self.pcm = pcm }
}

/// Controls share the PCM queue. A boundary cannot overtake captured audio or
/// race a second writer on the framed worker pipe.
public enum MeetingLiveInput: Sendable {
    case audio(MeetingAudioPacket)
    case boundary(UUID)
}

/// Optional recognition observes audio AFTER the durable writer. Bounded queue
/// overflow stops only live words, never capture or disk persistence.
public final class MeetingLiveAudioFeed: @unchecked Sendable {
    public let stream: AsyncThrowingStream<MeetingLiveInput, Error>
    private let continuation: AsyncThrowingStream<MeetingLiveInput, Error>.Continuation
    private let lock = NSLock()
    private var active = true
    private var queued = 0
    /// Preparing recognizers may retain a larger bounded opening queue. The
    /// byte ceiling is unchanged, and overflow still cannot stop durable audio.
    public init(bufferingLimit: Int = 128) {
        let limit = min(512, max(1, bufferingLimit))
        let pair = AsyncThrowingStream<MeetingLiveInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(limit))
        stream = pair.stream; continuation = pair.continuation
    }
    public func append(_ buffer: AVAudioPCMBuffer, track: String, start: Double) {
        guard buffer.format.sampleRate == 16000, buffer.format.channelCount == 1,
              buffer.format.commonFormat == .pcmFormatFloat32, buffer.frameLength <= 16384,
              let channel = buffer.floatChannelData?[0] else { fail("Unsupported live audio; recording continues."); return }
        let data = Data(bytes: channel, count: Int(buffer.frameLength) * 4)
        append(.init(track: track, start: start, pcm: data))
    }
    public func append(_ packet: MeetingAudioPacket) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        guard ["mic", "system"].contains(packet.track), packet.start.isFinite, packet.start >= 0, packet.end <= 14430,
              !packet.pcm.isEmpty, packet.pcm.count <= 65536, packet.pcm.count.isMultiple(of: 4), queued + packet.pcm.count <= 2048000 else {
            active = false; continuation.finish(throwing: VoiceProblem.message("Live transcription could not keep up. Audio recording continues; transcribe it afterward.")); return
        }
        queued += packet.pcm.count
        if case .dropped = continuation.yield(.audio(packet)) {
            active = false; continuation.finish(throwing: VoiceProblem.message("Live transcription queue filled. Audio recording continues; transcribe it afterward."))
        }
    }
    @discardableResult public func boundary(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        switch continuation.yield(.boundary(id)) {
        case .enqueued: return true
        default:
            active = false
            continuation.finish(throwing: VoiceProblem.message("Live speech could not finish this turn. Audio remains separate."))
            return false
        }
    }
    public func consumed(_ input: MeetingLiveInput) { if case .audio(let packet) = input { consumed(packet) } }
    public func consumed(_ packet: MeetingAudioPacket) { lock.lock(); queued = max(0, queued - packet.pcm.count); lock.unlock() }
    public func finish() { lock.lock(); active = false; continuation.finish(); lock.unlock() }
    public func fail(_ message: String) { lock.lock(); active = false; continuation.finish(throwing: VoiceProblem.message(message)); lock.unlock() }
}
