import XCTest
import Foundation
import AVFoundation
import Darwin
import ModuleCore
@testable import VoiceAudio

/// Actual authored Python workers and the production stdout transport. No model,
/// microphone, capture, account, network or installed/default profile is used.
@MainActor final class MeetingSpeakerOutputTests: XCTestCase {
    func testFragmentedAndCoalescedRoomCallSpansRetainOrderFinalTailAndDurableAudio() async throws {
        let f = try await fixture(mode: "fragmented")
        try await f.start(); f.beginFinish(); try await f.joinFinish()
        XCTAssertTrue(f.finishSucceeded); XCTAssertTrue(f.failures.isEmpty)
        f.assertFourUpdates(); try f.assertAudioPreserved()
        XCTAssertEqual(f.labels.through["mic"] ?? -1, 0.128, accuracy: 0.000001)
        XCTAssertEqual(f.labels.through["system"] ?? -1, 0.378, accuracy: 0.000001)
        XCTAssertTrue(try f.marker("output-complete"))
        let fragmented = try f.json("fragmented-line")
        XCTAssertGreaterThan(try XCTUnwrap(fragmented["bytes"] as? Int), 16_384)
        XCTAssertLessThan(try XCTUnwrap(fragmented["bytes"] as? Int), 262_144)
    }

    func testEOFMissingClosedFailsOptionalAttributionWithoutDiscardingSavedAudio() async throws {
        let f = try await fixture(mode: "missing-closed")
        try await f.start(); f.beginFinish(); try await f.joinFinish()
        XCTAssertFalse(f.finishSucceeded); XCTAssertNotNil(f.finishError)
        XCTAssertTrue(f.failures.contains { $0.contains("ended before final labels") })
        f.assertFourUpdates(); try f.assertAudioPreserved()
    }

    func testExitedWorkerFinalTailCannotFinishUntilOriginalReaderIsReleased() async throws {
        let f = try await fixture(mode: "coalesced", holdReader: true)
        try await f.start(); XCTAssertTrue(f.readerGate.entered)
        f.beginFinish()
        try await f.wait { try f.marker("output-complete") && f.workerAbsent() }
        XCTAssertFalse(f.finishDone, "Process exit is not ordered stdout completion")
        XCTAssertTrue(f.updates.isEmpty)
        XCTAssertFalse(f.readerGate.released)
        f.readerGate.release(); try await f.joinFinish()
        XCTAssertFalse(f.finishedBeforeReaderRelease)
        XCTAssertTrue(f.finishSucceeded); XCTAssertTrue(f.failures.isEmpty)
        f.assertFourUpdates(); try f.assertAudioPreserved()
    }

    func testBoundedOutputBurstWhileReaderHeldRequiresFallbackAndPreservesAudio() async throws {
        let f = try await fixture(mode: "overflow", holdReader: true)
        try await f.start(); f.beginFinish()
        try await f.wait { try f.marker("burst") && f.workerAbsent() }
        let receipt = try f.json("burst")
        XCTAssertGreaterThan(try XCTUnwrap(receipt["requestedBytes"] as? Int), 2 * 1_048_576)
        XCTAssertTrue(try XCTUnwrap(receipt["backpressure"] as? Bool))
        XCTAssertLessThan(try XCTUnwrap(receipt["writtenBytes"] as? Int), try XCTUnwrap(receipt["requestedBytes"] as? Int))
        XCTAssertFalse(f.finishDone); XCTAssertTrue(f.updates.isEmpty)
        f.readerGate.release(); try await f.joinFinish()
        XCTAssertFalse(f.finishSucceeded); XCTAssertNotNil(f.finishError)
        XCTAssertTrue(f.failures.contains { $0.contains("output") && ($0.contains("keep up") || $0.contains("limit")) })
        try f.assertAudioPreserved()
        // Queue/output failure only: no RSS, DER, speech-quality or capture claim.
    }

