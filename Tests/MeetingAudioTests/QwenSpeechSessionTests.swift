import XCTest
import Foundation
import Darwin
@testable import VoiceAudio
@MainActor final class QwenSpeechSessionTests:XCTestCase {
 func fixture(_ behavior:String="normal")throws->URL{let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false);let p=dir.appendingPathComponent("worker");try """
#!/usr/bin/python3
import json,sys,base64,struct,time,os
with open(os.path.join(os.path.dirname(__file__),'pid'),'w') as f:f.write(str(os.getpid()))
print(json.dumps(dict(kind='ready',version=1,sampleRate=24000)),flush=True)
for line in sys.stdin:
 r=json.loads(line)
 print(json.dumps(dict(kind='audio',id=r['id'],sequence=0,sampleRate=24000,pcm=base64.b64encode(struct.pack('<fff',0.0,0.1,-0.1)).decode())),flush=True)
 if r['text']=='stall':time.sleep(30)
 else:print(json.dumps(dict(kind='done',id=r['id'],sequence=1,frames=3)),flush=True)
 if '\(behavior)'=='eof':break
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
 private func helperPID(_ helper:URL)throws->pid_t {
  try XCTUnwrap(pid_t(String(contentsOf:helper.deletingLastPathComponent().appendingPathComponent("pid"),encoding:.utf8)))
 }
 private func assertReaped(_ pid:pid_t,file:StaticString=#filePath,line:UInt=#line) {
  let presence=kill(pid,0),presenceError=errno
  let group=kill(-pid,0),groupError=errno
  var status:Int32=0
  let waited=waitpid(pid,&status,WNOHANG),waitError=errno
  XCTAssertEqual(presence,-1,"Retired Qwen helper remains present",file:file,line:line)
  XCTAssertEqual(presenceError,ESRCH,file:file,line:line)
  XCTAssertEqual(group,-1,"Retired Qwen helper group remains present",file:file,line:line)
  XCTAssertEqual(groupError,ESRCH,file:file,line:line)
  XCTAssertEqual(waited,-1,"Original reader did not reap its Qwen child",file:file,line:line)
  XCTAssertEqual(waitError,ECHILD,file:file,line:line)
 }
 func testOriginalRetirementAndRepeatedStopDoNotAffectNewWorker()async throws {
  let firstHelper=try fixture(),secondHelper=try fixture()
  defer { try? FileManager.default.removeItem(at:firstHelper.deletingLastPathComponent());try? FileManager.default.removeItem(at:secondHelper.deletingLastPathComponent()) }
  let first=try QwenSpeechSession(helper:firstHelper,model:firstHelper.deletingLastPathComponent());defer{first.stop()}
  try await first.prepare();let firstPID=try helperPID(firstHelper)
  let original=try XCTUnwrap(first.retirementCompletion())
  first.stop();first.stop();XCTAssertNotNil(first.retirementCompletion())
  await original.value;assertReaped(firstPID)
  let second=try QwenSpeechSession(helper:secondHelper,model:secondHelper.deletingLastPathComponent());defer{second.stop()}
  try await second.prepare();let secondPID=try helperPID(secondHelper)
  first.stop();await first.stopAndWait()
  let id=UUID(),request=try JSONSerialization.data(withJSONObject:["id":id.uuidString,"text":"hello"])
  let stream=try await second.stream(request,id:id);var frames=0
  for try await data in stream{frames+=data.count/4}
  XCTAssertEqual(frames,3);XCTAssertTrue(second.usable)
  await second.stopAndWait();assertReaped(secondPID)
 }
 func testPendingCancellationJoinsActualOriginalReaderReap()async throws {
  let helper=try fixture();defer{try? FileManager.default.removeItem(at:helper.deletingLastPathComponent())}
  let session=try QwenSpeechSession(helper:helper,model:helper.deletingLastPathComponent());defer{session.stop()}
  try await session.prepare();let pid=try helperPID(helper)
  let original=try XCTUnwrap(session.retirementCompletion())
  let id=UUID(),request=try JSONSerialization.data(withJSONObject:["id":id.uuidString,"text":"stall"])
  let stream=try await session.stream(request,id:id);var iterator=stream.makeAsyncIterator()
  let first=try await iterator.next();XCTAssertEqual(first?.count,12)
  session.cancelPending();XCTAssertFalse(session.usable)
  do{_=try await iterator.next();XCTFail("Cancelled generation completed")}catch{}
  await original.value;assertReaped(pid)
  await session.stopAndWait()
 }
 func testNaturalEOFRetainsOriginalReaderThroughActualReap()async throws {
  let helper=try fixture("eof");defer{try? FileManager.default.removeItem(at:helper.deletingLastPathComponent())}
  let session=try QwenSpeechSession(helper:helper,model:helper.deletingLastPathComponent());defer{session.stop()}
  try await session.prepare();let pid=try helperPID(helper)
  let original=try XCTUnwrap(session.retirementCompletion())
  let id=UUID(),request=try JSONSerialization.data(withJSONObject:["id":id.uuidString,"text":"hello"])
  let stream=try await session.stream(request,id:id);var frames=0
  for try await data in stream{frames+=data.count/4}
  XCTAssertEqual(frames,3)
  await original.value
  XCTAssertFalse(session.usable);XCTAssertNotNil(session.retirementCompletion());assertReaped(pid)
 }

}
