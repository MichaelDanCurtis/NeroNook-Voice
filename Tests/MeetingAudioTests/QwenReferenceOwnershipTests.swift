import XCTest
import Foundation
@testable import VoiceAudio

final class QwenReferenceOwnershipTests:XCTestCase{
    @MainActor func testOriginalTapCallbackReturnsBeforeActualFileWriterBarrier()async throws{
        let tail=QwenReferenceReturnTail(),lease=try XCTUnwrap(tail.admission.enter())
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:path)}
        var nativeStops=0,writerReturned=false
        let returned=tail.stop(native:{nativeStops+=1},writer:{Result{
            FileManager.default.createFile(atPath:path.path,contents:Data())
            let file=try FileHandle(forWritingTo:path)
            try file.write(contentsOf:Data("queued authored bytes".utf8));try file.close()
            writerReturned=true;return path
        }})
        XCTAssertEqual(nativeStops,1);XCTAssertFalse(writerReturned);XCTAssertNil(tail.admission.enter())
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.path))
        let repeated=tail.stop(native:{XCTFail("stopped a replacement")},writer:{XCTFail("replaced original writer");return .success(path)})
        lease.finish()
        let first=try await returned.value.get(),second=try await repeated.value.get()
        XCTAssertEqual(first,path);XCTAssertEqual(second,path)
        XCTAssertTrue(writerReturned);XCTAssertEqual(nativeStops,1)
        XCTAssertEqual(try String(contentsOf:path,encoding:.utf8),"queued authored bytes")
    }
    @MainActor func testWriterOperationFailureStillReturnsOriginalCallbackAndWriter()async throws{
        let tail=QwenReferenceReturnTail(),lease=try XCTUnwrap(tail.admission.enter())
        var writerReturned=false
        let returned=tail.stop(native:{},writer:{writerReturned=true;return .failure(NSError(domain:"authored.writer",code:3))})
        XCTAssertFalse(writerReturned);lease.finish()
        let result=await returned.value
        if case .success=result{XCTFail("erased original writer failure")}
        XCTAssertTrue(writerReturned)
        await tail.admission.waitForReturn()
        XCTAssertNil(tail.admission.enter())
    }
    @MainActor func testCapturedPreparationReturnWaitsForOriginalPermitRelease()async throws{
        let gate=SpeechPreparationGate(),original=try await gate.acquire()
        let returned=try XCTUnwrap(gate.currentReturn())
        var joined=false
        let waiter=Task{await returned.value;joined=true}
        await Task.yield();XCTAssertFalse(joined)
        gate.release(original);await waiter.value
        XCTAssertTrue(joined);XCTAssertNil(gate.currentReturn())
    }
    @MainActor func testOldPreparationReceiptDoesNotWaitForOrReleaseSuccessor()async throws{
        let gate=SpeechPreparationGate(),original=try await gate.acquire()
        let returned=try XCTUnwrap(gate.currentReturn())
        gate.release(original)
        let successor=try await gate.acquire()
        await returned.value
        XCTAssertTrue(gate.busy);XCTAssertNotNil(gate.currentReturn())
        gate.release(original);XCTAssertTrue(gate.busy)
        gate.release(successor);XCTAssertFalse(gate.busy)
    }
    @MainActor func testStopBeforeAnyTapCallbackUsesOneImmediateOriginalWriterReturn()async throws{
        let tail=QwenReferenceReturnTail(),path=URL(fileURLWithPath:"/authored-not-opened")
        var finishes=0
        let returned=tail.stop(native:{},writer:{finishes+=1;return .success(path)})
        XCTAssertEqual(try tail.immediate?.get(),path)
        let result=try await returned.value.get()
        XCTAssertEqual(result,path);XCTAssertEqual(finishes,1)
    }
}