    func testStopWithQueuedFinalOutputDiscardsLabelsAfterReaderRelease() async throws {
        let f = try await fixture(mode: "coalesced", holdReader: true)
        try await f.start(); f.beginFinish()
        try await f.wait { try f.marker("output-complete") && f.workerAbsent() }
        f.service.cancel() // Actual service Stop while its original reader is held.
        f.readerGate.release(); try await f.joinFinish()
        XCTAssertTrue(f.updates.isEmpty); XCTAssertTrue(f.failures.isEmpty)
        XCTAssertFalse(f.finishSucceeded)
        try f.assertAudioPreserved()
    }

    func testSynchronousStopInFirstUpdateDropsLaterCoalescedSpans() async throws {
        let f = try await fixture(mode: "coalesced")
        f.stopAtFirstUpdate = true
        try await f.start(); f.beginFinish(); try await f.joinFinish()
        try await f.wait { try f.workerAbsent() }
        XCTAssertEqual(f.updates.count, 1)
        XCTAssertEqual(f.updates.first?.track, "mic")
        XCTAssertEqual(f.updates.first?.through ?? -1, 0.064, accuracy: 0.000001)
        XCTAssertTrue(f.failures.isEmpty)
        XCTAssertFalse(f.finishSucceeded)
        try f.assertAudioPreserved()
    }

    func testSpanAfterClosedFailsWithoutPublishingLateLabel() async throws {
        let f = try await fixture(mode: "terminal-spans")
        try await f.start(); f.beginFinish(); try await f.joinFinish()
        XCTAssertFalse(f.finishSucceeded); XCTAssertNotNil(f.finishError)
        XCTAssertTrue(f.failures.contains { $0.contains("after closing") })
        f.assertFourUpdates(); try f.assertAudioPreserved()
        XCTAssertEqual(f.labels.through["mic"] ?? -1, 0.128, accuracy: 0.000001)
        XCTAssertEqual(f.labels.through["system"] ?? -1, 0.378, accuracy: 0.000001)
    }

    func testAckOrDuplicateClosedFailsTerminalAttribution() async throws {
        for mode in ["terminal-ack", "terminal-duplicate"] {
            let f = try await fixture(mode: mode)
            try await f.start(); f.beginFinish(); try await f.joinFinish()
            XCTAssertFalse(f.finishSucceeded, mode); XCTAssertNotNil(f.finishError, mode)
            XCTAssertTrue(f.failures.contains { $0.contains("after closing") }, mode)
            f.assertFourUpdates(); try f.assertAudioPreserved()
            // The next real worker cannot borrow availability while this
            // original failure is still retiring under the existing Stop policy.
            try await f.wait { try f.workerAbsent() }
        }
    }

    func testClosedWithIncompleteTrailingJSONFailsAndPreservesAudio() async throws {
        let f = try await fixture(mode: "terminal-partial")
        try await f.start(); f.beginFinish(); try await f.joinFinish()
        XCTAssertFalse(f.finishSucceeded); XCTAssertNotNil(f.finishError)
        XCTAssertTrue(f.failures.contains { $0.contains("incomplete trailing data") })
        f.assertFourUpdates(); try f.assertAudioPreserved()
    }

    func testFragmentedTerminalClosedJoinsOriginalReaderAndPreservesAudio() async throws {
        let f = try await fixture(mode: "terminal-fragmented", holdReader: true)
        try await f.start(); XCTAssertTrue(f.readerGate.entered)
        f.beginFinish()
        try await f.wait { try f.marker("output-complete") && f.workerAbsent() }
        XCTAssertFalse(f.finishDone); XCTAssertTrue(f.updates.isEmpty)
        let terminal = try f.json("terminal-line")
        XCTAssertGreaterThan(try XCTUnwrap(terminal["bytes"] as? Int), 16_384)
        XCTAssertLessThan(try XCTUnwrap(terminal["bytes"] as? Int), 262_144)
        f.readerGate.release(); try await f.joinFinish()
        XCTAssertFalse(f.finishedBeforeReaderRelease)
        XCTAssertTrue(f.finishSucceeded); XCTAssertTrue(f.failures.isEmpty)
        f.assertFourUpdates(); try f.assertAudioPreserved()
    }

