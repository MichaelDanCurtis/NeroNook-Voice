import XCTest
import Foundation
import AVFoundation
import Darwin
import ModuleCore
@testable import VoiceAudio

/// Real authored protocol workers, no ASR model, capture or readiness hook.
/// The actual model worker settles both tracks, emits closed last and returns.
@MainActor final class MeetingASROutputTests: XCTestCase {
    func testClosedWithUnterminatedTrailingJSONFailsAndPreservesAudio() async throws {
        let f = try await fixture("trailing-partial")
        try await f.start(); f.beginFinish(); try await f.joinFinish()
        f.assertFailure(); f.assertOrderedFinals(); try f.assertAudioPreserved()
    }
    func testClosedWithCompleteAckFailsAndPreservesAudio() async throws {
        let f = try await fixture("trailing-ack")
        try await f.start(); f.beginFinish(); try await f.joinFinish()
        f.assertFailure(); f.assertOrderedFinals(); try f.assertAudioPreserved()
    }
    func testEOFMissingClosedFailsAndPreservesAudio() async throws {
        let f = try await fixture("missing-closed")
        try await f.start(); f.beginFinish(); try await f.joinFinish()
        f.assertFailure(); f.assertOrderedFinals(); try f.assertAudioPreserved()
    }
    func testCompleteOrderedUnicodeRoomCallFinalsThenClosedFinishSuccessfully() async throws {
        let f = try await fixture("complete")
        try await f.start(); f.beginFinish(); try await f.joinFinish()
        XCTAssertTrue(f.finishSucceeded); XCTAssertNil(f.finishError); XCTAssertTrue(f.failures.isEmpty)
        f.assertOrderedFinals(); try f.assertAudioPreserved()
        try await f.wait { try f.workerAbsent() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("output-written").path))
    }
    func testStopInFirstCallbackCannotPublishLaterCoalescedUpdates() async throws {
        let f = try await fixture("complete")
        f.cancelOnFirst = true
        try await f.start(); f.beginFinish(); try await f.joinFinish()
        try await f.wait { try f.workerAbsent() }
        XCTAssertEqual(f.updates.count, 1); XCTAssertEqual(f.updates.first?.track, "mic")
        XCTAssertEqual(f.updates.first?.text, ASROutputFixture.texts[0])
        XCTAssertTrue(f.failures.isEmpty, "An explicit Stop does not report a new optional-worker failure")
        XCTAssertFalse(f.finishSucceeded); try f.assertAudioPreserved()
    }
    func testFinalFrameAfterClosedFailsWithoutPublishingLateWords() async throws {
        let f = try await fixture("trailing-final")
        try await f.start(); f.beginFinish(); try await f.joinFinish()
        f.assertFailure(); f.assertOrderedFinals()
        XCTAssertFalse(f.updates.contains { $0.text == "INVALID_LATE_WORDS" })
        try f.assertAudioPreserved()
    }
    private func fixture(_ mode: String) async throws -> ASROutputFixture {
        let f = try ASROutputFixture(mode: mode)
        addTeardownBlock { @MainActor in
            do { try await f.cleanup() }
            catch { XCTFail("Original ASR worker/task unsettled; authored root preserved at \(f.root.path): \(error)") }
        }
        try await f.saveAudio(); return f
    }
}

@MainActor private final class ASROutputFixture {
    let root, script: URL
    let feed = MeetingLiveAudioFeed(bufferingLimit: 512)
    let service: MeetingLiveTranscriber
    let store: MeetingStore
    private var meeting: Meeting
    private let mode: String
    private var expectedPCM: [String: Data] = [:]
    private var savedPID: Int32?
    private var startRequested = false
    private var startTask: Task<Void, Never>?
    private var startDone = true
    private var startError: Error?
    private var finishTask: Task<Void, Never>?
    private var finishDone = true
    private(set) var finishSucceeded = false
    private(set) var finishError: Error?
    private(set) var updates: [MeetingLiveUpdate] = []
    private(set) var failures: [String] = []
    var cancelOnFirst = false
    private var disposed = false
    static let texts = ["Room café 🌿", "Call 你好", "Room café again", "Call 再见 🌙"]

