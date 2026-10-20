import XCTest
import Foundation
@testable import VoiceAudio
@MainActor final class QwenSpeechSessionTests:XCTestCase {
 func fixture()throws->URL{let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false);let p=dir.appendingPathComponent("worker");try """
#!/usr/bin/python3
import json,sys,base64,struct,time
print(json.dumps(dict(kind='ready',version=1,sampleRate=24000)),flush=True)
for line in sys.stdin:
 r=json.loads(line)
 print(json.dumps(dict(kind='audio',id=r['id'],sequence=0,sampleRate=24000,pcm=base64.b64encode(struct.pack('<fff',0.0,0.1,-0.1)).decode())),flush=True)
 if r['text']=='stall':time.sleep(30)
 else:print(json.dumps(dict(kind='done',id=r['id'],sequence=1,frames=3)),flush=True)
""".write(to:p,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:p.path);return p}
 func testTwoWarmRequestsUseOrderedFrames()async throws {
  let p=try fixture();defer{try? FileManager.default.removeItem(at:p.deletingLastPathComponent())};let session=try QwenSpeechSession(helper:p,model:p.deletingLastPathComponent());defer{session.stop()};try await session.prepare()
  for _ in 0..<2{let id=UUID();let request=try JSONSerialization.data(withJSONObject:["id":id.uuidString,"text":"hello"]);let stream=try await session.stream(request,id:id);var frames=0;for try await data in stream{frames+=data.count/4};XCTAssertEqual(frames,3);XCTAssertTrue(session.usable)}
 }
 func testStopRetiresPendingGenerationAndCannotResume()async throws {
  let p=try fixture();defer{try? FileManager.default.removeItem(at:p.deletingLastPathComponent())};let session=try QwenSpeechSession(helper:p,model:p.deletingLastPathComponent());defer{session.stop()};let id=UUID(),request=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"text":"stall"])
  var fields=try JSONSerialization.jsonObject(with:request) as! [String:Any];fields["id"]=id.uuidString
  let stream=try await session.stream(try JSONSerialization.data(withJSONObject:fields),id:id);var iterator=stream.makeAsyncIterator();let first=try await iterator.next();XCTAssertEqual(first?.count,12);session.cancelPending();XCTAssertFalse(session.usable)
  do{_=try await iterator.next();XCTFail("Cancelled generation must fail")}catch{}
  do{try await session.prepare();XCTFail("Retired worker must not be reused")}catch{}
 }
}
