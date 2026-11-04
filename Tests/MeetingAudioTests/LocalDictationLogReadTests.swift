import XCTest
import Foundation
import Dispatch
import Darwin
@testable import VoiceAudio

/// Holds the actual opened reader, without supplying bytes or parser results.
/// The timeout only releases a broken test; a passing case must never use it.
private final class DictationReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var armed: Bool?
    private var enteredValue = false, heldValue = false, timedOutValue = false

    func arm(requireFinal: Bool) {
        lock.lock(); defer { lock.unlock() }
        armed = requireFinal
    }
    func checkpoint(requireFinal: Bool) {
        lock.lock()
        guard armed == requireFinal, !enteredValue else { lock.unlock(); return }
        armed = nil; enteredValue = true; heldValue = true
        lock.unlock()
        let result = release.wait(timeout: .now() + 5)
        lock.lock(); timedOutValue = result == .timedOut; heldValue = false; lock.unlock()
    }
    func open() { release.signal() }
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return enteredValue }
    var held: Bool { lock.lock(); defer { lock.unlock() }; return heldValue }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOutValue }
}

@MainActor final class LocalDictationLogReadTests: XCTestCase {
    private let finalText = "Reader café 🌿 final."

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-log-read-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = """
        import json,os,signal,struct,sys
        root,prior=sys.argv[1:3]
        signal.signal(signal.SIGTERM,lambda *_:os._exit(0))
        def marker(name):
            with open(os.path.join(root,name),'w') as f:f.write('observed')
        def emit(kind,text=''):
            print(json.dumps(dict(type=kind,text=text),ensure_ascii=False),flush=True)
        def read(size):
            value=b''
            while len(value)<size:
                piece=sys.stdin.buffer.read(size-len(value))
                if not piece:raise EOFError()
                value+=piece
            return value
        with open(os.path.join(root,'pid.tmp'),'w') as f:
            json.dump(dict(pid=os.getpid(),priorReturned=not prior or os.path.exists(prior)),f)
        os.replace(os.path.join(root,'pid.tmp'),os.path.join(root,'pid.json'))
        emit('ready')
        while True:
            size=struct.unpack('<I',read(4))[0]
            if size==0:
                marker('ending')
                emit('final','Reader café 🌿 final.')
                marker('final-emitted')
                break
            data=read(size)
            assert size%4==0 and all(value==0 for value in data)
            emit('partial','Reader café 🌿 partial.')
            marker('partial-emitted')
        """
        try script.write(to: root.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        return root
    }
    private func arguments(_ root: URL, prior: URL? = nil) -> [String] {
        ["-u", root.appendingPathComponent("worker.py").path, root.path, prior?.path ?? ""]
    }
    private func exists(_ root: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }
    private func until(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < end else { throw NSError(domain: "LocalDictationLogReadTests", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func pid(_ root: URL) throws -> pid_t {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("pid.json"))) as? [String: Any]
        return try XCTUnwrap(pid_t(exactly: XCTUnwrap(value?["pid"] as? Int)))
    }
    private func assertReaped(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        let present = kill(pid, 0), presenceError = errno
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG), waitError = errno
        XCTAssertEqual(present, -1, "Original helper remains present", file: file, line: line)
        XCTAssertEqual(presenceError, ESRCH, file: file, line: line)
        XCTAssertEqual(waited, -1, "Original Foundation Process wait did not reap its helper", file: file, line: line)
        XCTAssertEqual(waitError, ECHILD, file: file, line: line)
    }
    private func pulseWhileHeld(_ gate: DictationReadGate, file: StaticString = #filePath, line: UInt = #line) async {
        var heldWhenActorRan = false
        let pulse = Task { @MainActor in heldWhenActorRan = gate.held }
        await pulse.value
        XCTAssertTrue(heldWhenActorRan, "MainActor job did not run while the actual reader was held", file: file, line: line)
        XCTAssertFalse(gate.timedOut, "Reader was released by the failure watchdog", file: file, line: line)
    }

