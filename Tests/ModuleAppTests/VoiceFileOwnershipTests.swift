import XCTest
import Foundation
import VoiceAudio
@testable import ModuleApp

final class VoiceFileOwnershipTests:XCTestCase{
    @MainActor func testOwnedTempSurvivesHeldOriginalReaderAndCommittedSaveSurvivesStop()async throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let input=root.appendingPathComponent("owned.txt"),published=root.appendingPathComponent("saved.txt")
        try Data("authored reference".utf8).write(to:input)
        let source=VoiceOwnedFileSource(url:input,owned:true),consumer=try source.acquire()
        let work=VoiceFileWork(),owner=VoiceFoundationOwner(),gate=FileWorkBlockingGate()
        let(stream,entered)=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
        var iterator=stream.makeAsyncIterator(),result:Result<String,Error>?
        try work.start(owner:owner,work:{()->Result<String,Error> in Result{
            let reader=try FileHandle(forReadingFrom:input);defer{try? reader.close()}
            entered.yield(());gate.wait()
            let bytes=try reader.readToEnd() ?? Data();try bytes.write(to:published)
            return String(decoding:bytes,as:UTF8.self)
        }},cancelled:{source.release(consumer);entered.finish()}){value in result=value;source.release(consumer);entered.finish()}
        let entry=await iterator.next()
        XCTAssertNotNil(entry,"Original reader never opened the authored source")
        source.discard();work.close(owner)
        XCTAssertTrue(work.busy);XCTAssertTrue(FileManager.default.fileExists(atPath:input.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:published.path))
        gate.release();await work.wait(owner)
        XCTAssertEqual(try XCTUnwrap(result).get(),"authored reference")
        XCTAssertFalse(FileManager.default.fileExists(atPath:input.path))
        XCTAssertEqual(try String(contentsOf:published,encoding:.utf8),"authored reference")
        XCTAssertNil(source.cleanupIssue);entered.finish()
    }
    @MainActor func testImportedOriginalIsNeverDeletedAndForeignConsumerCannotReleaseReader()throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("user-authored fixture".utf8).write(to:root);defer{try? FileManager.default.removeItem(at:root)}
        let source=VoiceOwnedFileSource(url:root,owned:false),consumer=try source.acquire()
        source.discard();source.release(UUID())
        XCTAssertEqual(try String(contentsOf:root,encoding:.utf8),"user-authored fixture")
        source.release(consumer);source.release(consumer)
        XCTAssertEqual(try String(contentsOf:root,encoding:.utf8),"user-authored fixture")
        XCTAssertThrowsError(try source.acquire())
    }
    @MainActor func testCancelBeforeFirstRunDoesNotLaunchDetachedFileWorkAndReturnsLease()async throws{
        let work=VoiceFileWork(),owner=VoiceFoundationOwner(),probe=FileWorkProbe()
        var abandoned=false,completed=false
        try work.start(owner:owner,work:{probe.start();return true},cancelled:{abandoned=true}){_ in completed=true}
        work.close(owner);await work.wait(owner)
        XCTAssertFalse(probe.started);XCTAssertTrue(abandoned);XCTAssertFalse(completed)
    }
    @MainActor func testScopedOriginalAssetJoinDoesNotWaitForOtherOwners()async{
        let work=VoiceFileWork(),a=VoiceFoundationOwner(),b=VoiceFoundationOwner(),local=LocalFoundationModelWork.localUser
        let gateA=FileWorkAsyncGate(),gateB=FileWorkAsyncGate(),gateLocal=FileWorkAsyncGate()
        work.retain(Task{await gateA.wait()},owner:a);work.retain(Task{await gateB.wait()},owner:b)
        work.retain(Task{await gateLocal.wait()},owner:local)
        work.close(a);await gateA.release();await work.wait(a)
        XCTAssertTrue(work.busy);XCTAssertTrue(work.permits(b));XCTAssertTrue(work.permits(local));XCTAssertFalse(work.permits(a))
        await gateB.release();await gateLocal.release();await work.wait(nil)
        XCTAssertFalse(work.busy)
    }
    @MainActor func testCancelledPickerCallbackRemainsOwnedUntilItsQueuedDeliveryReturns()async{
        let work=VoiceFileWork(),a=VoiceFoundationOwner(),b=VoiceFoundationOwner()
        let old=VoiceFileCallback(),replacement=VoiceFileCallback()
        work.retain(old.returned,owner:a);work.retain(replacement.returned,owner:b)
        var stopped=false,oldPublished=false,newPublished=false
        old.close{stopped=true};work.close(a)
        XCTAssertTrue(stopped);XCTAssertTrue(work.busy)
        old.deliver{oldPublished=true};await work.wait(a)
        XCTAssertFalse(oldPublished);XCTAssertTrue(work.busy)
        replacement.deliver{newPublished=true};await work.wait(b)
        XCTAssertTrue(newPublished);XCTAssertFalse(work.busy)
    }
    @MainActor func testCleanupFailureIsLatchedBeforeOriginalSourceCanBeDiscarded()throws{
        var originalFailure:String?
        let source=VoiceOwnedFileSource(url:URL(fileURLWithPath:"/authored-not-opened"),owned:true,
            cleanup:{_ in throw NSError(domain:"authored.cleanup",code:7)},failure:{originalFailure=$0})
        let reader=try source.acquire();source.discard()
        XCTAssertNil(originalFailure)
        source.release(reader)
        XCTAssertNotNil(source.cleanupIssue);XCTAssertEqual(source.cleanupIssue,originalFailure)
    }
    @MainActor func testProfileMoveWaitsForActualOriginalReaderClose()async throws{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let input=root.appendingPathComponent("reference.txt"),archive=root.appendingPathComponent("archive.txt")
        try Data("owned reference".utf8).write(to:input)
        let work=VoiceFileWork(),owner=VoiceFoundationOwner(),gate=FileWorkBlockingGate(),probe=FileWorkReaderProbe()
        let(stream,entered)=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
        var iterator=stream.makeAsyncIterator()
        let original=Task.detached{
            defer{entered.finish()}
            do{let file=try FileHandle(forReadingFrom:input);probe.opened();entered.yield(())
                gate.wait();_=try file.read(upToCount:1);try file.close();probe.closed()
            }catch{probe.failed(error)}
        }
        let actualEntry=await iterator.next();XCTAssertNotNil(actualEntry)
        try work.afterOriginal(owner:owner,capture:{VoiceFilePriorReturn(completion:original,issue:{probe.issue})},operation:{
            try FileManager.default.moveItem(at:input,to:archive)
        },failed:{_ in XCTFail("original consumer failed")})
        XCTAssertFalse(FileManager.default.fileExists(atPath:archive.path));XCTAssertTrue(work.busy)
        gate.release();await work.wait(owner)
        XCTAssertTrue(probe.didClose);XCTAssertNil(probe.issue)
        XCTAssertEqual(try String(contentsOf:archive,encoding:.utf8),"owned reference")
        XCTAssertTrue(work.release(owner).isReleased)
    }
    @MainActor func testReentrantStopDuringCaptureStillJoinsOriginalAndRefusesProfileMutation()async throws{
        let work=VoiceFileWork(),owner=VoiceFoundationOwner(),gate=FileWorkAsyncGate()
        let original=Task{await gate.wait()}
        var moved=false
        try work.afterOriginal(owner:owner,capture:{
            work.close(owner)
            return VoiceFilePriorReturn(completion:original,issue:{nil})
        },operation:{moved=true},failed:{_ in XCTFail("invented original failure")})
        XCTAssertTrue(work.busy);XCTAssertFalse(work.release(owner).isReleased)
        await Task.yield();XCTAssertTrue(work.busy);XCTAssertFalse(moved)
        await gate.release();await work.wait(owner)
        XCTAssertFalse(moved);XCTAssertTrue(work.release(owner).isReleased)
    }
    @MainActor func testPendingSyncOriginalAndForeignTokenCannotBeReportedReleased()async throws{
        let work=VoiceFileWork(),other=VoiceFileWork(),owner=VoiceFoundationOwner()
        let original=try work.begin(owner),foreign=try other.begin(owner)
        work.close(owner);work.finish(foreign)
        XCTAssertTrue(work.busy);XCTAssertFalse(work.release(owner).isReleased)
        XCTAssertThrowsError(try work.operation(owner:owner){XCTFail("admitted new file IO")})
        work.finish(original);await work.wait(owner)
        XCTAssertTrue(work.release(owner).isReleased)
        other.finish(foreign)
    }
    @MainActor func testAdmittedAssetProducerDeliveryReturnsBeforeFileRelease()async throws{
        let work=VoiceFileWork(),owner=VoiceFoundationOwner(),gate=VoiceAudioCallbackAdmission()
        work.retainCallbacks(gate,owner:owner)
        let delivery=try XCTUnwrap(gate.enter())
        work.close(owner);gate.seal();gate.nativeStopReturned()
        XCTAssertFalse(work.release(owner).isReleased)
        delivery.finish();await work.wait(owner)
        XCTAssertTrue(work.release(owner).isReleased);XCTAssertNil(gate.enter())
    }
    @MainActor func testReturnedOperationFailureAndUnknownPrerequisiteRemainDifferent()async throws{
        let work=VoiceFileWork(),owner=VoiceFoundationOwner()
        XCTAssertThrowsError(try work.operation(owner:owner){throw NSError(domain:"authored.write",code:9)})
        if case .released(.failed)=work.release(owner){}else{XCTFail("returned write failure was not retained")}
        let unknown=VoiceFileWork(),other=VoiceFoundationOwner()
        try unknown.afterOriginal(owner:other,capture:{VoiceFilePriorReturn(completion:nil,issue:{"original-return-unknown"})},operation:{XCTFail("mutated profile without original return")},failed:{_ in})
        await unknown.wait(other)
        if case .unknown("original-return-unknown")=unknown.release(other){}else{XCTFail("unknown resource was called released")}
        XCTAssertFalse(VoiceFileWork.aggregate([work.release(owner),unknown.release(other)]).isReleased)
    }
    @MainActor func testGlobalCloseSealsEveryOwnerAndJoinsFailedOriginalOperation()async throws{
        let work=VoiceFileWork(),owner=VoiceFoundationOwner()
        var failed=false
        try work.start(owner:owner,work:{Result<Bool,Error>.failure(NSError(domain:"authored.operation",code:8))}){result in
            if case .failure=result{failed=true}
        }
        // Let the admitted worker complete; an operation failure still has an
        // actual original return, independently of its result.
        await work.wait(owner);XCTAssertTrue(failed)
        work.close(nil)
        XCTAssertThrowsError(try work.start(owner:VoiceFoundationOwner(),work:{true}){_ in})
    }
}
private final class FileWorkBlockingGate:@unchecked Sendable{
    private let semaphore=DispatchSemaphore(value:0)
    func wait(){semaphore.wait()}
    func release(){semaphore.signal()}
}
private final class FileWorkProbe:@unchecked Sendable{
    private let lock=NSLock();private var value=false
    var started:Bool{lock.lock();defer{lock.unlock()};return value}
    func start(){lock.lock();value=true;lock.unlock()}
}
private actor FileWorkAsyncGate{
    private var open=false,waiters:[CheckedContinuation<Void,Never>]=[]
    func wait()async{if open{return};await withCheckedContinuation{waiters.append($0)}}
    func release(){open=true;let originals=waiters;waiters=[];for original in originals{original.resume()}}
}

private final class FileWorkReaderProbe:@unchecked Sendable{
    private let lock=NSLock();private var closeReturned=false,error:String?
    func opened(){}
    func closed(){lock.lock();closeReturned=true;lock.unlock()}
    func failed(_ value:Error){lock.lock();error=value.localizedDescription;lock.unlock()}
    var issue:String?{lock.lock();defer{lock.unlock()};return error}
    var didClose:Bool{lock.lock();defer{lock.unlock()};return closeReturned}
}
