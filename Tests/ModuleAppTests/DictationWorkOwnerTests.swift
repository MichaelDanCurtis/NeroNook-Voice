import XCTest
@testable import ModuleApp

@MainActor final class DictationWorkOwnerTests: XCTestCase {
    private final class Hold {
        var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { opened = true; let old = continuation; continuation = nil; old?.resume() }
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "DictationWorkOwnerTests", code: 1) }
            await Task.yield()
        }
    }
    func testPreparationAndFinalizationRemainOwnedUntilBothReturn() async throws {
        let owner = DictationWorkOwner(), preparation = Hold(), finalization = Hold()
        defer { preparation.open(); finalization.open() }
        let prep = owner.start { await preparation.wait() }
        let finish = owner.start { await finalization.wait() }
        try await until { preparation.continuation != nil && finalization.continuation != nil }
        owner.cancel(); let original = owner.retirementCompletion()
        preparation.open(); await prep?.value
        XCTAssertTrue(owner.busy); XCTAssertTrue(owner.draining)
        finalization.open(); await finish?.value; await original?.value
        XCTAssertFalse(owner.busy)
    }
    func testCancellationReservesAdmissionBeforeCaptureAndRetainsResourceDrain() async throws {
        let owner = DictationWorkOwner(), resource = Hold()
        defer { resource.open() }
        var rejected = false, ran = false
        owner.cancel {
            rejected = owner.start { ran = true } == nil
            return [Task { await resource.wait() }]
        }
        let original = owner.retirementCompletion()
        try await until { resource.continuation != nil }
        XCTAssertTrue(rejected); XCTAssertFalse(ran); XCTAssertTrue(owner.busy)
        resource.open(); await original?.value
        XCTAssertFalse(owner.busy)
    }
    func testSelfCancellationDoesNotAwaitItsOwnReturnInline() async throws {
        let owner = DictationWorkOwner()
        var returned = false
        let original = owner.start { owner.cancel(); returned = true }
        await original?.value; await owner.retirementCompletion()?.value
        XCTAssertTrue(returned); XCTAssertFalse(owner.busy)
    }
    func testCompletionNotificationCannotEraseSuccessor() async throws {
        let owner = DictationWorkOwner(), old = Hold(), next = Hold()
        defer { old.open(); next.open() }
        var replaced = false
        owner.changed = {
            if !owner.busy && !replaced {
                replaced = true; owner.start { await next.wait() }
            }
        }
        let original = owner.start { await old.wait() }
        try await until { old.continuation != nil }
        old.open(); await original?.value
        try await until { next.continuation != nil }
        XCTAssertTrue(owner.busy)
        owner.changed = nil; owner.cancel(); let drain = owner.retirementCompletion()
        next.open(); await drain?.value
        XCTAssertFalse(owner.busy)
    }
    func testRepeatedCancelKeepsTheSamePendingRetirement() async throws {
        let owner = DictationWorkOwner(), hold = Hold()
        defer { hold.open() }
        owner.start { await hold.wait() }
        try await until { hold.continuation != nil }
        owner.cancel(); let id = owner.retirementID, original = owner.retirementCompletion()
        owner.cancel(); owner.cancel()
        XCTAssertEqual(owner.retirementID, id); XCTAssertTrue(owner.busy)
        hold.open(); await original?.value
        XCTAssertFalse(owner.busy)
    }
    func testReentrantCancelBeforeDispatchCannotRunBody() async throws {
        let owner = DictationWorkOwner()
        var cancelled = false, ran = false
        owner.changed = {
            if owner.busy && !cancelled { cancelled = true; owner.cancel() }
        }
        let original = owner.start { ran = true }
        await original?.value; await owner.retirementCompletion()?.value
        XCTAssertTrue(cancelled); XCTAssertFalse(ran); XCTAssertFalse(owner.busy)
    }
    func testSynchronousPreparationIsReservedAndStopPreventsDispatch() async throws {
        let owner = DictationWorkOwner()
        var prepared = false, ran = false, nestedRejected = false
        let original = owner.start(prepare: { task in
            prepared = true
            XCTAssertTrue(owner.busy)
            nestedRejected = owner.draining
            owner.cancel()
            XCTAssertTrue(task.isCancelled)
        }) { ran = true }
        XCTAssertTrue(prepared)
        XCTAssertFalse(nestedRejected) // normal finalization may share this owner
        await original?.value; await owner.retirementCompletion()?.value
        XCTAssertFalse(ran); XCTAssertFalse(owner.busy)
    }
    func testStopFromReservationPublicationSkipsSynchronousPreparation() async throws {
        let owner = DictationWorkOwner()
        var cancelled = false, prepared = false, ran = false
        owner.changed = {
            if owner.busy && !cancelled { cancelled = true; owner.cancel() }
        }
        let original = owner.start(prepare: { _ in prepared = true }) { ran = true }
        await original?.value; await owner.retirementCompletion()?.value
        XCTAssertTrue(cancelled); XCTAssertFalse(prepared); XCTAssertFalse(ran); XCTAssertFalse(owner.busy)
    }

}
