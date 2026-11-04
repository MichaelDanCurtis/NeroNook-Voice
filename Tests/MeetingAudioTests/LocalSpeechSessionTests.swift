import XCTest
import Darwin
@testable import VoiceAudio

final class LocalSpeechSessionTests: XCTestCase {
    @MainActor private func session(_ behavior: String = "echo", pidFile: URL? = nil, receivedFile: URL? = nil) throws -> LocalSpeechSession {
        let script = """
        import json,sys,time,os
        if sys.argv[1]:
            with open(sys.argv[1],'w') as f:f.write(str(os.getpid()))
        print(json.dumps(dict(ready=True,version=1)),flush=True)
        for line in sys.stdin:
            value=json.loads(line)
            if sys.argv[2]:
                with open(sys.argv[2],'w') as f:f.write('received')
            if '\(behavior)'=='slow':time.sleep(10)
            if '\(behavior)'=='bad':value['id']='unexpected'
            print(json.dumps(value),flush=True)
            if '\(behavior)'=='eof':break
        """
        return try LocalSpeechSession(executable: "/usr/bin/python3", arguments: ["-u", "-c", script, pidFile?.path ?? "", receivedFile?.path ?? ""], environment: ["PATH":"/usr/bin:/bin"])
    }
    @MainActor func testReadyRendererIsReusedAndFramesRemainOrdered() async throws {
        let worker = try session(); defer { worker.stop() }
        try await worker.prepare()
        for _ in 0..<3 {
            let id = UUID(), data = try JSONSerialization.data(withJSONObject: ["id":id.uuidString,"ok":true])
            let answer = try await worker.render(data, id:id)
            XCTAssertEqual((try JSONSerialization.jsonObject(with:answer) as? [String:Any])?["id"] as? String,id.uuidString)
        }
        XCTAssertTrue(worker.usable)
    }
    @MainActor func testStopCancelsPendingAndCannotReviveAClosedSession() async throws {
        let worker = try session("slow"); try await worker.prepare()
        let id=UUID(),data=try JSONSerialization.data(withJSONObject:["id":id.uuidString])
        let request=Task { try await worker.render(data,id:id) }
        try await Task.sleep(for:.milliseconds(100));worker.stop()
        do { _=try await request.value;XCTFail("A stopped render completed") }catch{}
        XCTAssertFalse(worker.usable)
        do {try await worker.prepare();XCTFail("Closed session reopened")}catch{}
    }
    @MainActor func testBadReceiptRetiresPendingRequest() async throws {
        let worker=try session("bad");defer{worker.stop()};let id=UUID()
        do {_=try await worker.render(try JSONSerialization.data(withJSONObject:["id":id.uuidString]),id:id);XCTFail("Accepted wrong receipt")}catch{}
        XCTAssertFalse(worker.usable)
    }
    @MainActor func testCancellationAndOversizedRequestAreBounded() async throws {
        let worker=try session("slow");defer{worker.stop()};try await worker.prepare()
        do {_=try await worker.render(Data(repeating:65,count:8193),id:UUID());XCTFail("Accepted oversized request")}catch{}
        let id=UUID(),data=try JSONSerialization.data(withJSONObject:["id":id.uuidString])
        let request=Task{try await worker.render(data,id:id)}
        try await Task.sleep(for:.milliseconds(100));request.cancel()
        do {_=try await request.value;XCTFail("Cancelled render completed")}catch{}
        XCTAssertFalse(worker.usable)
    }
    @MainActor private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speech-retirement-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    @MainActor private func helperPID(_ file: URL) throws -> pid_t {
        try XCTUnwrap(pid_t(String(contentsOf: file, encoding: .utf8)))
    }
    @MainActor private func assertReaped(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        let presence = kill(pid, 0), presenceError = errno
        let group = kill(-pid, 0), groupError = errno
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG), waitError = errno
        XCTAssertEqual(presence, -1, "Retired helper remains present", file: file, line: line)
        XCTAssertEqual(presenceError, ESRCH, file: file, line: line)
        XCTAssertEqual(group, -1, "Retired helper group remains present", file: file, line: line)
        XCTAssertEqual(groupError, ESRCH, file: file, line: line)
        XCTAssertEqual(waited, -1, "Original reader did not reap its child", file: file, line: line)
        XCTAssertEqual(waitError, ECHILD, file: file, line: line)
    }
    @MainActor private func waitForReceipt(_ path: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: path.path) {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "LocalSpeechSessionTests", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor func testOriginalRetirementCompletesAfterActualReapAndRepeatedStopKeepsSuccessor() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try session(pidFile: root.appendingPathComponent("first.pid")); defer { first.stop() }
        try await first.prepare()
        let firstPID = try helperPID(root.appendingPathComponent("first.pid"))
        let original = try XCTUnwrap(first.retirementCompletion())
        first.stop(); first.stop()
        XCTAssertNotNil(first.retirementCompletion(), "Stop dropped original reader custody")
        await original.value; assertReaped(firstPID)
        let second = try session(pidFile: root.appendingPathComponent("second.pid")); defer { second.stop() }
        try await second.prepare()
        let secondPID = try helperPID(root.appendingPathComponent("second.pid"))
        first.stop(); await first.stopAndWait()
        let id = UUID(), data = try JSONSerialization.data(withJSONObject: ["id": id.uuidString])
        _ = try await second.render(data, id: id)
        XCTAssertTrue(second.usable)
        await second.stopAndWait(); assertReaped(secondPID)
    }
    @MainActor func testPendingCancellationJoinsOriginalReaderAndActualReap() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("received")
        let worker = try session("slow", pidFile: root.appendingPathComponent("pid"), receivedFile: receipt)
        defer { worker.stop() }
        try await worker.prepare()
        let pid = try helperPID(root.appendingPathComponent("pid"))
        let original = try XCTUnwrap(worker.retirementCompletion())
        let id = UUID(), data = try JSONSerialization.data(withJSONObject: ["id": id.uuidString])
        let request = Task { try await worker.render(data, id: id) }
        try await waitForReceipt(receipt)
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled render completed") } catch {}
        XCTAssertFalse(worker.usable)
        await original.value; assertReaped(pid)
        await worker.stopAndWait()
    }
    @MainActor func testNaturalEOFRetainsOriginalReaderUntilActualReap() async throws {
        let root = try fixtureRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let worker = try session("eof", pidFile: root.appendingPathComponent("pid")); defer { worker.stop() }
        try await worker.prepare()
        let pid = try helperPID(root.appendingPathComponent("pid"))
        let original = try XCTUnwrap(worker.retirementCompletion())
        let id = UUID(), data = try JSONSerialization.data(withJSONObject: ["id": id.uuidString])
        _ = try await worker.render(data, id: id)
        await original.value
        XCTAssertFalse(worker.usable); XCTAssertNotNil(worker.retirementCompletion())
        assertReaped(pid)
    }

}
