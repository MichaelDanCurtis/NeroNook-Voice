import XCTest
import Foundation
import ModuleCore
import NookPluginSDK
@testable import ModuleApp

// Isolated authored files only; no MeetingModel/VoiceModel initializer, user
// profile, GUI, audio, network, model or native service is constructed.
final class VoiceMeetingReadOwnershipTests: XCTestCase {
    @MainActor func testRetirementBeforeFirstTaskRunNeverStartsReadOrDeliversCallback() async throws {
        let owner = VoiceMeetingReadOwner(), id = UUID()
        var operationStarted = false, callbackDelivered = false
        try owner.start(id, operation: { operationStarted = true; return [:] },
                        reply: { _ in callbackDelivered = true })
        // Both calls are synchronous on MainActor, so the original task cannot
        // start before the real retirement admission is sealed.
        let originals = owner.beginRetirement([id])
        XCTAssertEqual(originals.count, 1)
        for original in originals { await original.value }
        XCTAssertFalse(operationStarted); XCTAssertFalse(callbackDelivered)
        XCTAssertEqual(owner.count, 0)
    }

    @MainActor func testDirectCancellationBeforeFirstTaskRunSuppressesCallback() async throws {
        let owner = VoiceMeetingReadOwner(), id = UUID()
        var operationStarted = false, callbackDelivered = false
        let original = try owner.start(id, operation: { operationStarted = true; return [:] },
                                       reply: { _ in callbackDelivered = true })
        owner.cancel(id)
        await original.value
        XCTAssertFalse(operationStarted); XCTAssertFalse(callbackDelivered)
        XCTAssertEqual(owner.count, 0)
    }

    @MainActor func testExactRetirementWaitsForOriginalFileAndPreservesOtherRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceMeetingRead-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(title: "Authored meeting", source: "none", microphone: false)
        try store.save(meeting)
        let file = store.folder(meeting.id).appendingPathComponent("meeting.json")
        let originalBytes = try Data(contentsOf: file)
        let aGate = AuthoredFileGate(file), bGate = AuthoredFileGate(file)
        let a = UUID(), b = UUID(), owner = VoiceMeetingReadOwner()
        var aReply = false, bReply: Result<[String: PluginValue], Error>?
        let bReturned = expectation(description: "Unrelated actual read returns")
        let values: [String: PluginValue] = ["query": .string("Authored")]
        try owner.start(a, operation: {
            try await MeetingReadWork.read(MeetingReadContract.search.id, values: values, store: store, provider: .apple, beforeRead: { aGate.holdOriginalFileRead() })
        }, reply: { _ in aReply = true })
        try owner.start(b, operation: {
            try await MeetingReadWork.read(MeetingReadContract.search.id, values: values, store: store, provider: .apple, beforeRead: { bGate.holdOriginalFileRead() })
        }, reply: { bReply = $0; bReturned.fulfill() })
        let aEntered = await aGate.waitForEntry(), bEntered = await bGate.waitForEntry()
        XCTAssertTrue(aEntered); XCTAssertTrue(bEntered)
        var aRetired = false
        let retirement = Task { @MainActor in await owner.retire([a]); aRetired = true }
        await Task.yield()
        XCTAssertFalse(aRetired); XCTAssertEqual(owner.count, 2)
        XCTAssertThrowsError(try owner.start(a, operation: { [:] }, reply: { _ in }))
        aGate.release()
        await retirement.value
        XCTAssertTrue(aRetired); XCTAssertFalse(aReply); XCTAssertEqual(owner.count, 1)
        XCTAssertTrue(aGate.didReadAndClose)
        XCTAssertNil(bReply)
        bGate.release()
        await owner.retire([]) // does not cancel or join B
        await fulfillment(of: [bReturned], timeout: 5)
        guard case .success(let result)? = bReply, case .string(let matches)? = result["matches"] else {
            XCTFail("The unrelated original must return its real search result"); return
        }
        XCTAssertTrue(matches.contains(meeting.id.uuidString)); XCTAssertTrue(bGate.didReadAndClose)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
    }

    @MainActor func testShutdownCancellationKeepsOriginalUntilItsFileReadReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceMeetingRead-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), meeting = Meeting(title: "Held original", source: "none", microphone: false)
        try store.save(meeting)
        let gate = AuthoredFileGate(store.folder(meeting.id).appendingPathComponent("meeting.json"))
        let id = UUID(), owner = VoiceMeetingReadOwner()
        var delivered = false
        try owner.start(id, operation: {
            try await MeetingReadWork.read(MeetingReadContract.read.id,
                values: ["meeting_id": .string(meeting.id.uuidString), "offset": .number(0), "personal_notes": .boolean(false)],
                store: store, provider: .apple, beforeRead: { gate.holdOriginalFileRead() })
        }, reply: { _ in delivered = true })
        let entered = await gate.waitForEntry(); XCTAssertTrue(entered)
        owner.cancelAll()
        XCTAssertEqual(owner.count, 1)
        var returned = false
        let retirement = Task { @MainActor in await owner.retire([id]); returned = true }
        await Task.yield(); XCTAssertFalse(returned)
        gate.release(); await retirement.value
        XCTAssertTrue(returned); XCTAssertFalse(delivered); XCTAssertEqual(owner.count, 0)
        XCTAssertTrue(gate.didReadAndClose)
    }
}

private final class AuthoredFileGate: @unchecked Sendable {
    private let url: URL
    private let entered = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false
    private var completed = false
    private var failure: String?
    init(_ url: URL) { self.url = url }
    func holdOriginalFileRead() {
        // Open the actual isolated authored file, keep the handle live across
        // cancellation, then perform its original read and close before return.
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { lock.lock(); failure = "open: \(error)"; lock.unlock(); entered.signal(); return }
        lock.lock(); opened = true; lock.unlock(); entered.signal()
        proceed.wait()
        do {
            let data = try handle.read(upToCount: 1)
            try handle.close()
            lock.lock(); completed = data?.count == 1; if !completed { failure = "short read" }; lock.unlock()
        } catch { lock.lock(); failure = "read or close: \(error)"; lock.unlock(); try? handle.close() }
    }
    func waitForEntry() async -> Bool {
        let signalled = await Task.detached { self.entered.wait(timeout: .now() + 5) == .success }.value
        return signalled && openedSuccessfully()
    }
    private func openedSuccessfully() -> Bool {
        lock.lock(); defer { lock.unlock() }; return opened && failure == nil
    }
    var didReadAndClose: Bool {
        lock.lock(); defer { lock.unlock() }; return completed && failure == nil
    }
    func release() { proceed.signal() }
}
