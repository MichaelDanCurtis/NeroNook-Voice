import XCTest
import Foundation
import NookPluginSDK
import Darwin
import Security
@testable import NookLocalServiceKit
@testable import ModuleApp

/// The production output/owned-request classes with authored write completions.
/// These tests do not fabricate native peer identity, service consent or a model.
final class VoiceServiceContextTests:XCTestCase{
    @MainActor func testProviderHandleKeepsOriginalSessionAndWriterAcrossOutputReplacement()async throws{
        let sessionA=UUID(),sessionB=UUID(),requestA=UUID(),requestB=UUID(),gate=ProviderWriteGate()
        let first=AuthoredMessageCollector(),second=AuthoredMessageCollector()
        let a=VoiceOutput(pluginID:"example.voice",channel:nil,test:false,sharedSink:{message in
            first.messages.append(message)
            return Task{await gate.wait();return true}
        })
        a.begin(sessionA)
        let original=VoiceOwnedProviderRequest(requestID:requestA,session:sessionA,output:a)
        try original.invoke(address:.init("example.calendar","read"),values:[:])
        let barrier=original.writeBarrier()
        let b=VoiceOutput(pluginID:"example.voice",channel:nil,test:false,sharedSink:{message in
            second.messages.append(message);return Task{true}
        })
        b.begin(sessionB)
        let replacement=VoiceOwnedProviderRequest(requestID:requestB,session:sessionB,output:b)
        try replacement.invoke(address:.init("example.calendar","read"),values:[:])
        try original.cancel()
        let cancellationBarrier=original.writeBarrier()
        XCTAssertEqual(first.messages.count,2);XCTAssertEqual(second.messages.count,1)
        XCTAssertTrue(first.messages.allSatisfy{$0.session==sessionA && $0.bus?.requestID==requestA})
        XCTAssertTrue(second.messages.allSatisfy{$0.session==sessionB && $0.bus?.requestID==requestB})
        a.stop()
        XCTAssertThrowsError(try original.cancel())
        XCTAssertEqual(second.messages.count,1)
        await gate.release();await barrier.value;await cancellationBarrier.value
        XCTAssertNil(original.writeIssue)
        await a.retirement();await b.retirement()
    }
    @MainActor func testCapturedWriteFailureCannotBeErasedByHealthyReplacement()async throws{
        let gate=ProviderWriteGate(),a=VoiceOutput(pluginID:"example.voice",channel:nil,test:false,sharedSink:{_ in
            Task{await gate.wait();return false}
        })
        let session=UUID();a.begin(session)
        let original=VoiceOwnedProviderRequest(requestID:UUID(),session:session,output:a)
        try original.invoke(address:.init("example.calendar","read"),values:[:])
        let barrier=original.writeBarrier()
        let b=VoiceOutput(pluginID:"example.voice",channel:nil,test:false,sharedSink:{_ in Task{true}})
        b.begin(UUID())
        await gate.release();await barrier.value
        XCTAssertEqual(original.writeIssue,"output-write-failed")
        XCTAssertNil(b.writeIssue)
        await a.retirement();await b.retirement()
    }
    @MainActor func testSharedOutputReservesFIFOInCallerBeforeReturning()async throws{
        let collector=AuthoredMessageCollector(),gate=ProviderWriteGate()
        let output=VoiceOutput(pluginID:"example.voice",channel:nil,test:false,sharedSink:{message in
            collector.messages.append(message)
            return Task{await gate.wait();return true}
        })
        output.begin(UUID())
        try output.emit("ready")
        XCTAssertEqual(collector.messages.map(\.sequence),[0])
        try output.emit("heartbeat")
        try output.emit("heartbeat")
        XCTAssertEqual(collector.messages.map(\.sequence),[0,1,2])
        let barrier=output.writeBarrier()
        output.stop()
        XCTAssertThrowsError(try output.emit("heartbeat"))
        XCTAssertEqual(collector.messages.count,3)
        await gate.release();await barrier.value;await output.retirement()
    }
    @MainActor func testSynchronousContextQueueRefusalReturnsToOriginalCaller()async throws{
        let output=VoiceOutput(pluginID:"example.voice",channel:nil,test:false,sharedSink:{_ in
            throw VoiceServiceProblem.busy
        })
        output.begin(UUID())
        XCTAssertThrowsError(try output.emit("ready"))
        await output.retirement()
    }
    @MainActor func testIncomingAndDerivedRequestsShareOneThirtyTwoRunBudget()throws{
        let budget=VoiceClientRunBudget()
        var originals=[VoiceClientRunBudget.Reservation]()
        for i in 0..<32 { originals.append(try budget.reserve(UUID(),kind:i%2 == 0 ? .incoming : .provider)) }
        let refused=UUID()
        XCTAssertThrowsError(try budget.reserve(refused,kind:.provider))
        budget.release(originals[0])
        XCTAssertThrowsError(try budget.reserve(refused,kind:.incoming))
        _=try budget.reserve(UUID(),kind:.incoming)
        XCTAssertThrowsError(try budget.reserve(UUID(),kind:.provider))
    }
    @MainActor func testBothKindsConsumeOneSeenIDLedgerAfterActualRelease()throws{
        let budget=VoiceClientRunBudget(),first=UUID()
        let original=try budget.reserve(first,kind:.provider);budget.release(original)
        XCTAssertThrowsError(try budget.reserve(first,kind:.incoming))
        for i in 1..<4096 {
            let next=try budget.reserve(UUID(),kind:i%2 == 0 ? .incoming:.provider)
            budget.release(next)
        }
        XCTAssertThrowsError(try budget.reserve(UUID(),kind:.incoming))
        XCTAssertThrowsError(try budget.reserve(UUID(),kind:.provider))
    }
    @MainActor func testForeignReservationCannotReleaseOriginalAndCloseCannotReopen()throws{
        let budget=VoiceClientRunBudget(),other=VoiceClientRunBudget(),id=UUID()
        let original=try budget.reserve(id,kind:.provider)
        let foreign=try other.reserve(id,kind:.provider)
        budget.release(foreign)
        for _ in 1..<32 { _=try budget.reserve(UUID(),kind:.incoming) }
        XCTAssertThrowsError(try budget.reserve(UUID(),kind:.incoming))
        budget.close();budget.release(original)
        XCTAssertThrowsError(try budget.reserve(UUID(),kind:.provider))
    }
    @MainActor func testCompletedProviderHistorySurvivesUntilExactContextDetach()async throws{
        let history=VoiceContextProviderHistory(),meeting=UUID(),dictation=UUID()
        try history.record(meeting,source:.meeting);try history.record(dictation,source:.dictation)
        // Terminal active-handle removal has no history-removal entry point.
        XCTAssertEqual(history.retainedCount,2)
        var joined=[String:Set<UUID>]()
        let result=await history.retire{source,ids in
            joined[source == .meeting ? "meeting":"dictation"]=ids
            return .released(.effectUncertain)
        }.value
        XCTAssertTrue(result);XCTAssertEqual(history.retainedCount,0)
        XCTAssertEqual(joined["meeting"],[meeting]);XCTAssertEqual(joined["dictation"],[dictation])
        XCTAssertThrowsError(try history.record(UUID(),source:.meeting))
    }
    @MainActor func testHeldOriginalPreventsPruneAndRepeatedDetachJoinsSameTask()async throws{
        let history=VoiceContextProviderHistory(),request=UUID(),gate=ProviderWriteGate()
        let session=UUID(),output=VoiceOutput(pluginID:"example.voice",channel:nil,test:false,sharedSink:{_ in
            Task{await gate.wait();return true}
        })
        output.begin(session)
        let provider=VoiceOwnedProviderRequest(requestID:request,session:session,output:output)
        try provider.invoke(address:.init("example.assistant","reply"),values:[:])
        let(stream,entered)=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
        var iterator=stream.makeAsyncIterator(),joins=0
        try history.record(request,source:.dictation)
        let original=history.retire{_,ids in
            joins+=1;XCTAssertEqual(ids,[request]);entered.yield(())
            // Actual captured provider retirement joins the held original
            // VoiceOutput receipt; it cannot be substituted with a new writer.
            await provider.retire();return .released(.effectUncertain)
        }
        _=await iterator.next()
        let repeated=history.retire{_,_ in XCTFail("replaced the original join");return .released(.succeeded)}
        XCTAssertEqual(history.retainedCount,1);XCTAssertEqual(joins,1)
        XCTAssertThrowsError(try history.record(UUID(),source:.dictation))
        await gate.release()
        let first=await original.value,second=await repeated.value
        XCTAssertTrue(first);XCTAssertTrue(second);XCTAssertEqual(joins,1);XCTAssertEqual(history.retainedCount,0)
        entered.finish();await output.retirement()
    }
    @MainActor func testForeignAndStaleHistorySnapshotsCannotPruneAnOriginal()async throws{
        let original=VoiceContextProviderHistory(),foreign=VoiceContextProviderHistory(),id=UUID()
        try original.record(id,source:.meeting);try foreign.record(id,source:.meeting)
        let ownSnapshot=original.seal(),foreignSnapshot=foreign.seal()
        XCTAssertFalse(original.pruneJoined(foreignSnapshot,source:.meeting))
        XCTAssertEqual(original.retainedCount,1);XCTAssertEqual(foreign.retainedCount,1)
        let returned=await original.retire{_,ids in XCTAssertEqual(ids,[id]);return .released(.effectUncertain)}.value
        XCTAssertTrue(returned)
        XCTAssertFalse(original.pruneJoined(ownSnapshot,source:.meeting))
        XCTAssertEqual(foreign.retainedCount,1)
    }
    @MainActor func testUnknownFamilyStaysRetainedWhileJoinedOtherFamilyPrunes()async throws{
        let history=VoiceContextProviderHistory(),meeting=UUID(),dictation=UUID()
        try history.record(meeting,source:.meeting);try history.record(dictation,source:.dictation)
        let returned=await history.retire{source,_ in
            source == .meeting ? .unknown("held-original-local-return"):.released(.effectUncertain)
        }.value
        XCTAssertFalse(returned);XCTAssertEqual(history.retainedCount,1)
        let repeated=await history.retire{_,_ in XCTFail("unknown original was replaced");return .released(.succeeded)}.value
        XCTAssertFalse(repeated);XCTAssertEqual(history.retainedCount,1)
    }
    @MainActor func testRepeatedJoinedContextsDoNotAccumulateSlotsOrHistory()async throws{
        let admission=VoiceContextAdmission()
        for _ in 0..<64{
            let slot=try XCTUnwrap(admission.reserve()),history=VoiceContextProviderHistory()
            try history.record(UUID(),source:.meeting);try history.record(UUID(),source:.dictation)
            XCTAssertEqual(admission.occupiedCount,1)
            let returned=await history.retire{_,_ in .released(.effectUncertain)}.value
            XCTAssertTrue(returned);XCTAssertEqual(history.retainedCount,0)
            XCTAssertTrue(admission.finish(slot,allReturned:returned))
            XCTAssertEqual(admission.occupiedCount,0);XCTAssertEqual(admission.unresolvedCount,0)
        }
    }
    @MainActor func testUnknownIOOrWorkKeepsAllFourOriginalAdmissionSlots()throws{
        let admission=VoiceContextAdmission()
        for _ in 0..<4{
            let original=try XCTUnwrap(admission.reserve())
            // Runtime passes final work AND native I/O/ack result here. A live
            // socket census or returned work alone cannot free this slot.
            XCTAssertTrue(admission.finish(original,allReturned:false))
        }
        XCTAssertEqual(admission.occupiedCount,4);XCTAssertEqual(admission.unresolvedCount,4)
        XCTAssertNil(admission.reserve())
    }
    @MainActor func testForeignOrStaleAdmissionReceiptCannotFreeCurrentSlot()throws{
        let admission=VoiceContextAdmission(),foreign=VoiceContextAdmission()
        let old=try XCTUnwrap(admission.reserve()),other=try XCTUnwrap(foreign.reserve())
        XCTAssertFalse(admission.finish(other,allReturned:true));XCTAssertEqual(admission.occupiedCount,1)
        XCTAssertTrue(admission.finish(old,allReturned:true))
        let replacement=try XCTUnwrap(admission.reserve())
        XCTAssertFalse(admission.finish(old,allReturned:true));XCTAssertEqual(admission.occupiedCount,1)
        XCTAssertTrue(admission.finish(replacement,allReturned:false));XCTAssertEqual(admission.unresolvedCount,1)
    }
    @MainActor func testGlobalClientReleaseRequiresActualJoinedSlotsAndNoQuarantine()throws{
        let admission=VoiceContextAdmission()
        XCTAssertTrue(admission.releaseAfterJoiningClients(originalsReturned:true,quarantinedContexts:0).isReleased)
        XCTAssertFalse(admission.releaseAfterJoiningClients(originalsReturned:false,quarantinedContexts:0).isReleased)
        let actual=try XCTUnwrap(admission.reserve())
        XCTAssertFalse(admission.releaseAfterJoiningClients(originalsReturned:true,quarantinedContexts:0).isReleased)
        XCTAssertTrue(admission.finish(actual,allReturned:true))
        XCTAssertTrue(admission.releaseAfterJoiningClients(originalsReturned:true,quarantinedContexts:0).isReleased)
        // A retained quarantined object is an independent unknown even if a
        // bookkeeping inconsistency were to leave the slot map empty.
        XCTAssertFalse(admission.releaseAfterJoiningClients(originalsReturned:true,quarantinedContexts:1).isReleased)
    }
    @MainActor func testGlobalClientReleaseRefusesUnknownPrecontextAndRetiredNativeContext()throws{
        let beforeContext=VoiceContextAdmission(),retiredContext=VoiceContextAdmission()
        let reservedBeforeConstruction=try XCTUnwrap(beforeContext.reserve())
        XCTAssertTrue(beforeContext.finish(reservedBeforeConstruction,allReturned:false))
        // No VoiceClientContext was ever constructed, yet the native original
        // had an unknown return. Zero objects cannot make this family clean.
        XCTAssertFalse(beforeContext.releaseAfterJoiningClients(originalsReturned:true,quarantinedContexts:0).isReleased)
        let native=try XCTUnwrap(retiredContext.reserve())
        XCTAssertTrue(retiredContext.finish(native,allReturned:false))
        XCTAssertFalse(retiredContext.releaseAfterJoiningClients(originalsReturned:true,quarantinedContexts:1).isReleased)
        XCTAssertEqual(retiredContext.occupiedCount,1);XCTAssertEqual(retiredContext.unresolvedCount,1)
    }
    @MainActor func testCompletedHistoryIsBoundedBeforeDetach()async throws{
        let history=VoiceContextProviderHistory()
        for i in 0..<4096{try history.record(UUID(),source:i%2 == 0 ? .meeting:.dictation)}
        XCTAssertThrowsError(try history.record(UUID(),source:.meeting));XCTAssertEqual(history.retainedCount,4096)
        var count=0
        let returned=await history.retire{_,ids in count+=ids.count;return .released(.effectUncertain)}.value
        XCTAssertTrue(returned);XCTAssertEqual(count,4096);XCTAssertEqual(history.retainedCount,0)
    }
    @MainActor func testOriginalOutputCannotBeReboundToAnotherSession()async throws{
        let collector=AuthoredMessageCollector()
        let output=VoiceOutput(pluginID:"example.voice",channel:nil,test:false,sharedSink:{message in
            collector.messages.append(message);return Task{true}
        })
        let originalSession=UUID();output.begin(originalSession)
        let original=VoiceOwnedProviderRequest(requestID:UUID(),session:originalSession,output:output)
        output.begin(UUID())
        XCTAssertEqual(output.writeIssue,"session-rebind-refused")
        XCTAssertThrowsError(try original.cancel())
        XCTAssertTrue(collector.messages.isEmpty)
        await output.retirement()
    }
}
@MainActor private final class AuthoredMessageCollector{var messages:[PluginMessage]=[]}
private actor ProviderWriteGate{
    private var open=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    func wait()async{if open{return};await withCheckedContinuation{waiters.append($0)}}
    func release(){open=true;let originals=waiters;waiters.removeAll();originals.forEach{$0.resume()}}
}

