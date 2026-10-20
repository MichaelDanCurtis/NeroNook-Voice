import AVFoundation
import Foundation
import ModuleCore

/// Copies a bounded number of callback buffers, then writes/rotates them on one
/// worker queue. Never sends audio through the plugin protocol or holds a session in RAM.
public final class MeetingAudioWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let snapshotLock = NSLock()
    private var cached: (duration: Double, levels: [String: Double], last: [String: Double], error: String?) = (0, [:], [:], nil)
    private let slots = DispatchSemaphore(value: 64)
    private let store: MeetingStore
    private var meeting: Meeting
    private var committedDuration: Double
    private var active = true
    private var failure: String?
    private var files: [String: AVAudioFile] = [:]
    private var chunks: [String: MeetingChunk] = [:]
    private var converters: [String: AVAudioConverter] = [:]
    private var inputFormats: [String: AVAudioFormat] = [:]
    private var levels: [String: Double] = [:]
    private var last: [String: Double] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var serial: Int
    private var liveFeed: MeetingLiveAudioFeed?
    private var speakerFeed: MeetingLiveAudioFeed?
    public convenience init(store: MeetingStore, meeting: Meeting, liveFeed: MeetingLiveAudioFeed? = nil, speakerFeed: MeetingLiveAudioFeed? = nil) throws {
        try self.init(store: store, meeting: meeting, liveFeed: liveFeed, speakerFeed: speakerFeed,
                      storageQueue: DispatchQueue(label: "cafe.nero.voice.meeting-writer"))
    }
    init(store: MeetingStore, meeting: Meeting, liveFeed: MeetingLiveAudioFeed? = nil, speakerFeed: MeetingLiveAudioFeed? = nil,
         storageQueue: DispatchQueue) throws {
        queue = storageQueue
        self.store = store; self.meeting = meeting; committedDuration = meeting.duration; self.liveFeed = liveFeed; self.speakerFeed = speakerFeed; serial = meeting.chunks.count; try store.save(meeting)
        publishSnapshot()
    }
    /// Prepared observers start at the next durable buffer, without delaying
    /// capture or accumulating audio during model initialization.
    public func attachLiveFeed(_ feed: MeetingLiveAudioFeed?) { queue.async { self.liveFeed = feed } }
    public func attachSpeakerFeed(_ feed: MeetingLiveAudioFeed?) { queue.async { self.speakerFeed = feed } }
    public func append(_ input: AVAudioPCMBuffer, track: String, start: Double) {
        guard slots.wait(timeout: .now()) == .success else { queue.async { self.fail("Disk writing could not keep up. Saved audio is recoverable.") }; return }
        guard ["mic", "system"].contains(track), start.isFinite, start >= 0, input.frameLength > 0, input.frameLength <= 8192,
              input.format.channelCount <= 8, let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { slots.signal(); queue.async { self.fail("Unsupported recording buffer.") }; return }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<source.count { memcpy(target[index].mData!, source[index].mData!, Int(source[index].mDataByteSize)) }
        queue.async { defer { self.publishSnapshot(); self.slots.signal() }; guard self.active else { return }; do { try self.write(copy, track: track, start: start) } catch { self.fail(error.localizedDescription) } }
    }
    private func write(_ input: AVAudioPCMBuffer, track: String, start: Double) throws {
        guard start <= 4 * 3600 else { throw VoiceProblem.message("Four-hour recording limit reached. Start another meeting to continue.") }
        if input.format == format { try persist(input, track: track, start: start); return }
        if let previous = inputFormats[track], previous != input.format { throw VoiceProblem.message("Audio format changed. Resume to use the new device format.") }
        if converters[track] == nil { inputFormats[track] = input.format; converters[track] = AVAudioConverter(from: input.format, to: format) }
        guard let converter = converters[track], let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536) else { throw VoiceProblem.message("Cannot prepare audio storage") }
        var fed = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }; fed = true; status.pointee = .haveData; return input
        }
        if let error { throw error }; guard output.frameLength > 0 else { return }
        try persist(output, track: track, start: start)
    }
    private func persist(_ output: AVAudioPCMBuffer, track: String, start: Double) throws {
        var peak: Float = 0
        for i in 0..<Int(output.frameLength) { peak = max(peak, abs(output.floatChannelData![0][i])) }
        levels[track] = min(1, Double(peak) * 3); last[track] = ProcessInfo.processInfo.systemUptime
        if files[track] == nil {
            let capacity = try store.root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
            guard capacity > 100_000_000 else { throw VoiceProblem.message("Less than 100 MB remains. Recording stopped; saved audio is retained.") }
            serial += 1
            let name = "\(track)-\(serial)-\(Int((start * 1000).rounded())).caf"
            let url = store.folder(meeting.id).appendingPathComponent(name)
            files[track] = try AVAudioFile(forWriting: url, settings: format.settings)
            chunks[track] = MeetingChunk(file: name, track: track, start: start, duration: 0)
        }
        try files[track]!.write(from: output)
        chunks[track]!.duration = Double(files[track]!.length) / 16000
        liveFeed?.append(output, track: track, start: start)
        speakerFeed?.append(output, track: track, start: start)
        if chunks[track]!.duration >= 15 { try close(track) }
    }
    private func close(_ track: String) throws {
        files.removeValue(forKey: track) // Close CAF before committing its index.
        if let chunk = chunks.removeValue(forKey: track), chunk.duration > 0 { meeting.chunks.append(chunk); committedDuration = max(committedDuration, chunk.start + chunk.duration); try store.save(meeting) }
    }
    private func fail(_ message: String) { if failure == nil { failure = String(message.prefix(450)) }; active = false; publishSnapshot() }
    private func publishSnapshot() {
        let value = (max(committedDuration, chunks.values.map { $0.start + $0.duration }.max() ?? 0), levels, last, failure)
        snapshotLock.lock(); cached = value; snapshotLock.unlock()
    }
    public func snapshot() -> (duration: Double, levels: [String: Double], last: [String: Double], error: String?) {
        snapshotLock.lock(); defer { snapshotLock.unlock() }; return cached
    }
    /// Explicit asynchronous storage barrier for file-fed fixtures and owners
    /// that need durability, rather than using the UI meter as a queue drain.
    public func synchronize() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    public func mark(_ text: String) { queue.async {
        guard self.meeting.marks.count < 1000 else { return }
        let time = max(self.meeting.duration, self.chunks.values.map { $0.start + $0.duration }.max() ?? 0)
        self.meeting.marks.append(MeetingMark(time: time, text: String(text.prefix(200))))
        do { try self.store.save(self.meeting); self.publishSnapshot() } catch { self.fail(error.localizedDescription) }
    } }
    public func finish(state: String, issue: String = "") async throws -> Meeting {
        try await withCheckedThrowingContinuation { continuation in queue.async {
            do { continuation.resume(returning: try self.finalize(state: state, issue: issue)) } catch { continuation.resume(throwing: error) }
        } }
    }
    public func finishSynchronously() { queue.sync { _ = try? finalize(state: "saved", issue: "Voice closed; recording was saved.") } }
    private func finalize(state: String, issue: String) throws -> Meeting {
        active = false
        if failure == nil {
            for (track, converter) in converters {
                for _ in 0..<16 {
                    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
                    var error: NSError?
                    let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                    if let error { fail(error.localizedDescription); break }
                    if output.frameLength > 0 {
                        let lastEnd = max(meeting.chunks.filter { $0.track == track }.map { $0.start + $0.duration }.max() ?? 0, chunks[track].map { $0.start + $0.duration } ?? 0)
                        try persist(output, track: track, start: lastEnd)
                    }
                    if status == .endOfStream || output.frameLength == 0 { break }
                }
            }
        }
        converters = [:]
        for track in Array(files.keys) { try close(track) }
        meeting.state = failure == nil ? state : "interrupted"; meeting.issue = failure ?? issue
        try store.save(meeting); publishSnapshot(); return meeting
    }
    /// Inspect only our own named CAF files; salvage chunks closed after the last
    /// manifest commit. A malformed/missing tail is reported rather than invented.
    public static func recover(_ source: Meeting, store: MeetingStore) throws -> Meeting {
        var value = source
        let folder = store.folder(value.id)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
        for url in files where url.pathExtension == "caf" && !value.chunks.contains(where: { $0.file == url.lastPathComponent }) {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count == 3, ["mic", "system"].contains(String(parts[0])), Int(parts[1]) != nil,
                  let start = Double(parts[2]), start >= 0, (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { continue }
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { value.issue = "One unfinished audio chunk could not be recovered."; continue }
            let chunk = MeetingChunk(file: url.lastPathComponent, track: String(parts[0]), start: start / 1000, duration: Double(file.length) / file.processingFormat.sampleRate)
            guard chunk.duration <= 20, chunk.start + chunk.duration <= 14430 else { continue }; value.chunks.append(chunk)
        }
        value.chunks.sort { $0.start < $1.start }
        if value.state == "recording" || value.state == "paused" { value.state = "interrupted"; if value.issue.isEmpty { value.issue = "Recovered after interruption. Review the saved recording." } }
        try store.save(value); return value
    }
}
