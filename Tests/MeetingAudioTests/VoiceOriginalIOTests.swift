import XCTest
import Foundation
import Darwin
@testable import VoiceAudio

@MainActor final class VoiceOriginalIOTests:XCTestCase{
    private func until(_ body:()->Bool)async throws{
        let end=ContinuousClock.now + .seconds(5)
        while !body(){guard ContinuousClock.now<end else{throw NSError(domain:"VoiceOriginalIOTests.timeout",code:1)};try await Task.sleep(for:.milliseconds(10))}
    }
    func testEnteredReadCallbackKeepsOriginalFDOpenUntilItsActualReturn()async throws{
        let pipe=Pipe(),receipt=MeetingCleanupReceipt(),gate=OriginalIOGate()
        let closer=VoiceOriginalIOClose(receipt)
        let reader=VoiceOriginalPipeReader(handle:pipe.fileHandleForReading,closer:closer)
        let stream=AsyncThrowingStream<Data,Error>.makeStream(bufferingPolicy:.bufferingOldest(64))
        reader.install(stream.continuation,checkpoint:{gate.enterAndWait()})
        defer{gate.release()}
        let fd=pipe.fileHandleForReading.fileDescriptor
        try pipe.fileHandleForWriting.write(contentsOf:Data("authored pipe".utf8))
        try await until{gate.entered}
        let original=reader.retire()
        XCTAssertNotEqual(fcntl(fd,F_GETFD),-1,"closed the FD while its admitted callback was still entered")
        let unrelated=Pipe()
        XCTAssertNotEqual(unrelated.fileHandleForReading.fileDescriptor,fd)
        gate.release();await original.value
        closer.close(pipe.fileHandleForWriting,context:"authored pipe writer close")
        closer.close(unrelated.fileHandleForReading,context:"authored unrelated reader close")
        closer.close(unrelated.fileHandleForWriting,context:"authored unrelated writer close")
        XCTAssertNil(receipt.issue)
    }
    func testActualBoundedPipeBytesAndEOFAreDeliveredBeforeOriginalClose()async throws{
        let pipe=Pipe(),receipt=MeetingCleanupReceipt()
        let closer=VoiceOriginalIOClose(receipt)
        let reader=VoiceOriginalPipeReader(handle:pipe.fileHandleForReading,closer:closer)
        let stream=AsyncThrowingStream<Data,Error>.makeStream(bufferingPolicy:.bufferingOldest(64))
        reader.install(stream.continuation)
        let received=Task{var data=Data();for try await chunk in stream.stream{data.append(chunk)};return data}
        let authored=Data("authored response\n".utf8)
        try pipe.fileHandleForWriting.write(contentsOf:authored)
        closer.close(pipe.fileHandleForWriting,context:"authored EOF close")
        let value=try await received.value
        await reader.retire().value
        XCTAssertEqual(value,authored);XCTAssertNil(receipt.issue)
    }
    func testCloseFailureIsFirstAndRetainedAcrossHealthyHandleReplacement()throws{
        let receipt=MeetingCleanupReceipt(),closer=VoiceOriginalIOClose(receipt),old=Pipe(),replacement=Pipe()
        closer.close(old.fileHandleForReading,context:"authored original close"){_ in throw NSError(domain:"authored.close",code:12)}
        let first=try XCTUnwrap(receipt.issue)
        closer.close(old.fileHandleForReading,context:"repeated old close"){_ in XCTFail("retried a failed original close")}
        closer.close(replacement.fileHandleForReading,context:"healthy replacement reader")
        closer.close(replacement.fileHandleForWriting,context:"healthy replacement writer")
        XCTAssertEqual(receipt.issue,first)
        // Fixture recovery only, not part of production's no-retry receipt.
        try old.fileHandleForReading.close();try old.fileHandleForWriting.close()
    }
    func testOldOriginalIssueCannotDisappearWhenHealthyReplacementReturnsFirst()async throws{
        let outcomes=VoiceOriginalIOOutcomes(),oldReceipt=MeetingCleanupReceipt(),gate=OriginalIOAsyncGate()
        let old=Task{await gate.wait()}
        let joined=try XCTUnwrap(outcomes.join(old,issue:{oldReceipt.issue}))
        let replacement=outcomes.join(Task{},issue:{nil})
        await replacement?.value
        XCTAssertNil(outcomes.issue)
        oldReceipt.record("authored original I/O close failure")
        XCTAssertNil(outcomes.issue,"reported an original outcome before its actual return")
        await gate.release();await joined.value
        XCTAssertEqual(outcomes.issue,"authored original I/O close failure")
        await outcomes.join(Task{},issue:{nil})?.value
        XCTAssertEqual(outcomes.issue,"authored original I/O close failure")
    }
    private func fixture()throws->URL{
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("voice-io-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        let script="""
        import json,os,signal,sys,time
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        with open(os.path.join(sys.argv[1],'pid'),'w') as f:f.write(str(os.getpid()))
        print(json.dumps(dict(type='ready',version=2)),flush=True)
        while True:time.sleep(0.05)
        """
        try script.write(to:root.appendingPathComponent("worker.py"),atomically:true,encoding:.utf8)
        return root
    }
    func testReentrantStopBeforeWaiterPublicationJoinsLateOriginalChildAndTimer()async throws{
        let root=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let service=MeetingLiveTranscriber()
        defer{service.didLaunchBeforeWait=nil;service.cancel()}
        var stoppedAt:ContinuousClock.Instant?
        service.didLaunchBeforeWait={
            let end=Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath:root.appendingPathComponent("pid").path),Date()<end{usleep(1000)}
            XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("pid").path))
            stoppedAt=ContinuousClock.now;service.cancel()
        }
        do{
            try await service.startPreparedWorker(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:[root.appendingPathComponent("worker.py").path,root.path],update:{_ in XCTFail("published after Stop")},failure:{_ in})
            XCTFail("reentrant Stop prepared a recognizer")
        }catch{XCTAssertTrue(error is CancellationError)}
        await service.cancelAndWait()
        XCTAssertNil(service.resourceReturnIssue)
        let stamp=try XCTUnwrap(stoppedAt)
        XCTAssertGreaterThanOrEqual(stamp.duration(to:ContinuousClock.now),.milliseconds(800))
        let text=try String(contentsOf:root.appendingPathComponent("pid"),encoding:.utf8)
        let pid=try XCTUnwrap(Int32(text))
        var status:Int32=0;errno=0
        XCTAssertEqual(waitpid(pid,&status,WNOHANG),-1);XCTAssertEqual(errno,ECHILD)
    }
    func testLiveStopJoinsEnteredReadBeforeClosingAndReportsCapturedContextIssue()async throws{
        let root=try fixture(),gate=OriginalIOGate(),receipt=MeetingCleanupReceipt()
        defer{gate.release();try? FileManager.default.removeItem(at:root)}
        let service=MeetingLiveTranscriber();service.outputReadCheckpoint={gate.enterAndWait()}
        defer{service.cancel()}
        let start=Task{
            try await MeetingCleanupContext.$current.withValue(receipt){
                try await service.startPreparedWorker(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:[root.appendingPathComponent("worker.py").path,root.path],update:{_ in},failure:{_ in})
            }
        }
        try await until{gate.entered}
        service.cancel()
        var returned=false
        let retired=Task{await service.cancelAndWait();returned=true}
        await Task.yield();XCTAssertFalse(returned)
        receipt.record("authored captured original close uncertainty")
        gate.release();_=try? await start.value;await retired.value
        XCTAssertTrue(returned)
        XCTAssertEqual(service.resourceReturnIssue,"authored captured original close uncertainty")
    }
}
private final class OriginalIOGate:@unchecked Sendable{
    private let lock=NSLock(),semaphore=DispatchSemaphore(value:0)
    private var enteredValue=false
    var entered:Bool{lock.lock();defer{lock.unlock()};return enteredValue}
    func enterAndWait(){lock.lock();enteredValue=true;lock.unlock();semaphore.wait()}
    func release(){semaphore.signal()}
}
private actor OriginalIOAsyncGate{
    private var open=false,waiters:[CheckedContinuation<Void,Never>]=[]
    func wait()async{if open{return};await withCheckedContinuation{waiters.append($0)}}
    func release(){open=true;let old=waiters;waiters=[];for original in old{original.resume()}}
}