    private func fixture(mode: String, holdReader: Bool = false) async throws -> SpeakerOutputFixture {
        let f = try SpeakerOutputFixture(mode: mode, holdReader: holdReader)
        addTeardownBlock { @MainActor in
            do { try await f.cleanup() }
            catch { XCTFail("Original worker/task unsettled; authored root preserved at \(f.root.path): \(error)") }
        }
        try await f.saveAuthoredAudio()
        return f
    }
}

@MainActor private final class SpeakerOutputReaderGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var released: Bool
    init(hold: Bool) { released = !hold }
    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        let original = continuation; continuation = nil
        original?.resume()
    }
}

@MainActor private final class SpeakerOutputFixture {
    struct Update { let track: String; let spans: [MeetingSpeakerSpan]; let through: Double }
    let root, script: URL
    let feed = MeetingLiveAudioFeed(bufferingLimit: 512)
    let service: MeetingLiveSpeakerAnalyzer
    let readerGate: SpeakerOutputReaderGate
    let store: MeetingStore
    private(set) var meeting: Meeting
    private let mode: String
    private var expectedPCM: [String: Data] = [:]
    private var savedPID: Int32?
    private var startRequested = false
    private var startTask: Task<Void, Never>?
    private var startDone = true
    private var startError: Error?
    private var finishTask: Task<Void, Never>?
    private(set) var finishDone = true
    private(set) var finishSucceeded = false
    private(set) var finishError: Error?
    private(set) var finishedBeforeReaderRelease = false
    private(set) var updates: [Update] = []
    private(set) var failures: [String] = []
    var labels = MeetingLiveSpeakers()
    var stopAtFirstUpdate = false
    private var disposed = false

