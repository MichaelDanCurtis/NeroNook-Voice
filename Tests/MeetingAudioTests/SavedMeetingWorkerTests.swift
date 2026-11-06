import XCTest
import Foundation
import Dispatch
import Darwin
import ModuleCore
@testable import VoiceAudio

private final class SavedReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let outputOnly: Bool
    private var enteredValue = false, heldValue = false, expiredValue = false
    init(outputOnly: Bool) { self.outputOnly = outputOnly }
    func checkpoint(_ kind: SavedMeetingReadKind) {
        let matches: Bool
        switch kind { case .output: matches = outputOnly; case .progress: matches = !outputOnly }
        lock.lock()
        guard matches, !enteredValue else { lock.unlock(); return }
        enteredValue = true; heldValue = true; lock.unlock()
        let result = semaphore.wait(timeout: .now() + 5)
        lock.lock(); expiredValue = result == .timedOut; heldValue = false; lock.unlock()
    }
    func open() { semaphore.signal() }
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return enteredValue }
    var held: Bool { lock.lock(); defer { lock.unlock() }; return heldValue }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return expiredValue }
}
private final class SavedReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func observe(_ kind: SavedMeetingReadKind) {
        if case .progress = kind { lock.lock(); count += 1; lock.unlock() }
    }
    var observed: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
}

