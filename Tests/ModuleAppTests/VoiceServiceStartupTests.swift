import XCTest
import Foundation
import Security
import NookLocalServiceKit
@testable import ModuleApp

final class VoiceServiceStartupTests: XCTestCase {
    private func fixture(globalControls: Bool = false) throws -> (VoiceServicePolicy, URL) {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        XCTAssertEqual(SecCodeCopySelf(SecCSFlags(), &code), errSecSuccess)
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), SecCSFlags(), &staticCode), errSecSuccess)
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode), SecCSFlags(), &requirement), errSecSuccess)
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), SecCSFlags(), &text), errSecSuccess)
        let service = "test.nero.startup.s" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let native = try LocalServicePolicy(serviceIdentifier: service,
            trustedSelfRequirements: ["startup-test": try XCTUnwrap(text) as String],
            trustedPeerRequirements: ["startup-test": try XCTUnwrap(text) as String])
        let parent = URL(fileURLWithPath: "/private/tmp/nero-startup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let policy = try VoiceServicePolicy(native: native, serviceIdentifier: service, moduleIdentifier: service,
            fullModulePolicyKey: "startup-test", capabilityPolicyKeys: [], lifecycleRoot: parent,
            resourceRevision: String(repeating: "0", count: 64), buildIdentifier: "authored-startup",
            permitsGlobalControls: globalControls)
        return (policy, parent)
    }

    func testFreshPreparationReturnsOnlyAfterActualActivePublication() async throws {
        let (policy, parent) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outcome = await VoiceServiceStartup.prepare(plan: .freshIsolated(parent: parent)) { policy }
        guard case .ready(let prepared) = outcome else { return XCTFail("Fresh isolated preparation failed") }
        XCTAssertTrue(prepared.isolated)
        XCTAssertNotEqual(prepared.policy.lifecycleRoot, parent)
        XCTAssertFalse(prepared.policy.permitsGlobalControls)
        let record = prepared.policy.lifecycleRoot.appendingPathComponent("lifecycle-v1.json")
        let bytes = try Data(contentsOf: record)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(value["state"] as? String, "active")
        XCTAssertEqual(value["epochID"] as? String, prepared.epoch.uuidString)
        XCTAssertEqual(value["releasedFamilies"] as? [String], [])
        // A known active lineage cannot be treated as first enrollment again.
        let another = try VoiceLifecycleLedger(root: prepared.policy.lifecycleRoot, owner: prepared.owner,
            binding: .init(serviceIdentifier: policy.serviceIdentifier, buildIdentifier: policy.buildIdentifier,
                bootSessionUUID: UUID(), ownPolicyKey: prepared.owner.ownPolicyKey))
        do { _ = try await another.begin(); XCTFail("Reset a known active lineage") }
        catch { XCTAssertEqual(error as? VoiceLifecycleFailure, .recoveryRequired) }
        let otherIssue = await another.retireStartupHandles()
        XCTAssertNil(otherIssue)
        XCTAssertEqual(try Data(contentsOf: record), bytes)
        let issue = await prepared.ledger.retireStartupHandles()
        XCTAssertNil(issue)
        XCTAssertEqual(try Data(contentsOf: record), bytes, "Startup handle retirement fabricated a clean record")
    }

    func testExistingMissingLineageDoesNotFallBackToFreshCreation() async throws {
        let (policy, parent) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outcome = await VoiceServiceStartup.prepare(plan: .existing) { policy }
        guard case .failed(let failure) = outcome else { return XCTFail("Enrolled a missing known lineage") }
        XCTAssertEqual(failure.error as? VoiceLifecycleFailure, .missingRecord)
        XCTAssertNil(failure.cleanupIssue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testPreparedProductAdmissionRejectsSamePathDirectoryReplacement() async throws {
        let (policy, parent) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outcome = await VoiceServiceStartup.prepare(plan: .freshIsolated(parent: parent)) { policy }
        guard case .ready(let prepared) = outcome else { return XCTFail("Fresh preparation failed") }
        try prepared.revalidateProductRoot()
        let root = prepared.policy.lifecycleRoot, moved = parent.appendingPathComponent("kept-original")
        let originalBytes = try Data(contentsOf: root.appendingPathComponent("lifecycle-v1.json"))
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try prepared.revalidateProductRoot())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let issue = await prepared.ledger.retireStartupHandles()
        XCTAssertNil(issue)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("lifecycle-v1.json")), originalBytes)
    }

    func testIsolatedPlanCannotEnableGlobalControls() async throws {
        let (policy, parent) = try fixture(globalControls: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let outcome = await VoiceServiceStartup.prepare(plan: .freshIsolated(parent: parent)) { policy }
        guard case .failed(let failure) = outcome else { return XCTFail("Enabled global controls through isolated enrollment") }
        XCTAssertEqual(failure.error as? VoiceLifecycleFailure, .invalidBinding)
        XCTAssertNil(failure.cleanupIssue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testFailureBeforeReturnedObjectStillPreservesOriginalCloseUncertainty() async throws {
        let (_, parent) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        // Authored failure injection at the actual preparation boundary. No
        // invalid or recycled descriptor is used to manufacture a close error.
        let outcome = await VoiceServiceStartup.prepare(plan: .freshIsolated(parent: parent)) {
            throw VoiceProvisionCleanupFailure(original: CancellationError(), closeErrors: [EIO])
        }
        guard case .failed(let failure) = outcome else { return XCTFail("Discarded original cleanup failure") }
        XCTAssertNotNil(failure.cleanupIssue)
        XCTAssertNil(failure.owner)
        XCTAssertNil(failure.ledger)
        XCTAssertNil(failure.provision)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    @MainActor func testActualBootstrapRefusesIsolatedGlobalControlsBeforeConstruction() throws {
        let (policy, parent) = try fixture(globalControls: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let bootstrap = VoiceServiceBootstrap(isolatedPolicy: policy, parent: parent)
        XCTAssertTrue(bootstrap.isolatedComposition)
        XCTAssertNil(bootstrap.legacy)
        XCTAssertNil(bootstrap.runtime)
        XCTAssertTrue(bootstrap.status.contains("cannot enable global controls"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    @MainActor func testActualBootstrapImmediateStopCannotStartRuntimeOrFreshRoot() async throws {
        let (policy, parent) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let bootstrap = VoiceServiceBootstrap(isolatedPolicy: policy, parent: parent)
        let returned = await bootstrap.shutdown()
        XCTAssertTrue(returned)
        XCTAssertNil(bootstrap.legacy)
        XCTAssertNil(bootstrap.runtime)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }

    func testCancellationJoinsEnteredOriginalBeforeNativeOwnerOrRootEffects() async throws {
        let (policy, parent) = try fixture(), gate = StartupOriginalGate()
        defer { gate.release(); try? FileManager.default.removeItem(at: parent) }
        let task = Task {
            let result = await VoiceServiceStartup.prepare(plan: .freshIsolated(parent: parent)) {
                gate.enterAndWait()
                return policy
            }
            gate.markReturned()
            return result
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !gate.entered {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "startup-test-timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        // The original has not returned merely because its caller cancelled.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(gate.returned)
        XCTAssertTrue(gate.entered)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
        gate.release()
        guard case .failed(let failure) = await task.value else { return XCTFail("Cancelled original admitted a runtime") }
        XCTAssertTrue(failure.error is CancellationError)
        XCTAssertNil(failure.owner)
        XCTAssertNil(failure.ledger)
        XCTAssertNil(failure.cleanupIssue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
    }
}

private final class StartupOriginalGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var hasEntered = false
    private var hasReturned = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return hasEntered }
    var returned: Bool { lock.lock(); defer { lock.unlock() }; return hasReturned }
    func enterAndWait() { lock.lock(); hasEntered = true; lock.unlock(); semaphore.wait() }
    func markReturned() { lock.lock(); hasReturned = true; lock.unlock() }
    func release() { semaphore.signal() }
}