    init(mode: String) throws {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("NeroASROutput-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let authoredRoot = root; var initialized = false
        defer { if !initialized { try? FileManager.default.removeItem(at: authoredRoot) } }
        script = root.appendingPathComponent("worker.py")
        try Data(Self.worker.utf8).write(to: script)
        store = try MeetingStore(root: root.appendingPathComponent("meetings"))
        meeting = Meeting(title: "Authored ASR output", source: "all", microphone: true)
        service = MeetingLiveTranscriber(feed: feed)
        self.mode = mode; initialized = true
    }
    func saveAudio() async throws {
        let writer = try MeetingAudioWriter(store: store, meeting: meeting, liveFeed: feed)
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
        meeting = try await writer.finish(state: "saved"); XCTAssertTrue(meeting.issue.isEmpty)
    }
    func start() async throws {
        guard !startRequested else { throw ASROutputFailure.state }
        startRequested = true; startDone = false
        let original = Task { @MainActor [self] in
            do {
                try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: ["-I", "-B", script.path, root.path, mode], update: { [self] value in
                        updates.append(value)
                        if cancelOnFirst && updates.count == 1 { service.cancel() }
                    }, failure: { [self] in failures.append($0) })
            } catch { startError = error }
            startDone = true
        }
        startTask = original
        try await wait { self.startDone }; await original.value
        if let startError { throw startError }
        try capturePID()
    }
    func beginFinish() {
        guard finishTask == nil else { XCTFail("Original finish cannot be replaced"); return }
        finishDone = false
        finishTask = Task { @MainActor [self] in
            do { try await service.finish(); finishSucceeded = true }
            catch { finishError = error }
            finishDone = true
        }
    }
    func joinFinish() async throws {
        try await wait { self.finishDone }
        if let finishTask { await finishTask.value }
    }
    func wait(_ condition: () throws -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while true {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ASROutputFailure.timeout }
            let matched = try condition()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ASROutputFailure.timeout }
            if matched { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func capturePID() throws {
        if savedPID != nil { return }
        let raw = try String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)
        guard let pid = Int32(raw), pid > 1 else { throw ASROutputFailure.state }
        savedPID = pid
    }
    func workerAbsent() throws -> Bool {
        try capturePID(); guard let savedPID else { throw ASROutputFailure.state }
        if kill(savedPID, 0) == 0 { return false }
        guard errno == ESRCH else { throw ASROutputFailure.state }; return true
    }
    func assertFailure(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(finishSucceeded, file: file, line: line)
        XCTAssertNotNil(finishError, file: file, line: line)
        XCTAssertFalse(failures.isEmpty, "Terminal corruption must be explicitly reported, not silently accepted", file: file, line: line)
    }
    func assertOrderedFinals(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(updates.count, 4, file: file, line: line)
        XCTAssertEqual(updates.map(\.track), ["mic", "system", "mic", "system"], file: file, line: line)
        XCTAssertTrue(updates.allSatisfy(\.final), file: file, line: line)
        XCTAssertEqual(updates.map { Data($0.text.utf8) }, Self.texts.map { Data($0.utf8) }, file: file, line: line)
        let starts = [0.0, 0.25, 0.064, 0.314], ends = [0.064, 0.314, 0.128, 0.378]
        for (index, update) in updates.enumerated() where index < 4 {
            XCTAssertEqual(update.start, starts[index], accuracy: 0.000001, file: file, line: line)
            XCTAssertEqual(update.end, ends[index], accuracy: 0.000001, file: file, line: line)
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
        service.cancel(); startTask?.cancel(); finishTask?.cancel()
        try await wait {
            guard self.startDone && self.finishDone else { return false }
            if !self.startRequested { return true }
            return try self.workerAbsent()
        }
        if let startTask { await startTask.value }
        if let finishTask { await finishTask.value }
        try FileManager.default.removeItem(at: root); disposed = true
    }
    private static let worker = #"""
import json,os,struct,sys
from pathlib import Path
root=Path(sys.argv[1]);mode=sys.argv[2]
(root/'pid').write_text(str(os.getpid()))
def raw(data):
    view=memoryview(data)
    while view:
        n=os.write(1,view);view=view[n:]
def line(value): return json.dumps(value,ensure_ascii=False,separators=(',',':')).encode('utf-8')+b'\n'
def read(n):
    data=b''
    while len(data)<n:
        part=sys.stdin.buffer.read(n-len(data))
        if not part: raise EOFError('authored framed stdin ended')
        data+=part
    return data
# Short ready on an open pipe, then the real ordered input pump must finish.
raw(line({'type':'ready','version':2}))
packets=[]
while True:
    n=struct.unpack('<I',read(4))[0]
    if n==0: break
    h=json.loads(read(n));read(h['length']);packets.append(h)
texts=['Room café 🌿','Call 你好','Room café again','Call 再见 🌙']
assert len(packets)==4
rows=[]
for h,text in zip(packets,texts):
    rows.append(line({'type':'final','track':h['track'],'start':h['start'],
                      'end':h['start']+h['length']/64000,'text':text}))
payload=b''.join(rows)
if mode!='missing-closed': payload+=line({'type':'closed'})
if mode=='trailing-partial': payload+=b'{"type":"ack"'
elif mode=='trailing-ack': payload+=line({'type':'ack'})
elif mode=='trailing-final': payload+=line({'type':'final','track':'mic','start':0.128,'end':0.129,'text':'INVALID_LATE_WORDS'})
# One finite coalesced write request. Correctness cannot depend on how the OS
# partitions it: finish must account for the actual reader and its terminal EOF.
raw(payload)
(root/'output-written').write_text(json.dumps({'mode':mode,'packets':len(packets),'bytes':len(payload)}))
"""#
}
private enum ASROutputFailure: Error { case timeout, state }
