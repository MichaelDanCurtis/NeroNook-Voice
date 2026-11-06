import XCTest
import Foundation
import Security
import Darwin
import NookLocalServiceKit
@testable import ModuleApp

final class VoiceNormalEnrollmentTests: XCTestCase {
    private func fixture(parentExists:Bool=false) throws -> (VoiceServicePolicy,URL) {
        var code:SecCode?,staticCode:SecStaticCode?,requirement:SecRequirement?,text:CFString?
        XCTAssertEqual(SecCodeCopySelf(SecCSFlags(),&code),errSecSuccess)
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code),SecCSFlags(),&staticCode),errSecSuccess)
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode),SecCSFlags(),&requirement),errSecSuccess)
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement),SecCSFlags(),&text),errSecSuccess)
        let service="test.nero.normal.s"+UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:"")
        let native=try LocalServicePolicy(serviceIdentifier:service,
            trustedSelfRequirements:["normal-test":try XCTUnwrap(text) as String],
            trustedPeerRequirements:["normal-test":try XCTUnwrap(text) as String])
        let base=URL(fileURLWithPath:"/private/tmp/nero-normal-enrollment-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let parent=base.appendingPathComponent("NeroVoice",isDirectory:true)
        if parentExists{try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false,attributes:[.posixPermissions:0o755])}
        let policy=try VoiceServicePolicy(native:native,serviceIdentifier:service,moduleIdentifier:service,
            fullModulePolicyKey:"normal-test",capabilityPolicyKeys:[],
            lifecycleRoot:parent.appendingPathComponent("ServiceLifecycle",isDirectory:true),
            resourceRevision:String(repeating:"0",count:64),buildIdentifier:"normal-authored",permitsGlobalControls:true)
        return(policy,base)
    }
    private func opportunity(_ policy:VoiceServicePolicy) async throws -> VoiceNormalEnrollment {
        let result=await VoiceServiceStartup.prepare(plan:.normal){policy}
        guard case .enrollmentRequired(let offer)=result else{throw NSError(domain:"normal-enrollment-opportunity",code:1)}
        return offer
    }
    private func record(_ root:URL) throws -> [String:Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("lifecycle-v1.json")))as?[String:Any])
    }

    func testNormalOfferWritesNothingAndKeepsOriginalNativeOwner() async throws {
        let(policy,base)=try fixture();defer{try? FileManager.default.removeItem(at:base)}
        let offer=try await opportunity(policy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:base.path),[])
        XCTAssertThrowsError(try LocalServiceOwner.acquire(policy:policy.native))
        try offer.owner.revalidate();try offer.closeAfterConsumption()
    }
    func testOrdinaryExistingPlanStillRefusesAndCannotOfferEnrollment() async throws {
        let(policy,base)=try fixture();defer{try? FileManager.default.removeItem(at:base)}
        let result=await VoiceServiceStartup.prepare(plan:.existing){policy}
        guard case .failed(let failure)=result else{return XCTFail("Existing plan enrolled/offered missing lineage")}
        XCTAssertNotNil(failure.owner);XCTAssertNil(failure.cleanupIssue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:base.path),[])
    }
    func testExistingEmptyRootIsNeverRepairedOrOffered() async throws {
        let(policy,base)=try fixture(parentExists:true);defer{try? FileManager.default.removeItem(at:base)}
        try FileManager.default.createDirectory(at:policy.lifecycleRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let before=try FileManager.default.attributesOfItem(atPath:policy.lifecycleRoot.path)
        let result=await VoiceServiceStartup.prepare(plan:.normal){policy}
        guard case .failed(let failure)=result else{return XCTFail("Existing empty root became enrollment")}
        XCTAssertEqual(failure.error as? VoiceLifecycleFailure,.missingRecord)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:policy.lifecycleRoot.path),[])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:policy.lifecycleRoot.path)[.systemFileNumber]as?NSNumber,before[.systemFileNumber]as?NSNumber)
    }
    func testExistingMalformedHistoryBytesArePreservedWithoutOffer() async throws {
        let(policy,base)=try fixture(parentExists:true);defer{try? FileManager.default.removeItem(at:base)}
        try FileManager.default.createDirectory(at:policy.lifecycleRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let file=policy.lifecycleRoot.appendingPathComponent("lifecycle-v1.json"),bytes=Data("authored incomplete prior history".utf8)
        try bytes.write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        let result=await VoiceServiceStartup.prepare(plan:.normal){policy}
        guard case .failed=result else{return XCTFail("Malformed history offered enrollment")}
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testConfirmedNormalCreatesFirstActiveUsingSameOwnerAndNoCleanSeed() async throws {
        let(policy,base)=try fixture();defer{try? FileManager.default.removeItem(at:base)}
        let offer=try await opportunity(policy),owner=offer.owner
        let result=await VoiceServiceStartup.enroll(offer)
        guard case .ready(let prepared)=result else{return XCTFail("Normal first enrollment failed")}
        XCTAssertTrue(prepared.owner === owner);XCTAssertFalse(prepared.isolated)
        XCTAssertEqual(prepared.policy.lifecycleRoot,policy.lifecycleRoot)
        let value=try record(policy.lifecycleRoot)
        XCTAssertEqual(value["state"]as?String,"active")
        XCTAssertEqual(value["epochID"]as?String,prepared.epoch.uuidString)
        XCTAssertEqual(value["releasedFamilies"]as?[String],[])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:policy.lifecycleRoot.path)[.posixPermissions]as?NSNumber,NSNumber(value:0o700))
        let bytes=try Data(contentsOf:policy.lifecycleRoot.appendingPathComponent("lifecycle-v1.json"))
        let issue=await prepared.ledger.retireStartupHandles();XCTAssertNil(issue)
        XCTAssertEqual(try Data(contentsOf:policy.lifecycleRoot.appendingPathComponent("lifecycle-v1.json")),bytes)
        XCTAssertNil(try VoiceNormalEnrollment.inspect(policy:policy,owner:owner,binding:offer.binding))
    }
    func testExistingLegacyParentAndSentinelAreRetained() async throws {
        let(policy,base)=try fixture(parentExists:true);defer{try? FileManager.default.removeItem(at:base)}
        let parent=policy.lifecycleRoot.deletingLastPathComponent(),sentinel=parent.appendingPathComponent("legacy-meeting.txt")
        let bytes=Data("original legacy bytes".utf8);try bytes.write(to:sentinel)
        let offer=try await opportunity(policy);let result=await VoiceServiceStartup.enroll(offer)
        guard case .ready(let prepared)=result else{return XCTFail("Existing safe legacy parent refused")}
        XCTAssertEqual(try Data(contentsOf:sentinel),bytes)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath:parent.path)[.posixPermissions]as?NSNumber,NSNumber(value:0o755))
        let issue=await prepared.ledger.retireStartupHandles();XCTAssertNil(issue)
    }
    func testRootAppearingDuringConfirmationRefusesWithoutOverwrite() async throws {
        let(policy,base)=try fixture(parentExists:true);defer{try? FileManager.default.removeItem(at:base)}
        let offer=try await opportunity(policy)
        try FileManager.default.createDirectory(at:policy.lifecycleRoot,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let sentinel=policy.lifecycleRoot.appendingPathComponent("retained.txt"),bytes=Data("raced authored history".utf8)
        try bytes.write(to:sentinel)
        guard case .failed=await VoiceServiceStartup.enroll(offer)else{return XCTFail("Replaced root appearing during confirmation")}
        XCTAssertEqual(try Data(contentsOf:sentinel),bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:policy.lifecycleRoot.appendingPathComponent("lifecycle-v1.json").path))
    }
    func testParentReplacementDuringConfirmationRefusesBothOriginalsPreserved() async throws {
        let(policy,base)=try fixture(parentExists:true);defer{try? FileManager.default.removeItem(at:base)}
        let offer=try await opportunity(policy),parent=policy.lifecycleRoot.deletingLastPathComponent(),kept=base.appendingPathComponent("kept-NeroVoice")
        try FileManager.default.moveItem(at:parent,to:kept)
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        guard case .failed=await VoiceServiceStartup.enroll(offer)else{return XCTFail("Accepted replacement parent")}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:kept.path),[])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:parent.path),[])
    }
    func testCancelledCreationJoinsOriginalAndLeavesUncommittedRootForRecovery() async throws {
        let(policy,base)=try fixture(),gate=NormalCreationGate();defer{gate.release();try? FileManager.default.removeItem(at:base)}
        let offer=try await opportunity(policy)
        let task=Task{await VoiceServiceStartup.enroll(offer,checkpoint:{gate.enterAndWait()})}
        let deadline=ContinuousClock.now + .seconds(5)
        while !gate.entered{guard ContinuousClock.now<deadline else{throw NSError(domain:"normal-gate-timeout",code:1)};await Task.yield()}
        task.cancel();XCTAssertTrue(FileManager.default.fileExists(atPath:policy.lifecycleRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:policy.lifecycleRoot.appendingPathComponent("lifecycle-v1.json").path))
        gate.release()
        guard case .failed(let failure)=await task.value else{return XCTFail("Cancelled creation returned admission")}
        XCTAssertTrue(failure.error is CancellationError);XCTAssertNil(failure.cleanupIssue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:policy.lifecycleRoot.path),[])
        XCTAssertNil(try VoiceNormalEnrollment.inspect(policy:policy,owner:offer.owner,binding:offer.binding))
    }
    @MainActor func testActualBootstrapCancelDoesNotConstructProductOrCreateRoot() async throws {
        let(policy,base)=try fixture();defer{try? FileManager.default.removeItem(at:base)}
        let prompt=NormalHeldPrompt(answer:false)
        let bootstrap=VoiceServiceBootstrap(normalPolicy:policy,prompt:{prompt})
        await bootstrap.startupCompletion?.value;XCTAssertTrue(bootstrap.canEnroll)
        let ownedWindow=EnrollmentOwnedTestWindow();defer{ownedWindow.close()}
        bootstrap.requestNormalEnrollment(from:try XCTUnwrap(ownedWindow.anchor.capture()));await bootstrap.enrollmentCompletion?.value
        XCTAssertEqual(prompt.confirmations,1);XCTAssertNil(bootstrap.runtime);XCTAssertNil(bootstrap.legacy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:base.path),[])
        let returned=await bootstrap.shutdown();XCTAssertTrue(returned)
    }
    @MainActor func testActualBootstrapQuitWaitsPromptAndRejectsLateAcceptAndDoubleClick() async throws {
        let(policy,base)=try fixture();defer{try? FileManager.default.removeItem(at:base)}
        let prompt=NormalHeldPrompt(),bootstrap=VoiceServiceBootstrap(normalPolicy:policy,prompt:{prompt})
        await bootstrap.startupCompletion?.value
        let ownedWindow=EnrollmentOwnedTestWindow();defer{ownedWindow.close()}
        bootstrap.requestNormalEnrollment(from:try XCTUnwrap(ownedWindow.anchor.capture()));bootstrap.requestNormalEnrollment(from:try XCTUnwrap(ownedWindow.anchor.capture()))
        await prompt.waitEntered();XCTAssertEqual(prompt.confirmations,1)
        var returned=false
        let stop=Task{let value=await bootstrap.shutdown();returned=true;return value}
        await prompt.waitCancelled();XCTAssertFalse(returned)
        prompt.answer(true)
        let value=await stop.value;XCTAssertTrue(value);XCTAssertFalse(bootstrap.canEnroll)
        XCTAssertNil(bootstrap.runtime);XCTAssertNil(bootstrap.legacy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:base.path),[])
    }
    @MainActor func testActualBootstrapQuitAfterActiveJoinsBeforeMaterializationWithoutClean() async throws {
        let(policy,base)=try fixture();defer{try? FileManager.default.removeItem(at:base)}
        let prompt=NormalHeldPrompt(answer:true),gate=NormalMaterializationGate()
        let bootstrap=VoiceServiceBootstrap(normalPolicy:policy,prompt:{prompt},beforeMaterialization:{prepared in
            XCTAssertEqual(try? self.record(prepared.policy.lifecycleRoot)["state"]as?String,"active")
            await gate.hold()
        })
        await bootstrap.startupCompletion?.value
        let ownedWindow=EnrollmentOwnedTestWindow();defer{ownedWindow.close()}
        bootstrap.requestNormalEnrollment(from:try XCTUnwrap(ownedWindow.anchor.capture()));await gate.waitEntered()
        XCTAssertNil(bootstrap.runtime);XCTAssertNil(bootstrap.legacy)
        let active=try Data(contentsOf:policy.lifecycleRoot.appendingPathComponent("lifecycle-v1.json"))
        let stop=Task{await bootstrap.shutdown()}
        let deadline=ContinuousClock.now + .seconds(5)
        while !bootstrap.retirementRequested{guard ContinuousClock.now<deadline else{throw NSError(domain:"normal-quit-timeout",code:1)};await Task.yield()}
        gate.release();let returned=await stop.value;XCTAssertTrue(returned)
        XCTAssertNil(bootstrap.runtime);XCTAssertNil(bootstrap.legacy)
        XCTAssertEqual(try Data(contentsOf:policy.lifecycleRoot.appendingPathComponent("lifecycle-v1.json")),active)
        XCTAssertEqual(try record(policy.lifecycleRoot)["state"]as?String,"active")
    }
    @MainActor func testActualCompositionKeepsPendingInertAndUsesAdmittedNormalAppearance() {
        XCTAssertTrue(VoiceServiceBootstrap.usesPlaceholderAppearance(legacyAvailable:false,runtimeIsolated:nil))
        XCTAssertFalse(VoiceServiceBootstrap.usesPlaceholderAppearance(legacyAvailable:true,runtimeIsolated:nil))
        XCTAssertFalse(VoiceServiceBootstrap.usesPlaceholderAppearance(legacyAvailable:false,runtimeIsolated:false))
        XCTAssertTrue(VoiceServiceBootstrap.usesPlaceholderAppearance(legacyAvailable:false,runtimeIsolated:true))
    }
}

