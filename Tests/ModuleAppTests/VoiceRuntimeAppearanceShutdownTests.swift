import XCTest
import Foundation
import Darwin
import Security
@testable import NookPluginSDK
import NookLocalServiceKit
@testable import ModuleApp

private actor RuntimeAppearanceWaiterStatus {
    private var started = Set<Int>()
    private var returned = Set<Int>()
    func start(_ id: Int) { started.insert(id) }
    func finish(_ id: Int) { returned.insert(id) }
    func hasStarted(_ id: Int) -> Bool { started.contains(id) }
    func hasReturned(_ id: Int) -> Bool { returned.contains(id) }
}

/// Actual isolated runtime, actual SDK store and actual native test-host owner;
/// no peer, NSWindow, user profile, microphone, model, or account is opened.
@MainActor final class VoiceRuntimeAppearanceShutdownTests: XCTestCase {
    private func fixture(earlyMaterialization: Bool = true) async throws -> (VoiceServiceRuntime, VoiceServicePreparedStart, VoiceProductConfiguration, URL) {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        XCTAssertEqual(SecCodeCopySelf(SecCSFlags(), &code), errSecSuccess)
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), SecCSFlags(), &staticCode), errSecSuccess)
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode), SecCSFlags(), &requirement), errSecSuccess)
        XCTAssertEqual(SecCodeCheckValidity(try XCTUnwrap(code), SecCSFlags.noNetworkAccess, try XCTUnwrap(requirement)), errSecSuccess)
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), SecCSFlags(), &text), errSecSuccess)
        let service = "test.nero.appearance.s" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let native = try LocalServicePolicy(serviceIdentifier: service,
            trustedSelfRequirements: ["appearance-test": try XCTUnwrap(text) as String],
            trustedPeerRequirements: ["appearance-test": try XCTUnwrap(text) as String])
        let parent = URL(fileURLWithPath: "/private/tmp/nero-appearance-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let policy = try VoiceServicePolicy(native: native, serviceIdentifier: service, moduleIdentifier: service,
            fullModulePolicyKey: "appearance-test", capabilityPolicyKeys: [], lifecycleRoot: parent,
            resourceRevision: String(repeating: "0", count: 64), buildIdentifier: "authored-appearance-runtime",
            permitsGlobalControls: false)
        let outcome = await VoiceServiceStartup.prepare(plan: .freshIsolated(parent: parent)) { policy }
        guard case .ready(let prepared) = outcome else { throw VoiceServiceProblem.unavailable }
        let product = try VoiceProductConfiguration.isolated(
            root: prepared.policy.lifecycleRoot.appendingPathComponent("Product", isDirectory: true),
            revalidate: { try prepared.revalidateProductRoot() })
        // Exercise both the pre-existing inert store and the runtime's own
        // first store selection without permitting replacement or promotion.
        let early: PluginAppearanceStore?
        if earlyMaterialization {
            early = product.appearance.store
            XCTAssertThrowsError(try product.appearance.prepareSharedService(observation: .system))
        } else {
            XCTAssertFalse(product.appearance.materialized)
            early = nil
        }
        let runtime = try VoiceServiceRuntime(owner: prepared.owner, policy: prepared.policy,
            ledger: prepared.ledger, epochID: prepared.epoch, productConfiguration: product)
        if let early {
            XCTAssertTrue(product.appearance.store === early)
        } else {
            XCTAssertTrue(product.appearance.materialized)
            try product.appearance.prepareSharedService(observation: .hostDelivered)
        }
        XCTAssertThrowsError(try product.appearance.prepareSharedService(observation: .system))
        try runtime.start()
        return (runtime, prepared, product, parent)
    }

    private func recordState(_ prepared: VoiceServicePreparedStart) throws -> String? {
        let record = prepared.policy.lifecycleRoot.appendingPathComponent("lifecycle-v1.json")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        return value["state"] as? String
    }
    private func waitFor(_ condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Original shutdown did not reach the expected point")
    }

    func testActualRuntimeShutdownJoinsHeldAppearanceOriginalAcrossCancelledWaiter() async throws {
        let (runtime, prepared, product, parent) = try await fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = product.appearance.store
        let source = try XCTUnwrap(store.appearanceLifetime.makeSource())
        source.finishRegistration(stop: {})
        let heldOriginal = try XCTUnwrap(source.enter())
        defer { heldOriginal.finish() }
        let status = RuntimeAppearanceWaiterStatus()
        let first = Task { @MainActor in
            await status.start(1)
            let result = await runtime.shutdown()
            await status.finish(1)
            return result
        }
        await waitFor { store.isRetiring }
        let second = Task { @MainActor in
            await status.start(2)
            let result = await runtime.shutdown()
            await status.finish(2)
            return result
        }
        await waitFor {
            let one = await status.hasStarted(1), two = await status.hasStarted(2)
            return one && two
        }
        first.cancel()
        for _ in 0..<20 { await Task.yield() }
        let firstReturned = await status.hasReturned(1)
        let secondReturned = await status.hasReturned(2)
        XCTAssertFalse(firstReturned); XCTAssertFalse(secondReturned)
        XCTAssertTrue(store.isRetiring)
        XCTAssertNil(source.enter())
        XCTAssertEqual(try recordState(prepared), "active")
        heldOriginal.finish()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertTrue(firstResult); XCTAssertTrue(secondResult)
        XCTAssertEqual(try recordState(prepared), "clean")
        let repeated = await runtime.shutdown()
        XCTAssertTrue(repeated)
    }

    func testActualRuntimeShutdownWithoutHeldAppearanceReturnsClean() async throws {
        let (runtime, prepared, product, parent) = try await fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let original = product.appearance.store
        let result = await runtime.shutdown()
        XCTAssertTrue(result)
        XCTAssertTrue(original.isRetiring)
        XCTAssertEqual(try recordState(prepared), "clean")
    }
    func testActualRuntimeSelectsHostDeliveredWhenStoreNotPrematerialized() async throws {
        let (runtime, prepared, product, parent) = try await fixture(earlyMaterialization: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let selected = product.appearance.store
        XCTAssertTrue(product.appearance.materialized)
        try product.appearance.prepareSharedService(observation: .hostDelivered)
        XCTAssertTrue(product.appearance.store === selected)
        XCTAssertThrowsError(try product.appearance.prepareSharedService(observation: .system))
        let result = await runtime.shutdown()
        XCTAssertTrue(result)
        XCTAssertTrue(selected.isRetiring)
        XCTAssertEqual(try recordState(prepared), "clean")
    }

}
