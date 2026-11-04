import XCTest
import Foundation
import Darwin
@testable import VoiceAudio

@MainActor final class LocalDictationRetirementTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("direct-dictation-retirement-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let script = """
        import json,os,signal,struct,sys,time
        root,mode,prior=sys.argv[1:4]
        signal.signal(signal.SIGTERM,lambda *_:os._exit(0))
        def marker(name):
            with open(os.path.join(root,name),'w') as f:f.write('observed')
        def emit(kind,text=''):
            print(json.dumps(dict(type=kind,text=text)),flush=True)
        def read(size):
            value=b''
            while len(value)<size:
                piece=sys.stdin.buffer.read(size-len(value))
                if not piece:raise EOFError()
                value+=piece
            return value
        with open(os.path.join(root,'process.tmp'),'w') as f:json.dump(dict(pid=os.getpid(),priorReturned=not prior or os.path.exists(prior)),f)
        os.replace(os.path.join(root,'process.tmp'),os.path.join(root,'process.json'))
        if mode=='opening':
            while not os.path.exists(os.path.join(root,'ready')):time.sleep(0.01)
        emit('ready')
        while True:
            size=struct.unpack('<I',read(4))[0]
            if size==0:
                if mode=='finishing':
                    marker('finishing')
                    while True:time.sleep(0.01)
                emit('final','Authored final text.')
                break
            if mode=='blocked':
                marker('blocked')
                while True:time.sleep(0.01)
            data=read(size)
            assert size%4==0 and all(value==0 for value in data)
            emit('partial','Authored partial text.')
        """
        try script.write(to: root.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        return root
    }
    private func arguments(_ root: URL, mode: String = "normal", prior: URL? = nil) -> [String] {
        ["-u", root.appendingPathComponent("worker.py").path, root.path, mode, prior?.path ?? ""]
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "LocalDictationRetirementTests", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func pid(_ root: URL) throws -> pid_t {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("process.json"))) as? [String: Any]
        let integer = try XCTUnwrap(value?["pid"] as? Int)
        return try XCTUnwrap(pid_t(exactly: integer))
    }
    private func assertReaped(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        let present = kill(pid, 0), presenceError = errno
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG), waitError = errno
        XCTAssertEqual(present, -1, "Original dictation helper remains present", file: file, line: line)
        XCTAssertEqual(presenceError, ESRCH, file: file, line: line)
        XCTAssertEqual(result, -1, "Original Foundation Process wait did not reap its child", file: file, line: line)
        XCTAssertEqual(waitError, ECHILD, file: file, line: line)
    }
    func testNormalPartialFinalAndLogCleanupFollowOriginalRetirement() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let stream = try LocalDictationStream(); defer { stream.cancel() }
        let log = stream.transcriptLogURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root))
        let originalPID = try pid(root)
        let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let audio = Data(repeating: 0, count: 4096)
        var partials: [String] = [], failures: [String] = []
        stream.observe(audio: { audio }, partial: { partials.append($0) }, failure: { failures.append($0) })
        try await until { partials.contains("Authored partial text.") }
        let text = try await stream.finish(audio)
        XCTAssertEqual(text, "Authored final text.")
        let original = try XCTUnwrap(stream.retirementCompletion())
        await original.value
        assertReaped(originalPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertTrue(failures.isEmpty)
    }
    func testStopWhileOpeningJoinsActualStartBeforeRemovingItsLog() async throws {
        let root = try fixture(), nextRoot = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: nextRoot) }
        let stream = try LocalDictationStream(), next = try LocalDictationStream()
        defer { stream.cancel(); next.cancel() }
        let log = stream.transcriptLogURL
        let returned = root.appendingPathComponent("start-returned")
        var startReturned = false
        let start = Task {
            defer { startReturned = true; try? Data("returned".utf8).write(to: returned, options: .atomic) }
            try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root, mode: "opening"))
        }
        try await until { FileManager.default.fileExists(atPath: root.appendingPathComponent("process.json").path) }
        let originalPID = try pid(root)
        stream.cancel(); stream.cancel()
        let original = try XCTUnwrap(stream.retirementCompletion())
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        let successor = Task {
            try await next.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(nextRoot, prior: returned))
        }
        do { try await start.value; XCTFail("Stopped opening returned ready") } catch {}
        await original.value
        XCTAssertTrue(startReturned); assertReaped(originalPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        try await successor.value
        let nextInfo = try JSONSerialization.jsonObject(with: Data(contentsOf: nextRoot.appendingPathComponent("process.json"))) as? [String: Any]
        XCTAssertEqual(nextInfo?["priorReturned"] as? Bool, true)
        let nextPID = try pid(nextRoot)
        await next.cancelAndWait(); assertReaped(nextPID)
    }
    func testStopDuringPendingPumpWriteAndFinishJoinsAllOriginalWork() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let stream = try LocalDictationStream(); defer { stream.cancel() }
        try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root, mode: "blocked"))
        let originalPID = try pid(root), log = stream.transcriptLogURL
        let audio = Data(repeating: 0, count: 2_000_000)
        var partials: [String] = [], failures: [String] = []
        stream.observe(audio: { audio }, partial: { partials.append($0) }, failure: { failures.append($0) })
        try await until { FileManager.default.fileExists(atPath: root.appendingPathComponent("blocked").path) && stream.writeInProgress }
        let finish = Task { try await stream.finish(audio) }
        try await until { stream.finishInProgress && stream.writeInProgress }
        stream.cancel()
        let original = try XCTUnwrap(stream.retirementCompletion())
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        do { _ = try await finish.value; XCTFail("Stopped finish returned text") } catch {}
        await original.value
        assertReaped(originalPID)
        XCTAssertFalse(stream.writeInProgress); XCTAssertFalse(stream.finishInProgress)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertTrue(partials.isEmpty); XCTAssertTrue(failures.isEmpty)
    }
    func testRepeatedOldStopDoesNotRemoveSuccessorLogOrStopItsProcess() async throws {
        let firstRoot = try fixture(), secondRoot = try fixture()
        defer { try? FileManager.default.removeItem(at: firstRoot); try? FileManager.default.removeItem(at: secondRoot) }
        let first = try LocalDictationStream(), second = try LocalDictationStream()
        defer { first.cancel(); second.cancel() }
        try await first.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(firstRoot))
        let firstPID = try pid(firstRoot), firstLog = first.transcriptLogURL
        await first.cancelAndWait(); assertReaped(firstPID)
        try await second.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(secondRoot))
        let secondPID = try pid(secondRoot), secondLog = second.transcriptLogURL
        XCTAssertNotEqual(firstLog, secondLog)
        first.cancel(); first.cancel(); await first.cancelAndWait()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstLog.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondLog.path))
        XCTAssertEqual(kill(secondPID, 0), 0)
        let text = try await second.finish(Data(repeating: 0, count: 4096))
        XCTAssertEqual(text, "Authored final text.")
        await second.cancelAndWait(); assertReaped(secondPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondLog.path))
    }
    func testCallerCancellationWhileFinishingRetiresActualProcessAndLog() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let stream = try LocalDictationStream(); defer { stream.cancel() }
        try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root, mode: "finishing"))
        let originalPID = try pid(root), log = stream.transcriptLogURL
        let finish = Task { try await stream.finish(Data(repeating: 0, count: 4096)) }
        try await until { FileManager.default.fileExists(atPath: root.appendingPathComponent("finishing").path) && stream.finishInProgress }
        finish.cancel()
        do { _ = try await finish.value; XCTFail("Cancelled finish returned text") }
        catch { XCTAssertTrue(error is CancellationError) }
        let original = try XCTUnwrap(stream.retirementCompletion())
        await original.value; assertReaped(originalPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }
    func testNeverStartedCancellationHasNoFileOrUnlaunchedProcessWait() async throws {
        let stream = try LocalDictationStream(), log = stream.transcriptLogURL
        await stream.cancelAndWait()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        do {
            try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [])
            XCTFail("Stopped instance launched new work")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }
    func testFailedUnlaunchedWorkerRetiresItsAllocatedLogWithoutProcessWait() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let stream = try LocalDictationStream(); defer { stream.cancel() }
        let log = stream.transcriptLogURL
        do {
            try await stream.startPreparedWorker(executable: root.appendingPathComponent("missing-executable"), arguments: [])
            XCTFail("Missing helper launched")
        } catch {}
        let original = try XCTUnwrap(stream.retirementCompletion())
        await original.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("process.json").path))
    }
}
