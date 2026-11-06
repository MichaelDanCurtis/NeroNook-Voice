import XCTest
import Foundation
import Darwin
import ModuleCore
@testable import VoiceAudio

@MainActor final class MeetingRecognitionRetirementTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recognition-retirement-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let script = """
        import json,os,signal,sys,time
        mode,root,prior=sys.argv[1:4]
        def emit(value):
            try:print(json.dumps(value),flush=True)
            except BrokenPipeError:pass
        def stop(signum,frame):
            emit(dict(type='final',track='mic',start=0,end=0,text='retired output'))
            os._exit(0)
        signal.signal(signal.SIGTERM,stop)
        with open(os.path.join(root,'process.tmp'),'w') as f:
            json.dump(dict(pid=os.getpid(),priorReturned=not prior or os.path.exists(prior)),f)
        os.replace(os.path.join(root,'process.tmp'),os.path.join(root,'process.json'))
        if mode=='delayed':
            while not os.path.exists(os.path.join(root,'ready')):time.sleep(0.01)
        emit(dict(type='ready',version=2))
        if mode=='failure':
            while not os.path.exists(os.path.join(root,'fail')):time.sleep(0.01)
            emit(dict(type='unknown-authored-response'))
            while True:time.sleep(0.05)
        for _ in iter(lambda:sys.stdin.buffer.read(1),b''):pass
        emit(dict(type='closed'))
        """
        try script.write(to: root.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        return root
    }
    private func arguments(_ root: URL, mode: String = "normal", prior: URL? = nil) -> [String] {
        [root.appendingPathComponent("worker.py").path, mode, root.path, prior?.path ?? ""]
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "MeetingRecognitionRetirementTests", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func info(_ root: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("process.json"))) as? [String: Any])
    }
    private func pid(_ root: URL) throws -> pid_t {
        let value = try XCTUnwrap((try info(root))["pid"] as? Int)
        return try XCTUnwrap(pid_t(exactly: value))
    }
    private func assertReaped(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        let present = kill(pid, 0), presenceError = errno
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG), waitError = errno
        XCTAssertEqual(present, -1, "Retired recognizer remains present", file: file, line: line)
        XCTAssertEqual(presenceError, ESRCH, file: file, line: line)
        XCTAssertEqual(result, -1, "Foundation Process wait did not reap its child", file: file, line: line)
        XCTAssertEqual(waitError, ECHILD, file: file, line: line)
    }
    func testStopRetainsOriginalReaderAndLaunchedProcessWaitThroughRepeatedCancel() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = MeetingLiveTranscriber(); defer { service.cancel() }
        var updates: [MeetingLiveUpdate] = [], failures: [String] = []
        try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root),
            update: { updates.append($0) }, failure: { failures.append($0) })
        let originalPID = try pid(root)
        service.cancel()
        let original = try XCTUnwrap(service.retirementCompletion())
        service.cancel(); service.cancel()
        await original.value
        assertReaped(originalPID)
        await service.cancelAndWait()
        XCTAssertTrue(updates.isEmpty); XCTAssertTrue(failures.isEmpty)
    }
    func testCancelDuringReadyWaitJoinsOriginalStartBeforeSuccessorLaunch() async throws {
        let firstRoot = try fixture(), nextRoot = try fixture()
        defer { try? FileManager.default.removeItem(at: firstRoot); try? FileManager.default.removeItem(at: nextRoot) }
        let first = MeetingLiveTranscriber(), next = MeetingLiveTranscriber()
        defer { first.cancel(); next.cancel() }
        let returned = firstRoot.appendingPathComponent("start-returned")
        var oldUpdates: [MeetingLiveUpdate] = []
        let start = Task {
            defer { try? Data("returned".utf8).write(to: returned) }
            try await first.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(firstRoot, mode: "delayed"),
                update: { oldUpdates.append($0) }, failure: { _ in })
        }
        try await until { FileManager.default.fileExists(atPath: firstRoot.appendingPathComponent("process.json").path) }
        let originalPID = try pid(firstRoot)
        first.cancel()
        let original = try XCTUnwrap(first.retirementCompletion())
        let successor = Task {
            try await next.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(nextRoot, prior: returned),
                update: { _ in }, failure: { _ in })
        }
        do { try await start.value; XCTFail("Stopped start completed preparation") } catch {}
        await original.value; assertReaped(originalPID)
        try await successor.value
        XCTAssertEqual(try info(nextRoot)["priorReturned"] as? Bool, true)
        XCTAssertTrue(oldUpdates.isEmpty)
        first.cancel(); await first.cancelAndWait()
        let nextPID = try pid(nextRoot)
        XCTAssertEqual(kill(nextPID, 0), 0, "Retiring old service affected its successor")
        await next.cancelAndWait(); assertReaped(nextPID)
    }
    func testCancelledStartTaskRetiresActualWorkerWithoutASeparateStop() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = MeetingLiveTranscriber(); defer { service.cancel() }
        let start = Task {
            try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root, mode: "delayed"),
                update: { _ in }, failure: { _ in })
        }
        try await until { FileManager.default.fileExists(atPath: root.appendingPathComponent("process.json").path) }
        let originalPID = try pid(root)
        start.cancel()
        do { try await start.value; XCTFail("Cancelled start returned ready") }
        catch { XCTAssertTrue(error is CancellationError) }
        let original = try XCTUnwrap(service.retirementCompletion())
        await original.value; assertReaped(originalPID)
    }
    func testOverlappingStartRefusesWithoutReplacingOriginalWorker() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let service = MeetingLiveTranscriber(); defer { service.cancel() }
        let start = Task {
            try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root, mode: "delayed"),
                update: { _ in }, failure: { _ in })
        }
        try await until { FileManager.default.fileExists(atPath: root.appendingPathComponent("process.json").path) }
        let originalPID = try pid(root)
        do {
            try await service.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(root),
                update: { _ in }, failure: { _ in })
            XCTFail("Overlapping start replaced original preparation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try pid(root), originalPID)
        try Data().write(to: root.appendingPathComponent("ready"))
        try await start.value
        await service.cancelAndWait(); assertReaped(originalPID)
    }
    func testFailurePublishesRetirementBeforeReentrantSuccessorStart() async throws {
        let firstRoot = try fixture(), nextRoot = try fixture()
        defer { try? FileManager.default.removeItem(at: firstRoot); try? FileManager.default.removeItem(at: nextRoot) }
        let first = MeetingLiveTranscriber(), next = MeetingLiveTranscriber()
        defer { first.cancel(); next.cancel() }
        var published = false, successor: Task<Void, Error>?
        try await first.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: arguments(firstRoot, mode: "failure"), update: { _ in }, failure: { _ in
            published = first.retirementCompletion() != nil && MeetingLiveTranscriber.pendingRetirementCompletion() != nil
            successor = Task {
                try await next.startPreparedWorker(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: self.arguments(nextRoot),
                    update: { _ in }, failure: { _ in })
            }
        })
        let originalPID = try pid(firstRoot)
        try Data().write(to: firstRoot.appendingPathComponent("fail"))
        try await until { successor != nil }
        let actualSuccessor = try XCTUnwrap(successor)
        try await actualSuccessor.value
        XCTAssertTrue(published)
        await first.cancelAndWait(); assertReaped(originalPID)
        let nextPID = try pid(nextRoot)
        await next.cancelAndWait(); assertReaped(nextPID)
        let neverStarted = MeetingLiveTranscriber()
        await neverStarted.cancelAndWait() // No waitUntilExit on an unlaunched Process.
    }
}
