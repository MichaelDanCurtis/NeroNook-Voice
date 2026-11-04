import XCTest
import Foundation
import VoiceAudio
@testable import ModuleApp

// Exercises actual process-local owners, not MeetingModel/user store,
// NSWorkspace, GUI, device permissions, audio, models or native services.
final class MeetingGlobalRetirementTests: XCTestCase {
    @MainActor func testGlobalNativeSealWaitsForEnteredOriginalDelivery() async throws {
        let owner = MeetingNativeObserverOwner(), hold = MeetingFileCompletion()
        let entered = try XCTUnwrap(owner.admission.enter())
        let original = Task { @MainActor in defer { entered.finish() }; await hold.wait() }
        owner.seal(); owner.sourceStopsReturned()
        XCTAssertTrue(owner.closing); XCTAssertNil(owner.admission.enter())
        var returned = false
        let retirement = Task { @MainActor in await owner.waitForReturn(); returned = true }
        await Task.yield(); XCTAssertFalse(returned)
        hold.finish(); await original.value; await retirement.value
        XCTAssertTrue(returned)
    }

    @MainActor func testStoppedSamplerOriginalSurvivesEmptySlotAndGlobalSeal() async {
        let owner = MeetingCallDetectionOwner(), hold = MeetingFileCompletion()
        let original = Task { @MainActor in await hold.wait() }
        XCTAssertTrue(owner.install(original))
        owner.stop(); XCTAssertNil(owner.current); XCTAssertTrue(original.isCancelled)
        owner.seal(); XCTAssertTrue(owner.sealed)
        let denied = Task { @MainActor in }
        XCTAssertFalse(owner.install(denied)); XCTAssertTrue(denied.isCancelled)
        var returned = false
        let retirement = Task { @MainActor in await owner.waitForReturn(); returned = true }
        await Task.yield(); XCTAssertFalse(returned)
        hold.finish(); await original.value; await retirement.value
        XCTAssertTrue(returned)
    }

    @MainActor func testPrestartRecordingAttemptRemainsExplicitAfterStop() {
        let original = MeetingRecordingAttempt(owner: .init())
        original.sealed = true
        // This is an explicit never-scheduled stage, not inference from nil.
        XCTAssertFalse(original.startScheduled)
        XCTAssertFalse(original.startReturned)
        XCTAssertFalse(original.captureAdmissionAttempted)
        XCTAssertTrue(original.sealed)
    }
    @MainActor func testCancelledSamplerDoesNotEnterNativeObservation() async {
        let original = Task { @MainActor in await MeetingCallObservation.sample() }
        original.cancel()
        let result = await original.value
        XCTAssertNil(result)
    }

}
