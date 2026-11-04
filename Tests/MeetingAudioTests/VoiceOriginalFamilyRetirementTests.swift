import XCTest
import Foundation
import ModuleCore
@testable import VoiceAudio

/// The actual production original-task owner with authored suspended work. No
/// model, microphone or TTS is invoked; these prove lifecycle mechanics only.
final class VoiceOriginalFamilyRetirementTests: XCTestCase {
    func testCancellationKeepsOriginalModelUntilItsActualReturn() async throws {
        let owner = FoundationOriginalWorkOwner(), gate = FoundationReturnGate()
        let entered = expectation(description: "Original authored model is inside its operation")
        let job = try owner.start(model: true) { entered.fulfill(); await gate.wait() }
        await fulfillment(of: [entered], timeout: 5)
        let originalDrain = owner.drain(seal: false)
        XCTAssertTrue(owner.busy)
        XCTAssertThrowsError(try owner.start(model: true) {})
        await gate.release()
        await originalDrain?.value
        await job.value
        XCTAssertFalse(owner.busy)
    }
    func testDrainJoinsBothOriginalModelAndItsDeadline() async throws {
        let owner = FoundationOriginalWorkOwner(), modelGate = FoundationReturnGate(), timerGate = FoundationReturnGate()
        let modelEntered = expectation(description: "Original model held"), timerEntered = expectation(description: "Original deadline held")
        let model = try owner.start(model: true) { modelEntered.fulfill(); await modelGate.wait() }
        let timer = try owner.start(model: false) { timerEntered.fulfill(); await timerGate.wait() }
        await fulfillment(of: [modelEntered, timerEntered], timeout: 5)
        let original = owner.drain(seal: false)
        await modelGate.release(); await model.value
        XCTAssertTrue(owner.busy)
        await timerGate.release(); await timer.value; await original?.value
        XCTAssertFalse(owner.busy)
    }
    func testReturnedJobReceiptAllowsNextModelWithoutLosingAnOriginal() async throws {
        let owner = FoundationOriginalWorkOwner()
        let first = try owner.start(model: true) {}
        await first.value
        XCTAssertFalse(owner.busy)
        let second = try owner.start(model: true) {}
        await second.value
        XCTAssertFalse(owner.busy)
    }
    func testScopedClientDrainDoesNotCancelUnrelatedLocalOriginal() async throws {
        let owner = FoundationOriginalWorkOwner(), local = VoiceFoundationOwner(), client = VoiceFoundationOwner()
        let localGate = FoundationReturnGate(), clientGate = FoundationReturnGate()
        let localEntered = expectation(description: "Unrelated local original held")
        let clientEntered = expectation(description: "Client original deadline held")
        let localJob = try owner.start(model: true, owner: local) { localEntered.fulfill(); await localGate.wait() }
        let clientJob = try owner.start(model: false, owner: client) { clientEntered.fulfill(); await clientGate.wait() }
        await fulfillment(of: [localEntered, clientEntered], timeout: 5)
        let clientDrain = owner.drain(owner: client, seal: false)
        XCTAssertTrue(clientJob.isCancelled)
        XCTAssertFalse(localJob.isCancelled)
        await clientGate.release(); await clientJob.value; await clientDrain?.value
        XCTAssertTrue(owner.busy); XCTAssertFalse(localJob.isCancelled)
        await localGate.release(); await localJob.value
        XCTAssertFalse(owner.busy)
    }
    func testTaskLocalOwnerIsCapturedBeforeDetachedWorkAndSurvivesScopeExit() async throws {
        let originalOwner = VoiceFoundationOwner(), other = VoiceFoundationOwner(), gate = FoundationReturnGate()
        let entered = expectation(description: "Detached authored work holds captured owner")
        let original = try LocalFoundationModelWork.$currentOwner.withValue(originalOwner) {
            try LocalFoundationModelWork.model { entered.fulfill(); await gate.wait() }
        }
        await fulfillment(of: [entered], timeout: 5)
        let unrelated = LocalFoundationModelWork.cancelAndWait(owner: other)
        XCTAssertNil(unrelated); XCTAssertFalse(original.isCancelled)
        let drain = LocalFoundationModelWork.$currentOwner.withValue(other) {
            LocalFoundationModelWork.cancelAndWait(owner: originalOwner)
        }
        XCTAssertTrue(original.isCancelled)
        await gate.release(); await original.value; await drain?.value
        XCTAssertFalse(LocalFoundationModelWork.busy)
    }
    func testOriginalDictationAdmissionRebindsActualOuterDetachedConsumer() async throws {
        let originalOwner = VoiceFoundationOwner(), unrelatedCallbackOwner = VoiceFoundationOwner()
        let session = UUID(), gate = FoundationReturnGate()
        // Same production consumer shape as VoiceModel.beginRecording/stopRecording:
        // retain the owner/session at admission, then later a callback/finalizer
        // runs under an unrelated ambient owner before launching the detached polish.
        let admission = LocalFoundationModelWork.$currentOwner.withValue(originalOwner) {
            VoiceFoundationAdmission(sessionID: session, owner: LocalFoundationModelWork.currentOwner)
        }
        XCTAssertEqual(admission.sessionID, session)
        let entered = expectation(description: "Production outer-detached helper entered original model work")
        let outer = LocalFoundationModelWork.$currentOwner.withValue(unrelatedCallbackOwner) {
            admission.detached {
                let original = try LocalFoundationModelWork.model { entered.fulfill(); await gate.wait() }
                await original.value
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        let wrong = LocalFoundationModelWork.cancelAndWait(owner: unrelatedCallbackOwner)
        XCTAssertNil(wrong)
        let matching = LocalFoundationModelWork.cancelAndWait(owner: originalOwner)
        XCTAssertNotNil(matching)
        await gate.release(); _ = try await outer.value; await matching?.value
        XCTAssertFalse(LocalFoundationModelWork.busy)
    }
    func testClosedAudioCallbackAdmissionJoinsEnteredDeliveryAfterNativeStop() async throws {
        let admission = VoiceAudioCallbackAdmission()
        let entered = try XCTUnwrap(admission.enter())
        admission.seal()
        XCTAssertNil(admission.enter())
        let original = Task { await admission.waitForReturn() }
        admission.nativeStopReturned()
        XCTAssertEqual(admission.enteredCallbackCount,1)
        // The actual original callback lease remains held until explicitly
        // returned. No elapsed timeout or audio-engine idle flag releases it.
        entered.finish()
        await original.value
        XCTAssertNil(admission.enter())
    }
    func testCallbackLeaseDoubleFinishCannotReleaseAnotherEnteredCallback() async throws {
        let admission = VoiceAudioCallbackAdmission()
        let first = try XCTUnwrap(admission.enter()), second = try XCTUnwrap(admission.enter())
        admission.seal(); admission.nativeStopReturned()
        first.finish(); first.finish()
        XCTAssertEqual(admission.enteredCallbackCount,1)
        let original = Task { await admission.waitForReturn() }
        second.finish(); await original.value
        XCTAssertNil(admission.enter())
    }
    @MainActor func testActualSynthesisStartFenceRejectsStopInsidePreparingCallout() throws {
        var playback=SpeechPlayback()
        let token=try playback.begin("Authored no-audio start check"),admission=VoiceAudioCallbackAdmission()
        var effectCount=0
        XCTAssertThrowsError(try SpeechSynthesisStartGuard.notifyThenStart(
            isCurrent:{playback.token==token && playback.active && admission.isOpen},
            notify:{playback.stop();admission.seal();admission.nativeStopReturned()},
            start:{effectCount+=1})) {XCTAssertTrue($0 is CancellationError)}
        XCTAssertEqual(effectCount,0)
    }
    @MainActor func testActualSynthesisStartFenceDoesNotBorrowReplacementToken() throws {
        var playback=SpeechPlayback()
        let original=try playback.begin("Original no-audio start")
        var replacement:UUID?,effectCount=0
        XCTAssertThrowsError(try SpeechSynthesisStartGuard.notifyThenStart(
            isCurrent:{playback.token==original && playback.active},
            notify:{playback.stop();replacement=try? playback.begin("Replacement no-audio start")},
            start:{effectCount+=1}))
        XCTAssertEqual(effectCount,0);XCTAssertNotEqual(replacement,original)
        XCTAssertTrue(playback.active)
    }
    func testPermanentSealNeverReopensAfterOriginalJobsReturn() async throws {
        let owner = FoundationOriginalWorkOwner(), gate = FoundationReturnGate()
        let entered = expectation(description: "Original work reserved before shutdown")
        let job = try owner.start(model: true) { entered.fulfill(); await gate.wait() }
        await fulfillment(of: [entered], timeout: 5)
        let original = owner.drain(seal: true)
        XCTAssertThrowsError(try owner.start(model: false) {})
        await gate.release(); await job.value; await original?.value
        XCTAssertTrue(owner.busy) // Permanently sealed; not an active-model claim.
        XCTAssertThrowsError(try owner.start(model: true) {})
    }
}
private actor FoundationReturnGate {
    private var released = false
    private var originals: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { originals.append($0) }
    }
    func release() {
        released = true
        let captured = originals; originals.removeAll()
        captured.forEach { $0.resume() }
    }
}