@MainActor final class SavedMeetingWorkerTests: XCTestCase {
    private struct Fixture {
        let root: URL
        var output: URL { root.appendingPathComponent("output.json") }
        var log: URL { root.appendingPathComponent("progress.txt") }
        var input: URL { root.appendingPathComponent("input.f32") }
    }
    private func fixture(payload: Data = Data("[]".utf8)) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saved-meeting-worker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let value = Fixture(root: root)
        try payload.write(to: root.appendingPathComponent("payload.json"))
        try Data(repeating: 0, count: 4096).write(to: value.input)
        let script = """
        import json,os,signal,sys,time
        root,mode=sys.argv[1:3]
        def marker(name):
            with open(os.path.join(root,name),'w') as f:f.write('observed')
        term=False
        def stop(*_):
            global term
            term=True
            print('progress 0.99',flush=True)
            marker('term')
        signal.signal(signal.SIGTERM,stop)
        with open(os.path.join(root,'pid.tmp'),'w') as f:f.write(str(os.getpid()))
        os.replace(os.path.join(root,'pid.tmp'),os.path.join(root,'pid'))
        with open(os.path.join(root,'input.f32'),'rb') as f:
            data=f.read()
            assert len(data)%4==0 and all(value==0 for value in data)
        with open(os.path.join(root,'payload.json'),'rb') as f:payload=f.read()
        with open(os.path.join(root,'output.json'),'wb') as f:f.write(payload)
        if mode=='progress-cap':
            sys.stdout.buffer.write(b'x'*1000000+b'\\nprogress 0.75\\n')
            sys.stdout.buffer.flush()
        else:print('progress 0.25',flush=True)
        marker('ready')
        if mode!='natural':
            while not os.path.exists(os.path.join(root,'allow-exit')):time.sleep(0.01)
        with open(os.path.join(root,'exit-observation.json'),'w') as f:
            json.dump(dict(term=term,inputPresent=os.path.exists(os.path.join(root,'input.f32')),
                           outputPresent=os.path.exists(os.path.join(root,'output.json')),
                           logPresent=os.path.exists(os.path.join(root,'progress.txt'))),f)
        """
        try script.write(to: root.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        return value
    }
    private func process(_ fixture: Fixture, mode: String = "wait") -> Process {
        let value = Process(); value.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        value.arguments = ["-u", fixture.root.appendingPathComponent("worker.py").path, fixture.root.path, mode]
        return value
    }
    private func worker(_ process: Process, _ fixture: Fixture, limit: Int = 32_000_000,
                        checkpoint: (@Sendable (SavedMeetingReadKind) -> Void)? = nil) -> SavedMeetingWorker {
        SavedMeetingWorker(process: process, output: fixture.output, log: fixture.log, outputLimit: limit,
            pollInterval: .milliseconds(20), progressTimeout: 5,
            processFailure: "Authored process failure", limitFailure: "Authored output limit",
            timeoutFailure: "Authored progress timeout", readCheckpoint: checkpoint)
    }
    private func exists(_ fixture: Fixture, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(name).path)
    }
    private func allowExit(_ fixture: Fixture) { try? Data("exit".utf8).write(to: fixture.root.appendingPathComponent("allow-exit")) }
    private func until(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < end else { throw NSError(domain: "SavedMeetingWorkerTests", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func pid(_ fixture: Fixture) throws -> pid_t {
        let text = try String(contentsOf: fixture.root.appendingPathComponent("pid"), encoding: .utf8)
        return try XCTUnwrap(pid_t(text))
    }
    private func assertReaped(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        let present = kill(pid, 0), presenceError = errno
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG), waitError = errno
        XCTAssertEqual(present, -1, file: file, line: line); XCTAssertEqual(presenceError, ESRCH, file: file, line: line)
        XCTAssertEqual(waited, -1, file: file, line: line); XCTAssertEqual(waitError, ECHILD, file: file, line: line)
    }
    private func pulse(_ gate: SavedReadGate) async {
        var heldWhenActorRan = false
        let value = Task { @MainActor in heldWhenActorRan = gate.held }
        await value.value
        XCTAssertTrue(heldWhenActorRan); XCTAssertFalse(gate.expired)
    }
    /// Every thrown assertion/fixture failure still stops and joins the original
    /// task before test-owned input/root cleanup. No successful job is rerun.
    private func joining<T: Sendable>(_ task: Task<T, Error>, cleanup: () -> Void,
                            body: () async throws -> Void) async throws {
        var failure: Error?
        do { try await body() } catch { failure = error }
        cleanup(); _ = await task.result
        if let failure { throw failure }
    }
    private func expectCancelled<T: Sendable>(_ task: Task<T, Error>) async {
        do { _ = try await task.value; XCTFail("Stopped worker returned successful output") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCallerCancellationRetainsInputLogAndOpenedReadThroughOriginalReap() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = SavedReadGate(outputOnly: false), process = process(fixture)
        let worker = worker(process, fixture, checkpoint: { gate.checkpoint($0) })
        var returned = false
        let run = Task {
            defer { returned = true; try? FileManager.default.removeItem(at: fixture.input) }
            return try await worker.run(progress: { _ in })
        }
        try await joining(run, cleanup: { gate.open(); worker.stop(); allowExit(fixture) }) {
            try await until { gate.entered && exists(fixture, "ready") }
            let originalPID = try pid(fixture), originalWait = try XCTUnwrap(worker.processCompletion)
            await pulse(gate)
            run.cancel()
            try await until { exists(fixture, "term") }
            XCTAssertFalse(returned); XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.input.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.log.path))
            allowExit(fixture); await originalWait.value; assertReaped(originalPID)
            await pulse(gate)
            XCTAssertFalse(returned); XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.output.path))
            gate.open(); await expectCancelled(run)
            XCTAssertTrue(returned); XCTAssertFalse(gate.expired)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.input.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
            let observed = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("exit-observation.json"))) as? [String: Bool]
            XCTAssertEqual(observed?["inputPresent"], true); XCTAssertEqual(observed?["logPresent"], true)
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }
    func testASRStopJobsFromProgressRejectsValidExitZeroWithoutCancellingCaller() async throws {
        let payload = try JSONEncoder().encode([MeetingUtterance(start: 0, end: 1, track: "mic", text: "Authored words")])
        let fixture = try fixture(payload: payload); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let process = process(fixture)
        var values: [Double] = [], returned = false
        let run = Task {
            defer { returned = true; try? FileManager.default.removeItem(at: fixture.input) }
            return try await LocalASREngine.transcribePreparedWorker(process: process, output: fixture.output, log: fixture.log, track: "mic") {
                values.append($0); LocalASREngine.stopJobs()
            }
        }
        try await joining(run, cleanup: { LocalASREngine.stopJobs(); allowExit(fixture) }) {
            try await until { exists(fixture, "term") }
            let originalPID = try pid(fixture)
            XCTAssertFalse(run.isCancelled); XCTAssertFalse(returned)
            XCTAssertEqual(values, [0.25]); XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.input.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.output.path))
            allowExit(fixture); await expectCancelled(run)
            XCTAssertEqual(values, [0.25]); XCTAssertTrue(returned); XCTAssertEqual(process.terminationStatus, 0)
            assertReaped(originalPID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.input.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
        }
    }
    func testSpeakerStopJobsDuringFinalReadRejectsAlreadyExitedValidOutput() async throws {
        let fixture = try fixture(payload: JSONEncoder().encode([MeetingSpeakerSpan(start: 0, end: 1, speaker: 0)]))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let gate = SavedReadGate(outputOnly: true), process = process(fixture, mode: "natural")
        var returned = false
        let run = Task {
            defer { returned = true }
            return try await MeetingSpeakerEngine.identifyPreparedWorker(process: process, output: fixture.output, log: fixture.log,
                readCheckpoint: { gate.checkpoint($0) }, progress: { _ in })
        }
        try await joining(run, cleanup: { gate.open(); MeetingSpeakerEngine.stopJobs(); allowExit(fixture) }) {
            try await until { gate.entered }
            let originalPID = try pid(fixture); assertReaped(originalPID)
            XCTAssertEqual(process.terminationStatus, 0)
            MeetingSpeakerEngine.stopJobs(); MeetingSpeakerEngine.stopJobs()
            await pulse(gate)
            XCTAssertFalse(run.isCancelled); XCTAssertFalse(returned)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.output.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.log.path))
            gate.open(); await expectCancelled(run)
            XCTAssertTrue(returned); XCTAssertFalse(gate.expired); assertReaped(originalPID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
        }
    }
    func testStopJobsCoversQueuedPreparedASRWithoutLaunchingIt() async throws {
        let first = try fixture(), second = try fixture()
        defer { try? FileManager.default.removeItem(at: first.root); try? FileManager.default.removeItem(at: second.root) }
        let firstProcess = process(first), firstWorker = worker(firstProcess, first)
        let firstRun = Task { try await firstWorker.run(progress: { _ in }) }
        try await joining(firstRun, cleanup: { firstWorker.stop(); allowExit(first) }) {
            try await until { exists(first, "ready") }
            let firstPID = try pid(first), secondProcess = process(second)
            let secondRun = Task { try await LocalASREngine.transcribePreparedWorker(process: secondProcess,
                output: second.output, log: second.log, track: "mic", progress: { _ in }) }
            try await joining(secondRun, cleanup: { LocalASREngine.stopJobs(); allowExit(second); allowExit(first) }) {
                try await until { FileManager.default.fileExists(atPath: second.log.path) }
                LocalASREngine.stopJobs()
                XCTAssertFalse(exists(second, "pid")); XCTAssertTrue(firstProcess.isRunning)
                allowExit(first); _ = try await firstRun.value
                await expectCancelled(secondRun)
                XCTAssertFalse(exists(second, "pid")); XCTAssertFalse(secondProcess.isRunning)
                XCTAssertFalse(FileManager.default.fileExists(atPath: second.log.path)); assertReaped(firstPID)
            }
        }
    }
    func testNaturalASRAndSpeakerUseProductionDecodersAndReapBeforeReturn() async throws {
        for speaker in [false, true] {
            let payload: Data
            if speaker { payload = try JSONEncoder().encode([MeetingSpeakerSpan(start: 0, end: 1, speaker: 2)]) }
            else { payload = try JSONEncoder().encode([MeetingUtterance(start: 0, end: 1, track: "mic", text: "Authored café 🌿")]) }
            let fixture = try fixture(payload: payload); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let process = process(fixture, mode: "natural")
            let run = Task<String, Error> {
                if speaker { return try await MeetingSpeakerEngine.identifyPreparedWorker(process: process, output: fixture.output, log: fixture.log, progress: { _ in }).map { String($0.speaker) }.joined(separator: ",") }
                return try await LocalASREngine.transcribePreparedWorker(process: process, output: fixture.output, log: fixture.log, track: "mic", progress: { _ in }).map(\.text).joined(separator: " ")
            }
            try await joining(run, cleanup: { MeetingSpeakerEngine.stopJobs(); LocalASREngine.stopJobs(); allowExit(fixture) }) {
                let value = try await run.value; XCTAssertEqual(value, speaker ? "2" : "Authored café 🌿")
                assertReaped(try pid(fixture)); XCTAssertEqual(process.terminationStatus, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
            }
        }
    }
    func testAtCapProgressIsIgnoredWithoutLosingNaturalResult() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = SavedReadProbe(), process = process(fixture, mode: "progress-cap")
        let worker = worker(process, fixture, checkpoint: { probe.observe($0) })
        var values: [Double] = []
        let run = Task { try await worker.run(progress: { values.append($0) }) }
        try await joining(run, cleanup: { worker.stop(); allowExit(fixture) }) {
            try await until { probe.observed && exists(fixture, "ready") }
            XCTAssertTrue(values.isEmpty)
            allowExit(fixture)
            let value = try await run.value; XCTAssertEqual(value, Data("[]".utf8))
            XCTAssertTrue(values.isEmpty); assertReaped(try pid(fixture))
        }
    }
    func testExactFinalLimitAndInvalidASRRemainFailuresAfterReap() async throws {
        let oversized = try fixture(payload: Data(("[]" + String(repeating: " ", count: 62)).utf8))
        defer { try? FileManager.default.removeItem(at: oversized.root) }
        let oversizedProcess = process(oversized, mode: "natural")
        let oversizedWorker = worker(oversizedProcess, oversized, limit: 64)
        let run = Task { try await oversizedWorker.run(progress: { _ in }) }
        try await joining(run, cleanup: { oversizedWorker.stop(); allowExit(oversized) }) {
            do { _ = try await run.value; XCTFail("Exact cap was accepted") }
            catch { XCTAssertEqual(error.localizedDescription, "Authored output limit") }
            assertReaped(try pid(oversized))
        }
        for payload in [Data("{invalid".utf8), try JSONEncoder().encode([MeetingUtterance(start: 0, end: 1, track: "wrong", text: "Authored words")])] {
            let fixture = try fixture(payload: payload); defer { try? FileManager.default.removeItem(at: fixture.root) }
            let process = process(fixture, mode: "natural")
            let run = Task { try await LocalASREngine.transcribePreparedWorker(process: process, output: fixture.output, log: fixture.log, track: "mic", progress: { _ in }) }
            try await joining(run, cleanup: { LocalASREngine.stopJobs(); allowExit(fixture) }) {
                do { _ = try await run.value; XCTFail("Invalid ASR result was accepted") }
                catch { XCTAssertFalse(error is CancellationError) }
                assertReaped(try pid(fixture))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
            }
        }
    }
    func testLaunchFailureNeverCreatesAWaitForUnlaunchedProcess() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let process = Process(); process.executableURL = fixture.root.appendingPathComponent("missing-executable")
        let worker = worker(process, fixture)
        let run = Task { try await worker.run(progress: { _ in }) }
        try await joining(run, cleanup: { worker.stop(); allowExit(fixture) }) {
            do { _ = try await run.value; XCTFail("Missing executable was accepted") }
            catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertNil(worker.processCompletion); XCTAssertFalse(exists(fixture, "pid"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path))
        }
    }
}
