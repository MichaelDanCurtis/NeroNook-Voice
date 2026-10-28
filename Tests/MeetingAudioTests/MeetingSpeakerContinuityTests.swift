import XCTest
import AVFoundation
import Darwin
import ModuleCore
@testable import VoiceAudio

final class MeetingSpeakerContinuityTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NeroSpeakerContinuity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    @MainActor private func opening(_ existing: MeetingLiveSpeakerAnalyzer? = nil, continuing: Bool = false,
        separation: Bool = true, modelReady: Bool = true, live: Bool = true,
        provider: MeetingASRProvider = .apple) -> MeetingLiveAudioFeed? {
        MeetingLiveSpeakerAnalyzer.recordingFeed(existing: existing, continuingMeeting: continuing,
            separation: separation, modelReady: modelReady, live: live, provider: provider)
    }
    private func buffer(track: String) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let value = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        value.frameLength = 1024
        for n in 0..<1024 { value.floatChannelData![0][n] = Float(n) / (track == "mic" ? 2048 : -4096) }
        return value
    }
    private func savedPCM(_ meeting: Meeting, store: MeetingStore, track: String) throws -> Data {
        var result = Data()
        for chunk in meeting.chunks.filter({ $0.track == track }).sorted(by: { $0.start < $1.start }) {
            let file = try AVAudioFile(forReading: store.audio(chunk, meeting: meeting))
            let value = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: value)
            result.append(Data(bytes: value.floatChannelData![0], count: Int(value.frameLength) * 4))
        }
        return result
    }
    private func worker(_ root: URL) throws -> (URL, URL) {
        let path = root.appendingPathComponent("worker.py"), log = root.appendingPathComponent("packets.jsonl")
        try Data(Self.worker.utf8).write(to: path)
        return (path, log)
    }
    @MainActor func testActualSelectionUsesOnlyEligibleNewQueueAndPreservesPreparingResume() throws {
        let feed = try XCTUnwrap(opening()), service = MeetingLiveSpeakerAnalyzer(feed: feed)
        defer { service.cancel() }
        XCTAssertTrue(opening(service, continuing: true) === feed)
        // Failure must not silently start another live model on resume.
        XCTAssertNil(opening(nil, continuing: true))
        XCTAssertNil(opening(separation: false)); XCTAssertNil(opening(modelReady: false))
        XCTAssertNil(opening(live: false)); XCTAssertNil(opening(provider: .parakeet))
        XCTAssertNil(opening(provider: .nemotron))
        XCTAssertFalse(opening(service) === feed)
    }
    @MainActor func testDelayedSpeakerStartupAndPauseResumeKeepExactRoomCallPCMAndClocks() async throws {
        let root = try folder(), store = try MeetingStore(root: root.appendingPathComponent("meetings"))
        let feed = try XCTUnwrap(opening()), service = MeetingLiveSpeakerAnalyzer(feed: feed)
        defer { service.cancel() }
        var meeting = Meeting(title: "Authored delayed speaker preparation", source: "all", microphone: true)
        let room = buffer(track: "mic"), call = buffer(track: "system")
        var writer = try MeetingAudioWriter(store: store, meeting: meeting, speakerFeed: feed)
        for n in 0..<80 {
            writer.append(room, track: "mic", start: Double(n)*0.064)
            writer.append(call, track: "system", start: 0.25+Double(n)*0.064)
            await writer.synchronize()
        }
        meeting = try await writer.finish(state: "paused")
        // Model is deliberately not started: Resume must retain the same pending
        // queue/consumer and absolute per-track clocks, not replace either.
        let resumed = try XCTUnwrap(opening(service, continuing: true))
        XCTAssertTrue(resumed === feed)
        writer = try MeetingAudioWriter(store: store, meeting: meeting, speakerFeed: resumed)
        for n in 80..<200 {
            writer.append(room, track: "mic", start: Double(n)*0.064)
            writer.append(call, track: "system", start: 0.25+Double(n)*0.064)
            await writer.synchronize()
        }
        meeting = try await writer.finish(state: "saved")
        let (script, log) = try worker(root)
        var labels = MeetingLiveSpeakers(); let epoch = labels.epoch
        var failure = ""
        try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, log.path],
            update: { track, spans, through in try labels.receive(track: track, spans: spans, through: through, epoch: epoch) },
            failure: { failure = $0 })
        try await service.finish()
        XCTAssertTrue(failure.isEmpty); XCTAssertEqual(labels.epoch, epoch)
        let rows = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        XCTAssertEqual(rows.count, 400) // Greater than the ordinary 128-message queue.
        for track in ["mic", "system"] {
            let packets = rows.filter { $0["track"] as? String == track }
            XCTAssertEqual(packets.count, 200)
            let first = try XCTUnwrap(packets.first?["start"] as? Double)
            XCTAssertEqual(first, track == "mic" ? 0 : 0.25, accuracy: 0.000001)
            var pcm = Data()
            for (n, packet) in packets.enumerated() {
                XCTAssertEqual(try XCTUnwrap(packet["start"] as? Double), first+Double(n)*0.064, accuracy: 0.000001)
                pcm.append(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(packet["pcm"] as? String))))
            }
            XCTAssertEqual(pcm.count, 200*1024*4)
            XCTAssertEqual(pcm, try savedPCM(meeting, store: store, track: track))
            XCTAssertEqual(try XCTUnwrap(labels.through[track]), first+12.8, accuracy: 0.000001)
        }
    }
    @MainActor func testOpeningSpeakerOverflowFailsFinalAttributionButKeepsAudioAndRecognition() async throws {
        let root = try folder(), store = try MeetingStore(root: root.appendingPathComponent("meetings"))
        let feed = try XCTUnwrap(opening()), recognition = MeetingLiveAudioFeed()
        let service = MeetingLiveSpeakerAnalyzer(feed: feed); defer { service.cancel() }
        let writer = try MeetingAudioWriter(store: store,
            meeting: .init(title: "Authored bounded speaker overflow", source: "all", microphone: true),
            liveFeed: recognition, speakerFeed: feed)
        var words = recognition.stream.makeAsyncIterator(), recognitionFrames = 0
        for n in 0..<300 {
            for track in ["mic", "system"] {
                writer.append(buffer(track: track), track: track, start: Double(n)*0.064 + (track == "mic" ? 0 : 0.25))
                await writer.synchronize()
                guard case .audio(let packet) = try await words.next() else { return XCTFail("Recognition lost durable audio") }
                recognition.consumed(packet); recognitionFrames += packet.pcm.count/4
            }
        }
        let meeting = try await writer.finish(state: "saved"); recognition.finish()
        XCTAssertEqual(recognitionFrames, 600*1024); XCTAssertTrue(meeting.issue.isEmpty)
        for track in ["mic", "system"] { XCTAssertEqual(try savedPCM(meeting, store: store, track: track).count, 300*1024*4) }
        let (script, log) = try worker(root); var failure = "", completed = false
        try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, log.path],
            update: { _, _, _ in }, failure: { failure = $0 })
        do { try await service.finish(); completed = true } catch { }
        XCTAssertFalse(completed, "Partial opening attribution must not suppress saved-audio fallback")
        XCTAssertFalse(failure.isEmpty)
    }
    @MainActor func testStopWhileWaitingForModelCannotLaunchRetiredWorker() async throws {
        let root = try folder(), (script, log) = try worker(root)
        let service = MeetingLiveSpeakerAnalyzer(feed: try XCTUnwrap(opening()))
        var continuation: CheckedContinuation<Void, Never>?
        let waiting = expectation(description: "Speaker startup reached model availability wait")
        var updates = 0
        let pending = Task {
            try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, log.path],
                waitForAvailable: { await withCheckedContinuation { continuation = $0; waiting.fulfill() } },
                update: { _, _, _ in updates += 1 }, failure: { _ in })
        }
        defer { service.cancel(); pending.cancel(); continuation?.resume(); continuation = nil }
        await fulfillment(of: [waiting], timeout: 2)
        let resume = try XCTUnwrap(continuation); continuation = nil
        // Stop retires the instance independently of cancellation propagation.
        service.cancel(); resume.resume()
        do { try await pending.value; XCTFail("Stopped preparation launched") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path)); XCTAssertEqual(updates, 0)
    }
    @MainActor func testTaskCancellationWhileWaitingCannotLaunchWorker() async throws {
        let root = try folder(), (script, log) = try worker(root)
        let service = MeetingLiveSpeakerAnalyzer(); defer { service.cancel() }
        var continuation: CheckedContinuation<Void, Never>?
        let waiting = expectation(description: "Speaker startup reached cancellable availability wait")
        let pending = Task {
            try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, log.path],
                waitForAvailable: { await withCheckedContinuation { continuation = $0; waiting.fulfill() } }, update: { _, _, _ in }, failure: { _ in })
        }
        defer { pending.cancel(); continuation?.resume(); continuation = nil }
        await fulfillment(of: [waiting], timeout: 2)
        let resume = try XCTUnwrap(continuation); continuation = nil
        pending.cancel(); resume.resume()
        do { try await pending.value; XCTFail("Cancelled preparation launched") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }
    @MainActor func testStopDuringWorkerPreparationNeverConsumesQueuedAudioOrPublishesLateLabels() async throws {
        let root = try folder(), (script, log) = try worker(root)
        let gate = root.appendingPathComponent("ready-gate"), marker = root.appendingPathComponent("waiting-pid")
        let feed = try XCTUnwrap(opening()), service = MeetingLiveSpeakerAnalyzer(feed: feed)
        feed.append(.init(track: "mic", start: 0, pcm: Data(repeating: 0, count: 4096)))
        var updates = 0, failures = 0
        let pending = Task {
            try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: [script.path, log.path, gate.path, marker.path],
                update: { _, _, _ in updates += 1 }, failure: { _ in failures += 1 })
        }
        defer { service.cancel(); pending.cancel() }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let pid = try XCTUnwrap(Int32(try String(contentsOf: marker, encoding: .utf8)))
        service.cancel()
        try Data().write(to: gate) // A late ready signal cannot revive a stopped session.
        do { try await pending.value; XCTFail("Stopped worker preparation became ready") } catch { }
        for _ in 0..<200 where kill(pid, 0) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(try Data(contentsOf: log).count, 0)
        XCTAssertEqual(updates, 0); XCTAssertEqual(failures, 0)
    }
    private static let worker = #"""
import base64,json,os,struct,sys,time
from pathlib import Path
out=Path(sys.argv[1])
def emit(x): print(json.dumps(x),flush=True)
def read(n):
    data=b''
    while len(data)<n:
        chunk=sys.stdin.buffer.read(n-len(data))
        if not chunk: raise EOFError()
        data+=chunk
    return data
with out.open('w') as records:
    if len(sys.argv)>3:
        Path(sys.argv[3]).write_text(str(os.getpid()))
        while not Path(sys.argv[2]).exists(): time.sleep(0.01)
    emit({'type':'ready'})
    while True:
        n=struct.unpack('<I',read(4))[0]
        if n==0: break
        h=json.loads(read(n));pcm=read(h['length'])
        records.write(json.dumps({'track':h['track'],'start':h['start'],'pcm':base64.b64encode(pcm).decode()})+'\n')
        records.flush()
        end=h['start']+len(pcm)/64000
        emit({'type':'spans','track':h['track'],'through':end,'spans':[{'start':h['start'],'end':end,'speaker':0}]})
    emit({'type':'closed'})
"""#
}