@MainActor private final class NormalHeldPrompt:VoiceNormalEnrollmentPrompt {
    private let entered=AsyncStream<Void>.makeStream(),cancelled=AsyncStream<Void>.makeStream()
    // Native sheet callbacks still belong to their original owner after Task
    // cancellation. AsyncStream iteration ends on cancellation and cannot model
    // that join; keep the authored callback pending until answer() returns it.
    private var response: CheckedContinuation<Bool, Never>?
    private var bufferedAnswer: Bool?
    private let immediate:Bool?
    private(set)var confirmations=0
    init(answer:Bool?=nil){immediate=answer}
    func confirm(_ opportunity:VoiceNormalEnrollment, parent:VoiceEnrollmentWindowAnchor.Snapshot?)async->Bool{
        confirmations+=1;entered.continuation.yield(());entered.continuation.finish()
        if let immediate{return immediate}
        if let bufferedAnswer { return bufferedAnswer }
        return await withCheckedContinuation { response = $0 }
    }
    func cancel(){cancelled.continuation.yield(());cancelled.continuation.finish()}
    func answer(_ value:Bool){
        bufferedAnswer=value
        let original=response;response=nil;original?.resume(returning:value)
    }
    func waitEntered()async{for await _ in entered.stream{}}
    func waitCancelled()async{for await _ in cancelled.stream{}}
}
@MainActor private final class NormalMaterializationGate {
    private let entered=AsyncStream<Void>.makeStream(),released=AsyncStream<Void>.makeStream()
    func hold()async{entered.continuation.yield(());entered.continuation.finish();for await _ in released.stream{}}
    func waitEntered()async{for await _ in entered.stream{}}
    func release(){released.continuation.yield(());released.continuation.finish()}
}
private final class NormalCreationGate:@unchecked Sendable {
    private let lock=NSLock(),semaphore=DispatchSemaphore(value:0)
    private var value=false
    var entered:Bool{lock.lock();defer{lock.unlock()};return value}
    func enterAndWait(){lock.lock();value=true;lock.unlock();semaphore.wait()}
    func release(){semaphore.signal()}
}
