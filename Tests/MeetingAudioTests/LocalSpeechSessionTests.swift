import XCTest
@testable import VoiceAudio

final class LocalSpeechSessionTests: XCTestCase {
    @MainActor private func session(_ behavior: String = "echo") throws -> LocalSpeechSession {
        let script = """
        import json,sys,time
        print(json.dumps(dict(ready=True,version=1)),flush=True)
        for line in sys.stdin:
            value=json.loads(line)
            if '\(behavior)'=='slow':time.sleep(10)
            if '\(behavior)'=='bad':value['id']='unexpected'
            print(json.dumps(value),flush=True)
        """
        return try LocalSpeechSession(executable: "/usr/bin/python3", arguments: ["-u", "-c", script], environment: ["PATH":"/usr/bin:/bin"])
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
}