// Exercise the actual isolated runtime and the actual SDK listener's retained
// close/unlink completion. The unique native service and parent are authored
// for this test; no peer, device, model, GUI or user store is opened.
extension VoiceServiceContextTests {
    @MainActor private func listenerFixture() async throws -> (VoiceServiceRuntime, VoiceServicePreparedStart, URL) {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        XCTAssertEqual(SecCodeCopySelf(SecCSFlags(), &code), errSecSuccess)
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), SecCSFlags(), &staticCode), errSecSuccess)
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode), SecCSFlags(), &requirement), errSecSuccess)
        XCTAssertEqual(SecCodeCheckValidity(try XCTUnwrap(code), SecCSFlags.noNetworkAccess, try XCTUnwrap(requirement)), errSecSuccess)
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), SecCSFlags(), &text), errSecSuccess)
        let service = "test.nero.listener.s" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let native = try LocalServicePolicy(serviceIdentifier: service,
            trustedSelfRequirements: ["listener-test": try XCTUnwrap(text) as String],
            trustedPeerRequirements: ["listener-test": try XCTUnwrap(text) as String])
        let parent = URL(fileURLWithPath: "/private/tmp/nero-listener-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let policy = try VoiceServicePolicy(native: native, serviceIdentifier: service, moduleIdentifier: service,
            fullModulePolicyKey: "listener-test", capabilityPolicyKeys: [], lifecycleRoot: parent,
            resourceRevision: String(repeating: "0", count: 64), buildIdentifier: "authored-listener",
            permitsGlobalControls: false)
        let outcome = await VoiceServiceStartup.prepare(plan: .freshIsolated(parent: parent)) { policy }
        guard case .ready(let prepared) = outcome else { throw VoiceServiceProblem.unavailable }
        let product = try VoiceProductConfiguration.isolated(
            root: prepared.policy.lifecycleRoot.appendingPathComponent("Product", isDirectory: true),
            revalidate: { try prepared.revalidateProductRoot() })
        let runtime = try VoiceServiceRuntime(owner: prepared.owner, policy: prepared.policy,
            ledger: prepared.ledger, epochID: prepared.epoch, productConfiguration: product)
        try runtime.start()
        return (runtime, prepared, parent)
    }

    @MainActor func testActualListenerReturnFailurePreventsRuntimeClean() async throws {
        let (runtime, prepared, parent) = try await listenerFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = prepared.owner.lock.root
        let name = root.digest + ".sock"
        var original = stat(), named = stat()
        XCTAssertEqual(fstatat(root.directoryFD, name, &original, AT_SYMLINK_NOFOLLOW), 0)
        XCTAssertEqual(original.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(fstatat(root.directoryFD, name, &named, AT_SYMLINK_NOFOLLOW), 0)
        XCTAssertEqual(original.st_dev, named.st_dev); XCTAssertEqual(original.st_ino, named.st_ino)
        guard original.st_mode & S_IFMT == S_IFSOCK,
              original.st_dev == named.st_dev, original.st_ino == named.st_ino,
              unlinkat(root.directoryFD, name, 0) == 0 else { throw VoiceServiceProblem.unavailable }
        let fd = openat(root.directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VoiceServiceProblem.unavailable }
        let marker = Data("authored-listener-marker".utf8)
        let written = marker.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        XCTAssertEqual(written, marker.count); XCTAssertEqual(Darwin.close(fd), 0)
        let first = await runtime.shutdown()
        let second = await runtime.shutdown()
        XCTAssertFalse(first); XCTAssertFalse(second)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root.socketPath)), marker)
        let record = prepared.policy.lifecycleRoot.appendingPathComponent("lifecycle-v1.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "recoveryRequired")
        // The marker is deliberately preserved. The SDK's permanent lock/root
        // are never removed or derived from another service's identity.
    }

    @MainActor func testActualListenerReturnSuccessAllowsRuntimeClean() async throws {
        let (runtime, prepared, parent) = try await listenerFixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = await runtime.shutdown()
        let second = await runtime.shutdown()
        XCTAssertTrue(first); XCTAssertTrue(second)
        let record = prepared.policy.lifecycleRoot.appendingPathComponent("lifecycle-v1.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        XCTAssertEqual(json["state"] as? String, "clean")
    }
}