    func testStartupReadYieldsMainActorAndStopRetainsOriginalReadLogAndSuccessorBarrier() async throws {
        let root = try fixture(), nextRoot = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: nextRoot) }
        let gate = DictationReadGate(); gate.arm(requireFinal: false)
        let stream = try LocalDictationStream(readCheckpoint: { gate.checkpoint(requireFinal: $0) })
        let next = try LocalDictationStream()
        defer { gate.open(); stream.cancel(); next.cancel() }
        let log = stream.transcriptLogURL, nextLog = next.transcriptLogURL
        let returned = root.appendingPathComponent("original-start-returned")
        var startReturned = false
        let start = Task {
            defer { startReturned = true; try? Data("returned".utf8).write(to: returned, options: .atomic) }
            try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root))
        }
        try await until { gate.entered && exists(root, "pid.json") }
        let originalPID = try pid(root)
        await pulseWhileHeld(gate)
        stream.cancel(); stream.cancel()
        let original = try XCTUnwrap(stream.retirementCompletion())
        var monitorStarted = false, retired = false
        let monitor = Task { monitorStarted = true; await original.value; retired = true }
        try await until { monitorStarted }
        XCTAssertTrue(gate.held); XCTAssertFalse(retired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        var successorEntered = false
        let successor = Task {
            successorEntered = true
            try await next.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(nextRoot, prior: returned))
        }
        try await until { successorEntered }
        await pulseWhileHeld(gate)
        XCTAssertFalse(exists(nextRoot, "pid.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nextLog.path))
        gate.open()
        do { try await start.value; XCTFail("Stopped startup returned ready") }
        catch { XCTAssertTrue(error is CancellationError) }
        await original.value; await monitor.value
        XCTAssertTrue(startReturned); XCTAssertTrue(retired); XCTAssertFalse(gate.timedOut)
        assertReaped(originalPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        try await successor.value
        let nextInfo = try JSONSerialization.jsonObject(with: Data(contentsOf: nextRoot.appendingPathComponent("pid.json"))) as? [String: Any]
        XCTAssertEqual(nextInfo?["priorReturned"] as? Bool, true)
        let nextPID = try pid(nextRoot)
        stream.cancel(); stream.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: nextLog.path))
        XCTAssertEqual(kill(nextPID, 0), 0)
        let text = try await next.finish(Data(repeating: 0, count: 4096))
        XCTAssertEqual(text, finalText)
        await next.cancelAndWait(); assertReaped(nextPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nextLog.path))
    }

    func testPollingReadCannotPublishPartialOrFailureAfterStop() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = DictationReadGate()
        let stream = try LocalDictationStream(readCheckpoint: { gate.checkpoint(requireFinal: $0) })
        defer { gate.open(); stream.cancel() }
        try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root))
        let originalPID = try pid(root), log = stream.transcriptLogURL
        gate.arm(requireFinal: false)
        let audio = Data(repeating: 0, count: 4096)
        var partials: [String] = [], failures: [String] = []
        stream.observe(audio: { audio }, partial: { partials.append($0) }, failure: { failures.append($0) })
        try await until { gate.entered && exists(root, "partial-emitted") }
        await pulseWhileHeld(gate)
        stream.cancel()
        let original = try XCTUnwrap(stream.retirementCompletion())
        var monitorStarted = false, retired = false
        let monitor = Task { monitorStarted = true; await original.value; retired = true }
        try await until { monitorStarted }
        await pulseWhileHeld(gate)
        XCTAssertFalse(retired); XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        XCTAssertTrue(partials.isEmpty); XCTAssertTrue(failures.isEmpty)
        gate.open(); await original.value; await monitor.value
        XCTAssertTrue(retired); XCTAssertFalse(gate.timedOut)
        XCTAssertTrue(partials.isEmpty); XCTAssertTrue(failures.isEmpty)
        assertReaped(originalPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testFinishJoinsOriginalPollingReadWithoutCancellingTheStream() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = DictationReadGate()
        let stream = try LocalDictationStream(readCheckpoint: { gate.checkpoint(requireFinal: $0) })
        defer { gate.open(); stream.cancel() }
        try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root))
        let originalPID = try pid(root), log = stream.transcriptLogURL
        gate.arm(requireFinal: false)
        let audio = Data(repeating: 0, count: 4096)
        var failures: [String] = []
        stream.observe(audio: { audio }, partial: { _ in }, failure: { failures.append($0) })
        try await until { gate.entered && exists(root, "partial-emitted") }
        var finishReturned = false
        let finish = Task { defer { finishReturned = true }; return try await stream.finish(audio) }
        try await until { stream.finishInProgress }
        await pulseWhileHeld(gate)
        XCTAssertFalse(finishReturned)
        XCTAssertFalse(exists(root, "ending"), "End-of-input overtook the original pumping read")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        gate.open()
        let text = try await finish.value
        XCTAssertEqual(text, finalText); XCTAssertTrue(finishReturned); XCTAssertFalse(gate.timedOut)
        XCTAssertTrue(failures.isEmpty)
        let original = try XCTUnwrap(stream.retirementCompletion())
        await original.value; assertReaped(originalPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testCallerCancellationDuringFinalReadRetainsLogUntilActualReadReturns() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = DictationReadGate(); gate.arm(requireFinal: true)
        let stream = try LocalDictationStream(readCheckpoint: { gate.checkpoint(requireFinal: $0) })
        defer { gate.open(); stream.cancel() }
        try await stream.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root))
        let originalPID = try pid(root), log = stream.transcriptLogURL
        var finishReturned = false
        let finish = Task { defer { finishReturned = true }; return try await stream.finish(Data(repeating: 0, count: 4096)) }
        try await until { gate.entered && exists(root, "final-emitted") }
        // The final reader is admitted only after the actual Foundation wait.
        assertReaped(originalPID)
        await pulseWhileHeld(gate)
        finish.cancel()
        try await until { stream.retirementCompletion() != nil }
        let original = try XCTUnwrap(stream.retirementCompletion())
        await pulseWhileHeld(gate)
        XCTAssertFalse(finishReturned)
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        gate.open()
        do { _ = try await finish.value; XCTFail("Cancelled final read returned text") }
        catch { XCTAssertTrue(error is CancellationError) }
        await original.value
        XCTAssertTrue(finishReturned); XCTAssertFalse(gate.timedOut)
        assertReaped(originalPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }
}
