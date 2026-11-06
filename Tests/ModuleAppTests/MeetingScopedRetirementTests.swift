import XCTest
import VoiceAudio
@testable import ModuleApp

// Exercises the production task owner with held original work only. No model,
// MeetingModel initializer, storage, native capture, observers or audio are used.
final class MeetingScopedRetirementTests: XCTestCase {
    func testProviderCapacityRefusesBeforeEitherLimit() {
        XCTAssertTrue(MeetingProviderCapacity.permits(live: 31, recorded: 4064))
        XCTAssertFalse(MeetingProviderCapacity.permits(live: 32, recorded: 0))
        XCTAssertFalse(MeetingProviderCapacity.permits(live: 1, recorded: 4095))
        XCTAssertFalse(MeetingProviderCapacity.permits(live: 0, recorded: 4096))
    }

    @MainActor func testScopedCloseWaitsForActualOriginalAndLeavesOtherOwnersAlone() async {
        let owner = MeetingOwnedTasks()
        let clientA = VoiceFoundationOwner(), clientB = VoiceFoundationOwner()
        let gateA = MeetingTaskGate(), gateB = MeetingTaskGate(), gateLocal = MeetingTaskGate()
        let a = Task { await gateA.wait() }
        let b = Task { await gateB.wait() }
        let local = Task { await gateLocal.wait() }
        owner.retain(a, owner: clientA); owner.retain(b, owner: clientB)
        owner.retain(local, owner: LocalFoundationModelWork.localUser)
        let originals = owner.close(clientA)
        XCTAssertEqual(originals.count, 1)
        XCTAssertTrue(a.isCancelled); XCTAssertFalse(b.isCancelled); XCTAssertFalse(local.isCancelled)
        XCTAssertFalse(owner.permits(clientA)); XCTAssertTrue(owner.permits(clientB))
        var returned = false
        let drain = Task { @MainActor in
            await owner.waitForReturn(clientA)
            returned = true
        }
        await Task.yield()
        XCTAssertFalse(returned)
        await gateA.release(); await drain.value
        XCTAssertTrue(returned)
        XCTAssertFalse(b.isCancelled); XCTAssertFalse(local.isCancelled)
        await gateB.release(); await gateLocal.release()
        await b.value; await local.value
    }

    @MainActor func testLateDerivedRetirementAfterSealIsJoined() async {
        let owner = MeetingOwnedTasks(), client = VoiceFoundationOwner(), gate = MeetingTaskGate()
        _ = owner.close(client)
        let derived = Task { await gate.wait() }
        owner.retain(derived, owner: client)
        XCTAssertTrue(derived.isCancelled)
        var returned = false
        let drain = Task { @MainActor in await owner.waitForReturn(client); returned = true }
        await Task.yield(); XCTAssertFalse(returned)
        await gate.release(); await drain.value
        XCTAssertTrue(returned)
    }

    @MainActor func testReplacementCannotDiscardHeldOriginalAndGlobalCloseSealsAdmission() async {
        let owner = MeetingOwnedTasks(), client = VoiceFoundationOwner()
        let firstGate = MeetingTaskGate(), secondGate = MeetingTaskGate()
        let first = Task { await firstGate.wait() }
        let second = Task { await secondGate.wait() }
        owner.retain(first, owner: client); owner.retain(second, owner: client)
        let originals = owner.close(nil)
        XCTAssertEqual(originals.count, 2)
        XCTAssertTrue(first.isCancelled); XCTAssertTrue(second.isCancelled)
        XCTAssertFalse(owner.permits(client)); XCTAssertFalse(owner.permits(VoiceFoundationOwner()))
        await firstGate.release(); await first.value
        var returned = false
        let drain = Task { @MainActor in
            await owner.waitForReturn(nil)
            returned = true
        }
        await Task.yield(); XCTAssertFalse(returned)
        await secondGate.release(); await drain.value
        XCTAssertTrue(returned)
    }
}

private actor MeetingTaskGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let originals = waiters; waiters.removeAll()
        originals.forEach { $0.resume() }
    }
}
