import XCTest
@testable import VoiceAudio

@MainActor final class SpeechPreparationGateTests: XCTestCase {
    @MainActor private final class Hold {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        var waiting: Bool { continuation != nil }
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            let original = continuation; continuation = nil
            original?.resume()
        }
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "SpeechPreparationGateTests", code: 1) }
            await Task.yield()
        }
    }
    func testFourCancelledWaitersFreeTheirSlotsWithoutReleasingOriginalPreparation() async throws {
        let gate = SpeechPreparationGate(), originalHold = Hold(), finalHold = Hold()
        let original = Task {
            let permit = try await gate.acquire(); defer { gate.release(permit) }
            await originalHold.wait()
        }
        defer { originalHold.open(); finalHold.open() }
        try await until { originalHold.waiting }
        var cancelled: [Task<UUID, Error>] = []
        defer { for waiter in cancelled { waiter.cancel() } }
        for count in 1...4 {
            cancelled.append(Task {
                let permit = try await gate.acquire(); defer { gate.release(permit) }
                return permit
            })
            try await until { gate.waitingCount == count }
        }
        for waiter in cancelled { waiter.cancel() }
        for waiter in cancelled {
            do { _ = try await waiter.value; XCTFail("Cancelled queued preparation was granted") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(gate.waitingCount, 0); XCTAssertTrue(gate.busy)
        let survivor = Task {
            let permit = try await gate.acquire(); defer { gate.release(permit) }
            await finalHold.wait()
        }
        try await until { gate.waitingCount == 1 }
        XCTAssertFalse(finalHold.waiting)
        originalHold.open(); try await original.value
        try await until { finalHold.waiting }
        XCTAssertTrue(gate.busy); XCTAssertEqual(gate.waitingCount, 0)
        finalHold.open(); try await survivor.value
        XCTAssertFalse(gate.busy)
    }
    func testCancellationRacingGrantReleasesOnlyItsGrantedPermit() async throws {
        let gate = SpeechPreparationGate()
        let original = try await gate.acquire()
        defer { gate.release(original) }
        let cancelled = Task {
            let permit = try await gate.acquire(); defer { gate.release(permit) }
            return permit
        }
        defer { cancelled.cancel() }
        try await until { gate.waitingCount == 1 }
        // No suspension between cancel and release: release can grant the
        // cancelled waiter before its MainActor cancellation callback runs.
        cancelled.cancel(); gate.release(original)
        let successor = try await gate.acquire()
        do { _ = try await cancelled.value; XCTFail("Cancelled grant escaped") }
        catch { XCTAssertTrue(error is CancellationError) }
        await Task.yield()
        XCTAssertTrue(gate.busy); XCTAssertEqual(gate.waitingCount, 0)
        gate.release(original); XCTAssertTrue(gate.busy)
        gate.release(successor); XCTAssertFalse(gate.busy)
    }
    func testLateCancellationOfOldCompletedRequestDoesNotReleaseSuccessor() async throws {
        let gate = SpeechPreparationGate()
        let original = try await gate.acquire()
        defer { gate.release(original) }
        let old = Task {
            let permit = try await gate.acquire(); defer { gate.release(permit) }
            return permit
        }
        defer { old.cancel() }
        try await until { gate.waitingCount == 1 }
        gate.release(original)
        let oldPermit = try await old.value
        gate.release(oldPermit)
        let successor = try await gate.acquire()
        old.cancel(); await Task.yield()
        gate.release(oldPermit)
        XCTAssertTrue(gate.busy)
        gate.release(successor); XCTAssertFalse(gate.busy)
    }
    func testAlreadyCancelledTaskNeverOwnsCapacity() async throws {
        let gate = SpeechPreparationGate()
        let start = Hold()
        let request = Task {
            await start.wait()
            return try await gate.acquire()
        }
        defer { request.cancel(); start.open() }
        try await until { start.waiting }
        request.cancel(); start.open()
        do { _ = try await request.value; XCTFail("Cancelled task acquired a permit") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(gate.busy); XCTAssertEqual(gate.waitingCount, 0)
    }
    func testWrongReleaseCannotUnlockAndWaitersProceedInRegistrationOrder() async throws {
        let gate = SpeechPreparationGate(), firstHold = Hold(), secondHold = Hold()
        let original = try await gate.acquire()
        defer { gate.release(original); firstHold.open(); secondHold.open() }
        let first = Task {
            let permit = try await gate.acquire(); defer { gate.release(permit) }
            await firstHold.wait()
        }
        try await until { gate.waitingCount == 1 }
        let second = Task {
            let permit = try await gate.acquire(); defer { gate.release(permit) }
            await secondHold.wait()
        }
        try await until { gate.waitingCount == 2 }
        gate.release(UUID()); XCTAssertTrue(gate.busy); XCTAssertEqual(gate.waitingCount, 2)
        gate.release(original)
        try await until { firstHold.waiting }
        XCTAssertFalse(secondHold.waiting); XCTAssertEqual(gate.waitingCount, 1)
        firstHold.open(); try await first.value
        try await until { secondHold.waiting }
        secondHold.open(); try await second.value
        XCTAssertFalse(gate.busy)
    }
}