    init(mode: String, holdReader: Bool) throws {
        let raw = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(raw) }
        root = URL(fileURLWithPath: String(cString: raw), isDirectory: true)
            .appendingPathComponent("NeroSpeakerOutput-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let authoredRoot = root; var initialized = false
        defer { if !initialized { try? FileManager.default.removeItem(at: authoredRoot) } }
        script = root.appendingPathComponent("worker.py")
        try Data(Self.worker.utf8).write(to: script)
        store = try MeetingStore(root: root.appendingPathComponent("meetings"))
        meeting = Meeting(title: "Authored speaker output", source: "all", microphone: true)
        service = MeetingLiveSpeakerAnalyzer(feed: feed)
        readerGate = SpeakerOutputReaderGate(hold: holdReader)
        self.mode = mode
        let actualGate = readerGate
        service.outputReaderReady = { await actualGate.wait() }
        initialized = true
    }
    func saveAuthoredAudio() async throws {
        let writer = try MeetingAudioWriter(store: store, meeting: meeting, speakerFeed: feed)
        for n in 0..<2 {
            for track in ["mic", "system"] {
                let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
                let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
                pcm.frameLength = 1024
                let channel = try XCTUnwrap(pcm.floatChannelData?[0])
                for i in 0..<1024 { channel[i] = Float(i + n) / (track == "mic" ? 4096 : -8192) }
                expectedPCM[track, default: Data()].append(Data(bytes: channel, count: 4096))
                writer.append(pcm, track: track, start: Double(n) * 0.064 + (track == "mic" ? 0 : 0.25))
                await writer.synchronize()
            }
        }
        meeting = try await writer.finish(state: "saved")
        XCTAssertTrue(meeting.issue.isEmpty)
    }
    func start() async throws {
        guard !startRequested else { throw SpeakerOutputFailure.state }
        startRequested = true; startDone = false
        let expectedEpoch = labels.epoch
        let original = Task { @MainActor [self] in
            do {
                try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-I", "-B", script.path, root.path, mode], waitForAvailable: {},
                    update: { [self] track, spans, through in
                        try labels.receive(track: track, spans: spans, through: through, epoch: expectedEpoch)
                        updates.append(.init(track: track, spans: spans, through: through))
                        if stopAtFirstUpdate && updates.count == 1 { service.cancel() }
                    }, failure: { [self] in failures.append($0) })
            } catch { startError = error }
            startDone = true
        }
        startTask = original
        try await wait { self.startDone }
        await original.value
        if let startError { throw startError }
        try capturePID()
    }
    func beginFinish() {
        guard finishTask == nil else { XCTFail("No replacement finish task permitted"); return }
        finishDone = false
        finishTask = Task { @MainActor [self] in
            do { try await service.finish(); finishSucceeded = true }
            catch { finishError = error }
            finishedBeforeReaderRelease = !readerGate.released
            finishDone = true
        }
    }
    func joinFinish() async throws {
        try await wait { self.finishDone }
        if let finishTask { await finishTask.value }
    }
    func wait(_ predicate: () throws -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 8
        while true {
            guard ProcessInfo.processInfo.systemUptime < end else { throw SpeakerOutputFailure.timeout }
            let value = try predicate()
            guard ProcessInfo.processInfo.systemUptime < end else { throw SpeakerOutputFailure.timeout }
            if value { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func capturePID() throws {
        if savedPID != nil { return }
        let text = try String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)
        guard let pid = Int32(text), pid > 1 else { throw SpeakerOutputFailure.state }
        savedPID = pid
    }
    func workerAbsent() throws -> Bool {
        try capturePID()
        guard let savedPID else { throw SpeakerOutputFailure.state }
        if kill(savedPID, 0) == 0 { return false }
        guard errno == ESRCH else { throw SpeakerOutputFailure.state }
        return true
    }
    func marker(_ name: String) throws -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }
    func json(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name))) as? [String: Any])
    }
    func assertFourUpdates(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(updates.map(\.track), ["mic", "system", "mic", "system"], file: file, line: line)
        let expected = [0.064, 0.314, 0.128, 0.378]
        XCTAssertEqual(updates.count, expected.count, file: file, line: line)
        for (index, update) in updates.enumerated() where index < expected.count {
            XCTAssertEqual(update.through, expected[index], accuracy: 0.000001, file: file, line: line)
            XCTAssertEqual(update.spans.count, 1, file: file, line: line)
            XCTAssertEqual(update.spans.first?.speaker, update.track == "mic" ? 0 : 1, file: file, line: line)
            XCTAssertEqual(update.spans.first?.end ?? -1, expected[index], accuracy: 0.000001, file: file, line: line)
        }
    }
    func assertAudioPreserved(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(meeting.issue.isEmpty, file: file, line: line)
        for track in ["mic", "system"] {
            var actual = Data()
            for chunk in meeting.chunks.filter({ $0.track == track }).sorted(by: { $0.start < $1.start }) {
                let audio = try AVAudioFile(forReading: store.audio(chunk, meeting: meeting))
                let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
                try audio.read(into: pcm)
                actual.append(Data(bytes: try XCTUnwrap(pcm.floatChannelData?[0]), count: Int(pcm.frameLength) * 4))
            }
            XCTAssertEqual(actual, expectedPCM[track], file: file, line: line)
        }
    }
    func cleanup() async throws {
        guard !disposed else { return }
        readerGate.release(); service.cancel(); startTask?.cancel(); finishTask?.cancel()
        try await wait {
            guard self.startDone && self.finishDone else { return false }
            if !self.startRequested { return true }
            return try self.workerAbsent()
        }
        if let startTask { await startTask.value }
        if let finishTask { await finishTask.value }
        // A missing PID or unsettled original preserves the entire authored
        // root. Absence here is not a claim of natural exit/reap under Stop.
        try FileManager.default.removeItem(at: root); disposed = true
    }
    private static let worker = #"""
