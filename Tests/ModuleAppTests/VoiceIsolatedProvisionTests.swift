import XCTest
import Foundation
import Darwin
import Security
import NookLocalServiceKit
@testable import ModuleApp

private actor EnrollmentReturnFlag {
    private(set) var started = false
    private(set) var returned = false
    func markStarted() { started = true }
    func mark() { returned = true }
}

final class VoiceIsolatedProvisionTests: XCTestCase {
    private struct Fixture {
        let parent: URL
        let owner: LocalServiceOwner
        let binding: VoiceLifecycleBinding
    }
    private func fixture() throws -> Fixture {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        XCTAssertEqual(SecCodeCopySelf(SecCSFlags(), &code), errSecSuccess)
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), SecCSFlags(), &staticCode), errSecSuccess)
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode), SecCSFlags(), &requirement), errSecSuccess)
        XCTAssertEqual(SecCodeCheckValidity(try XCTUnwrap(code), SecCSFlags.noNetworkAccess, try XCTUnwrap(requirement)), errSecSuccess)
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), SecCSFlags(), &text), errSecSuccess)
        let service = "test.nero.enrollment.s" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let own = try XCTUnwrap(text) as String
        let policy = try LocalServicePolicy(serviceIdentifier: service,
            trustedSelfRequirements: ["test": own], trustedPeerRequirements: ["test": own])
        let owner = try LocalServiceOwner.acquire(policy: policy)
        let parent = URL(fileURLWithPath: "/private/tmp/nero-enrollment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return Fixture(parent: parent, owner: owner,
                       binding: .init(serviceIdentifier: service, buildIdentifier: "test-build",
                                      bootSessionUUID: UUID(), ownPolicyKey: owner.ownPolicyKey))
    }
    func testExclusiveFreshRootPublishesActualActiveAndConsumesCapability() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let provision = try await VoiceIsolatedProvision.create(parent: f.parent, owner: f.owner, binding: f.binding)
        let ledger = try VoiceLifecycleLedger(root: provision.root, owner: f.owner, binding: f.binding)
        let epoch = try await ledger.beginIsolatedGenesis(provision)
        let file = provision.root.appendingPathComponent("lifecycle-v1.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "active")
        XCTAssertEqual(object["epochID"] as? String, epoch.uuidString)
        let other = try VoiceLifecycleLedger(root: provision.root, owner: f.owner, binding: f.binding)
        do { _ = try await other.beginIsolatedGenesis(provision); XCTFail("Reused capability") } catch { }
        do { _ = try await other.begin(); XCTFail("Active record accepted") } catch { }
    }
    func testExistingDestinationIsNeverOverwritten() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let provision = try await VoiceIsolatedProvision.create(parent: f.parent, owner: f.owner, binding: f.binding)
        let target = provision.root.appendingPathComponent("lifecycle-v1.json")
        let original = Data("authored incumbent".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: original, attributes: [.posixPermissions: 0o600]))
        let ledger = try VoiceLifecycleLedger(root: provision.root, owner: f.owner, binding: f.binding)
        do { _ = try await ledger.beginIsolatedGenesis(provision); XCTFail("Overwrote an incumbent") } catch { }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
    func testHeldOriginalCreationReturnsBeforeCancelledCaller() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let original = Task {
            try await VoiceIsolatedProvision.create(parent: f.parent, owner: f.owner, binding: f.binding) {
                entered.signal(); release.wait()
            }
        }
        let reached = await Task.detached { entered.wait(timeout: .now() + 5) == .success }.value
        guard reached else { release.signal(); original.cancel(); _ = await original.result; XCTFail("Original did not enter checkpoint"); return }
        original.cancel()
        let marker = expectation(description: "original joined"), flag = EnrollmentReturnFlag()
        let observer = Task { await flag.markStarted(); _ = await original.result; await flag.mark(); marker.fulfill() }
        while !(await flag.started) { await Task.yield() }
        let premature = await flag.returned
        XCTAssertFalse(premature)
        release.signal()
        await fulfillment(of: [marker], timeout: 5)
        await observer.value
        do { _ = try await original.value; XCTFail("Cancelled creation returned capability") } catch { }
        let children = try FileManager.default.contentsOfDirectory(atPath: f.parent.path)
        XCTAssertEqual(children.count, 1) // Original mkdir is retained for diagnosis.
    }
    func testReplacedOriginalParentCannotAuthorizeGenesis() async throws {
        let f = try fixture(); let moved = f.parent.appendingPathExtension("held")
        defer { try? FileManager.default.removeItem(at: f.parent); try? FileManager.default.removeItem(at: moved) }
        let provision = try await VoiceIsolatedProvision.create(parent: f.parent, owner: f.owner, binding: f.binding)
        try FileManager.default.moveItem(at: f.parent, to: moved)
        try FileManager.default.createDirectory(at: f.parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try provision.revalidate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(provision.root.lastPathComponent).path))
    }
    func testCancelledHeldFirstWriterIsJoinedAndDoesNotPublishActive() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let provision = try await VoiceIsolatedProvision.create(parent: f.parent, owner: f.owner, binding: f.binding)
        let ledger = try VoiceLifecycleLedger(root: provision.root, owner: f.owner, binding: f.binding)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let original = Task { try await ledger.beginIsolatedGenesis(provision) { entered.signal(); release.wait() } }
        let reached = await Task.detached { entered.wait(timeout: .now() + 5) == .success }.value
        guard reached else { release.signal(); original.cancel(); _ = await original.result; XCTFail("Original did not enter checkpoint"); return }
        original.cancel()
        let flag = EnrollmentReturnFlag()
        let observer = Task { await flag.markStarted(); _ = await original.result; await flag.mark() }
        while !(await flag.started) { await Task.yield() }
        let premature = await flag.returned
        XCTAssertFalse(premature)
        release.signal(); await observer.value
        do { _ = try await original.value; XCTFail("Cancelled writer returned active epoch") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: provision.root.appendingPathComponent("lifecycle-v1.json").path))
        let artifacts = try FileManager.default.contentsOfDirectory(atPath: provision.root.path)
        XCTAssertTrue(artifacts.contains { $0.hasPrefix(".lifecycle-") })
    }

    func testStartupHandleRetirementPreservesActualActiveRecord() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let provision = try await VoiceIsolatedProvision.create(parent: f.parent, owner: f.owner, binding: f.binding)
        let ledger = try VoiceLifecycleLedger(root: provision.root, owner: f.owner, binding: f.binding)
        _ = try await ledger.beginIsolatedGenesis(provision)
        let target = provision.root.appendingPathComponent("lifecycle-v1.json")
        let before = try Data(contentsOf: target)
        let issue = await ledger.retireStartupHandles()
        XCTAssertNil(issue)
        XCTAssertEqual(try Data(contentsOf: target), before)
        let again = await ledger.retireStartupHandles()
        XCTAssertNil(again)
        do { _ = try await ledger.begin(); XCTFail("Retired startup reopened") } catch { }
    }

    func testWrongBindingCannotConsumeTheOriginalCapability() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.parent) }
        let provision = try await VoiceIsolatedProvision.create(parent: f.parent, owner: f.owner, binding: f.binding)
        let wrong = VoiceLifecycleBinding(serviceIdentifier: f.binding.serviceIdentifier, buildIdentifier: "other",
                                          bootSessionUUID: f.binding.bootSessionUUID, ownPolicyKey: f.binding.ownPolicyKey)
        let other = try VoiceLifecycleLedger(root: provision.root, owner: f.owner, binding: wrong)
        do { _ = try await other.beginIsolatedGenesis(provision); XCTFail("Wrong binding admitted") } catch { }
        let ownerLedger = try VoiceLifecycleLedger(root: provision.root, owner: f.owner, binding: f.binding)
        _ = try await ownerLedger.beginIsolatedGenesis(provision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provision.root.appendingPathComponent("lifecycle-v1.json").path))
    }

}
