import XCTest
import Foundation
import ModuleCore
@testable import VoiceAudio

/// Authored PCM bytes are consumed only by a protocol stub, never an ASR model.
/// It deliberately combines old-final / ack / next-partial in one stdout write.
final class ConversationBoundaryTests: XCTestCase {
    private func fixture() throws -> (URL, URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceBoundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("worker.py"), marker = folder.appendingPathComponent("commit-seen")
        try Data(Self.worker.utf8).write(to: script)
        return (folder, script, marker)
    }
    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Authored worker did not reach its expected protocol point")
        throw VoiceProblem.message("Fixture timed out")
    }
    @MainActor func testAcknowledgedBoundaryRetiresAtomicallyBeforeNextPartialAndUsesProcessedClock() async throws {
        let (_, script, marker) = try fixture(), service = MeetingLiveTranscriber()
        defer { service.cancel() }
        var gate = ConversationTurn(), committed = "", acknowledged = -1.0, failure = ""
        try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, marker.path]) { value in
            try gate.receive(value, now: value.end)
        } failure: { failure = $0 }
        service.feed.append(.init(track: "mic", start: 0, pcm: Data(repeating: 0, count: 64_000)))
        try await waitFor { gate.text == "First thought" }
        let pending = Task { try await service.commit { through in
            acknowledged = through
            committed = gate.commit(through: through)
        } }
        try await waitFor { FileManager.default.fileExists(atPath: marker.path) }
        // Capture is now a full second ahead of the acknowledged input. The
        // next partial must enter a retired gate even if the caller is asleep.
        service.feed.append(.init(track: "mic", start: 1, pcm: Data(repeating: 0, count: 64_000)))
        try await pending.value
        try await waitFor { gate.text == "Second thought" }
        XCTAssertEqual(acknowledged, 1)
        XCTAssertEqual(committed, "First thought.")
        XCTAssertEqual(gate.text, "Second thought")
        XCTAssertTrue(failure.isEmpty, failure)
        try await service.finish()
    }
    @MainActor func testCancelledBoundaryReturnsPromptlyWithoutCallingItsHandoff() async throws {
        let (_, script, marker) = try fixture(), service = MeetingLiveTranscriber()
        defer { service.cancel() }
        var called = false
        try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, marker.path], update: { _ in }, failure: { _ in })
        service.feed.append(.init(track: "mic", start: 0, pcm: Data(repeating: 0, count: 64_000)))
        let pending = Task { try await service.commit { _ in called = true } }
        try await waitFor { FileManager.default.fileExists(atPath: marker.path) }
        let start = Date(); pending.cancel()
        do { try await pending.value; XCTFail("Cancelled boundary succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertFalse(called)
    }
    @MainActor func testWorkerCannotAcknowledgeUnprocessedAudio() async throws {
        let (_, script, marker) = try fixture(), service = MeetingLiveTranscriber()
        defer { service.cancel() }
        var failure = "", called = false
        try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [script.path, marker.path, "bad"], update: { _ in }, failure: { failure = $0 })
        service.feed.append(.init(track: "mic", start: 0, pcm: Data(repeating: 0, count: 64_000)))
        let pending = Task { try await service.commit { _ in called = true } }
        try await waitFor { FileManager.default.fileExists(atPath: marker.path) }
        service.feed.append(.init(track: "mic", start: 1, pcm: Data(repeating: 0, count: 64_000)))
        do { try await pending.value; XCTFail("Invalid acknowledgement succeeded") } catch {}
        XCTAssertFalse(called)
        XCTAssertTrue(failure.contains("invalid boundary"), failure)
    }
    func testAudioAndBoundariesShareOneFIFO() async throws {
        let feed = MeetingLiveAudioFeed(), id = UUID()
        feed.append(.init(track: "mic", start: 0, pcm: Data(repeating: 0, count: 640)))
        XCTAssertTrue(feed.boundary(id))
        feed.append(.init(track: "mic", start: 0.01, pcm: Data(repeating: 0, count: 640)))
        feed.finish()
        var order: [String] = []
        for try await event in feed.stream {
            feed.consumed(event)
            switch event {
            case .audio(let packet): order.append(String(packet.start))
            case .boundary(let value): XCTAssertEqual(value, id); order.append("boundary")
            }
        }
        XCTAssertEqual(order, ["0.0", "boundary", "0.01"])
    }
    private static let worker = #"""
import sys, struct, json
from pathlib import Path
def read(n):
    result = b''
    while len(result) < n:
        chunk = sys.stdin.buffer.read(n-len(result))
        if not chunk: raise EOFError()
        result += chunk
    return result
def emit(*values):
    sys.stdout.buffer.write(b''.join(json.dumps(v).encode()+b'\n' for v in values))
    sys.stdout.buffer.flush()
emit({'type':'ready','version':2})
through = 0.0
pending = None
while True:
    count = struct.unpack('<I',read(4))[0]
    if count == 0: break
    header = json.loads(read(count))
    if header.get('command') == 'commit':
        pending = (header['id'],through)
        Path(sys.argv[1]).touch()
        continue
    read(header['length'])
    through = header['start'] + header['length']/64000.0
    if pending:
        id, boundary = pending
        ack = boundary + (0.5 if len(sys.argv) > 2 else 0)
        emit({'type':'final','track':'mic','start':0,'end':boundary,'text':'First thought.'},
             {'type':'committed','id':id,'through':ack},
             {'type':'partial','track':'mic','start':boundary,'end':through,'text':'Second thought'})
        pending = None
    else:
        emit({'type':'partial','track':'mic','start':0,'end':through,'text':'First thought'})
    emit({'type':'ack'})
emit({'type':'closed'})
"""#
}