import json,os,select,struct,sys,time
from pathlib import Path
root=Path(sys.argv[1]);mode=sys.argv[2]
(root/'pid').write_text(str(os.getpid()))
def marker(name,value):
    (root/name).write_text(json.dumps(value))
def raw(data):
    view=memoryview(data)
    while view:
        n=os.write(1,view);view=view[n:]
def read(n):
    data=b''
    while len(data)<n:
        part=sys.stdin.buffer.read(n-len(data))
        if not part: raise EOFError('authored stdin ended')
        data+=part
    return data
def line(value): return json.dumps(value,separators=(',',':')).encode()+b'\n'
# Short genuine ready on a still-open pipe; never pad to disguise a blocked read.
if mode=='fragmented': raw(b'{"ty');raw(b'pe":"ready"}\n')
else: raw(line({'type':'ready'}))
packets=[]
while True:
    n=struct.unpack('<I',read(4))[0]
    if n==0: break
    h=json.loads(read(n));read(h['length']);packets.append(h)
if mode=='overflow':
    payload=line({'type':'ack'})*180000
    os.set_blocking(1,False)
    offset=0;blocked=None;end=time.monotonic()+6;backpressure=False
    while offset<len(payload):
        try:
            offset+=os.write(1,payload[offset:offset+65536]);blocked=None
        except BlockingIOError:
            now=time.monotonic()
            if blocked is None: blocked=now
            if now-blocked>=0.25:
                backpressure=True;break
            select.select([],[1],[],min(0.05,max(0,end-now)))
        if time.monotonic()>=end: break
    marker('burst',{'requestedBytes':len(payload),'writtenBytes':offset,'backpressure':backpressure,'packets':len(packets)})
else:
    rows=[]
    for h in packets:
        finish=h['start']+h['length']/64000
        row={'type':'spans','track':h['track'],'through':finish,
             'spans':[{'start':h['start'],'end':finish,'speaker':0 if h['track']=='mic' else 1}]}
        if mode=='fragmented' and not rows:
            row['padding']='x'*32768 # ignored root metadata; actual valid line spans multiple16KiB chunks
            encoded=line(row)
            assert 16384<len(encoded)<262144
            marker('fragmented-line',{'bytes':len(encoded)})
        rows.append(line(row))
    if mode=='fragmented':
        raw(b''.join(rows[:-1]))
        tail=rows[-1];cut=len(tail)//2;raw(tail[:cut]);raw(tail[cut:])
        raw(line({'type':'closed'}))
    elif mode.startswith('terminal-'):
        terminal=line({'type':'closed'})
        suffix=b''
        if mode=='terminal-fragmented':
            terminal=line({'type':'closed','padding':'x'*32768})
            assert 16384<len(terminal)<262144
            marker('terminal-line',{'bytes':len(terminal)})
            raw(b''.join(rows))
            cut=len(terminal)//2;raw(terminal[:cut]);raw(terminal[cut:])
        else:
            if mode=='terminal-spans':
                # Actual clock-bound last0.5ms span is accepted by the existing
                # label layer; only its POST-terminal position is invalid.
                end=max(h['start']+h['length']/64000 for h in packets if h['track']=='mic')
                suffix=line({'type':'spans','track':'mic','through':end,
                             'spans':[{'start':end-0.0005,'end':end,'speaker':7}]})
            elif mode=='terminal-ack': suffix=line({'type':'ack'})
            elif mode=='terminal-duplicate': suffix=line({'type':'closed'})
            elif mode=='terminal-partial': suffix=b'{"type":"spans"'
            else: raise ValueError('Unknown authored terminal mode')
            raw(b''.join(rows)+terminal+suffix)
    else:
        raw(b''.join(rows)+(b'' if mode=='missing-closed' else line({'type':'closed'})))
    marker('output-complete',{'packets':len(packets),'closed':mode!='missing-closed'})
"""#
}
private enum SpeakerOutputFailure: Error { case timeout, state }
