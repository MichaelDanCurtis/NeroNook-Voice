import XCTest
import Foundation
import Darwin
import ModuleCore
@testable import VoiceAudio

/// Real prepared-worker pipes, zero PCM and authored records. No capture,
/// model verification/loading, analyzer preparation, default stores or app.
@MainActor final class MeetingEarlyClosedTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-close-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let script = """
        import json,os,signal,struct,sys,time
        mode,root=sys.argv[1:3]
        def emit(value):
            os.write(1,json.dumps(value).encode()+b'\\n')
        def mark(name):
            with open(os.path.join(root,name),'wb') as f:f.write(b'authored')
        def wait(name):
            until=time.monotonic()+6
            while not os.path.exists(os.path.join(root,name)):
                if time.monotonic()>=until:os._exit(9)
                time.sleep(0.005)
        def exact(count):
            out=b''
            while len(out)<count:
                part=sys.stdin.buffer.read(count-len(out))
                if not part:return None
                out+=part
            return out
        signal.signal(signal.SIGTERM,lambda *_:os._exit(0))
        with open(os.path.join(root,'pid.json'),'w') as f:json.dump(os.getpid(),f)
        emit(dict(type='ready',version=2))
        if mode=='early':
            wait('emit-early')
            emit(dict(type='closed'))
            os.close(1)
            # Keep stdin/process original alive after real stdout EOF. Merely
            # observing producer marker/flush is not the test's synchronization.
            while sys.stdin.buffer.read(4096):pass
            os._exit(0)
        header=exact(4)
        if header!=struct.pack('<I',0):os._exit(8)
        mark('end-header-observed')
        closed=json.dumps(dict(type='closed')).encode()+b'\\n'
        if mode=='split':
            os.write(1,closed[:5]);mark('fragment-written');wait('finish-fragment')
            os.write(1,closed[5:])
        elif mode=='coalesced':
            os.write(1,json.dumps(dict(type='ack')).encode()+b'\\n'+closed)
        elif mode=='tail':os.write(1,closed[:-1])
        elif mode=='postclosed':os.write(1,closed+json.dumps(dict(type='ack')).encode()+b'\\n')
        elif mode=='malformed':os.write(1,b'not-json\\n')
        else:os.write(1,closed)
        """
        try script.write(to: root.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        return root
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw VoiceProblem.message("Authored worker did not reach its fixture gate") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func start(_ service: MeetingLiveTranscriber, root: URL, mode: String,
        updates: @escaping (MeetingLiveUpdate) -> Void = { _ in }, failure: @escaping (String) -> Void) async throws {
        try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [root.appendingPathComponent("worker.py").path, mode, root.path],
            update: updates, failure: failure)
    }
    private func assertReaped(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let raw = try JSONDecoder().decode(Int32.self, from: Data(contentsOf: root.appendingPathComponent("pid.json")))
        let present = kill(raw, 0), presenceError = errno
        var status: Int32 = 0
        let waited = waitpid(raw, &status, WNOHANG), waitError = errno
        XCTAssertEqual(present, -1, file: file, line: line); XCTAssertEqual(presenceError, ESRCH, file: file, line: line)
        XCTAssertEqual(waited, -1, file: file, line: line); XCTAssertEqual(waitError, ECHILD, file: file, line: line)
    }
    func testEarlyCloseIsObservedBeforeInputEndAndCannotFinishSuccessfully() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = MeetingLiveTranscriber()
        var failures: [String] = [], updates: [MeetingLiveUpdate] = []
        do {
            try await start(service, root: root, mode: "early", updates: { updates.append($0) }, failure: { failures.append($0) })
            let originalReader = try XCTUnwrap(service.originalWorkerOutputCompletion())
            try Data().write(to: root.appendingPathComponent("emit-early"))
            // This actual consumer original processes all data/EOF before
            // returning. No sleep or producer marker stands in for observation.
            await originalReader.value
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(failures.first?.contains("closed before its input ended") == true)
            var succeeded = false
            do { try await service.finish(); succeeded = true } catch { }
            XCTAssertFalse(succeeded, "An already observed early close cannot satisfy normal finish")
            await service.cancelAndWait()
            XCTAssertTrue(updates.isEmpty)
            try assertReaped(root)
        } catch { await service.cancelAndWait(); throw error }
    }
    func testClosedAfterOriginalEndHeaderFinishesNormally() async throws {
        try await normalFinish(mode: "normal")
    }
    func testCoalescedAckAndClosedAfterEndRemainValid() async throws {
        try await normalFinish(mode: "coalesced")
    }
    private func normalFinish(mode: String) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = MeetingLiveTranscriber(); var failures: [String] = []
        do {
            try await start(service, root: root, mode: mode, failure: { failures.append($0) })
            try await service.finish()
            await service.cancelAndWait()
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("end-header-observed").path))
            XCTAssertTrue(failures.isEmpty)
            try assertReaped(root)
        } catch { await service.cancelAndWait(); throw error }
    }
    func testSplitClosedFrameCompletesThroughActualReader() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = MeetingLiveTranscriber(); var failures: [String] = []
        var finish: Task<Void, Error>?
        do {
            try await start(service, root: root, mode: "split", failure: { failures.append($0) })
            let originalReader = try XCTUnwrap(service.originalWorkerOutputCompletion())
            let originalFinish = Task { try await service.finish() }; finish = originalFinish
            try await until { FileManager.default.fileExists(atPath: root.appendingPathComponent("fragment-written").path) }
            try Data().write(to: root.appendingPathComponent("finish-fragment"))
            try await originalFinish.value
            await originalReader.value
            await service.cancelAndWait()
            XCTAssertTrue(failures.isEmpty)
            try assertReaped(root)
        } catch {
            await service.cancelAndWait(); _ = try? await finish?.value
            throw error
        }
    }
    func testIncompleteClosedTailRemainsFailureAndJoinsOriginals() async throws {
        try await invalidFinish(mode: "tail", expected: "incomplete response")
    }
    func testPostClosedOutputRemainsFailureAndJoinsOriginals() async throws {
        try await invalidFinish(mode: "postclosed", expected: "after closing")
    }
    func testMalformedOutputRemainsFailureAndJoinsOriginals() async throws {
        try await invalidFinish(mode: "malformed", expected: nil)
    }
    private func invalidFinish(mode: String, expected: String?) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = MeetingLiveTranscriber(); var failures: [String] = []
        do {
            try await start(service, root: root, mode: mode, failure: { failures.append($0) })
            var succeeded = false
            do { try await service.finish(); succeeded = true } catch { }
            await service.cancelAndWait()
            XCTAssertFalse(succeeded)
            XCTAssertEqual(failures.count, 1)
            if let expected { XCTAssertTrue(failures.first?.contains(expected) == true) }
            try assertReaped(root)
        } catch { await service.cancelAndWait(); throw error }
    }
}
