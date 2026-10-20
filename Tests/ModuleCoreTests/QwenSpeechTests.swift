import XCTest
@testable import ModuleCore
final class QwenSpeechTests:XCTestCase {
 func line(_ v:[String:Any])throws->Data{try JSONSerialization.data(withJSONObject:v)}
 func ready(_ w:inout QwenSpeechWire)throws{_ = try w.accept(line(["kind":"ready","version":1,"sampleRate":24000]))}
 func audio(_ id:UUID,sequence:Int=0,values:[Float]=[0,0.1,-0.1])->[String:Any]{["kind":"audio","id":id.uuidString,"sequence":sequence,"sampleRate":24000,"pcm":values.withUnsafeBytes{Data($0).base64EncodedString()}]}
 func testOrderedAudioAndDoneThenNewTurn()throws{
  var w=QwenSpeechWire();try ready(&w);let id=UUID();try w.begin(id);if case .audio(let d)=try w.accept(line(audio(id))){XCTAssertEqual(d.count,12)}else{XCTFail()};XCTAssertEqual(w.frames,3)
  _=try w.accept(line(["kind":"done","id":id.uuidString,"sequence":1,"frames":3]));XCTAssertNil(w.active)
  let next=UUID();try w.begin(next);XCTAssertEqual(w.frames,0);XCTAssertThrowsError(try w.accept(line(audio(id))));_ = try w.accept(line(audio(next)))
 }
 func testNoPlaybackBeforeReadyWrongIDSequenceAndDuplicateReady()throws{
  var w=QwenSpeechWire();let id=UUID();XCTAssertThrowsError(try w.begin(id));XCTAssertThrowsError(try w.accept(line(audio(id))));try ready(&w);XCTAssertThrowsError(try ready(&w));try w.begin(id);XCTAssertThrowsError(try w.begin(UUID()));XCTAssertThrowsError(try w.accept(line(audio(UUID()))));XCTAssertThrowsError(try w.accept(line(audio(id,sequence:1))))
 }
 func testRejectsInvalidPCMAndIncompleteTerminal()throws{
  var w=QwenSpeechWire();try ready(&w);let id=UUID();try w.begin(id)
  for samples:[Float] in [[.nan],[.infinity],[5]]{XCTAssertThrowsError(try w.accept(line(audio(id,values:samples))))}
  var v=audio(id);v["pcm"]=Data([1,2,3]).base64EncodedString();XCTAssertThrowsError(try w.accept(line(v)))
  v=audio(id);v["sampleRate"]=48000;XCTAssertThrowsError(try w.accept(line(v)))
  XCTAssertThrowsError(try w.accept(line(["kind":"done","id":id.uuidString,"sequence":0,"frames":0])))
  _=try w.accept(line(audio(id)));XCTAssertThrowsError(try w.accept(line(["kind":"done","id":id.uuidString,"sequence":1,"frames":4])))
 }
 func testFrameAndUtteranceBounds()throws{
  var w=QwenSpeechWire();try ready(&w);let id=UUID();try w.begin(id)
  XCTAssertThrowsError(try w.accept(Data(repeating:32,count:49153)))
  XCTAssertThrowsError(try w.accept(line(audio(id,values:[Float](repeating:0,count:8193)))))
  let chunk=[Float](repeating:0.01,count:8192)
  for i in 0..<527{_=try w.accept(line(audio(id,sequence:i,values:chunk)))}
  XCTAssertThrowsError(try w.accept(line(audio(id,sequence:527,values:chunk))))
 }
 func testLanguageIsExplicitAndUnsupportedDoesNotFallBack()throws{XCTAssertEqual(try QwenLanguage.name(for:"en-US"),"English");XCTAssertEqual(try QwenLanguage.name(for:"es-MX"),"Spanish");XCTAssertEqual(try QwenLanguage.name(for:"zh-Hant"),"Chinese");XCTAssertThrowsError(try QwenLanguage.name(for:"ar-SA"))}
}
