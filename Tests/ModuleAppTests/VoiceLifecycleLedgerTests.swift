import XCTest
import Foundation
import Darwin
import Security
import NookLocalServiceKit
@testable import ModuleApp

/// Actual bounded ledger files and the actual test host's native owner. These
/// authored clean records are explicit fixture setup, not operational enrollment,
/// consent, a microphone test or evidence that any legacy owner has retired.
final class VoiceLifecycleLedgerTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let owner: LocalServiceOwner
        let binding: VoiceLifecycleBinding
        var file: URL { root.appendingPathComponent("lifecycle-v1.json") }
        func ledger() throws -> VoiceLifecycleLedger { try .init(root: root, owner: owner, binding: binding) }
        func bytes(state: String = "clean", extra: [String: Any] = [:]) throws -> Data {
            var value: [String: Any] = ["formatVersion": 1, "epochID": UUID().uuidString,
                "serviceIdentifier": binding.serviceIdentifier, "buildIdentifier": "authored-fixture",
                "bootSessionUUID": binding.bootSessionUUID.uuidString, "ownPolicyKey": binding.ownPolicyKey,
                "state": state, "releasedFamilies": [String](), "reason": ""]
            extra.forEach { value[$0.key] = $0.value }
            return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
        func seed(_ data: Data) throws {
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: data,
                attributes: [.posixPermissions: 0o600]))
        }
    }
    private func fixture() throws -> Fixture {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        XCTAssertEqual(SecCodeCopySelf(SecCSFlags(), &code), errSecSuccess)
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), SecCSFlags(), &staticCode), errSecSuccess)
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode), SecCSFlags(), &requirement), errSecSuccess)
        XCTAssertEqual(SecCodeCheckValidity(try XCTUnwrap(code), SecCSFlags.noNetworkAccess,
                                          try XCTUnwrap(requirement)), errSecSuccess)
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement), SecCSFlags(), &text), errSecSuccess)
        let service = "test.nero.ledger.s" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let own = try XCTUnwrap(text) as String
        let policy = try LocalServicePolicy(serviceIdentifier: service,
            trustedSelfRequirements: ["ledger-test": own], trustedPeerRequirements: ["ledger-test": own])
        let owner = try LocalServiceOwner.acquire(policy: policy)
        let root = URL(fileURLWithPath: "/private/tmp/nero-voice-ledger-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return Fixture(root: root, owner: owner,
                       binding: .init(serviceIdentifier: service, buildIdentifier: "ledger-test-build",
                                      bootSessionUUID: UUID(), ownPolicyKey: owner.ownPolicyKey))
    }
    private func refuses(_ expected: VoiceLifecycleFailure,
                         _ operation: () async throws -> Void,
                         file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected refusal", file: file, line: line) }
        catch { XCTAssertEqual(error as? VoiceLifecycleFailure, expected, file: file, line: line) }
    }

    func testMissingRecordDoesNotCreateOrEnrollAnEpoch() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let ledger = try f.ledger()
        await refuses(.missingRecord) { _ = try await ledger.begin() }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.path), [])
        await refuses(.busy) { _ = try await ledger.begin() }
    }
    func testDurableActivePrecedesReturnedEpochAndCannotBeginTwice() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed(f.bytes())
        let ledger = try f.ledger(), epoch = try await ledger.begin()
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        XCTAssertEqual(saved["epochID"] as? String, epoch.uuidString)
        XCTAssertEqual(saved["state"] as? String, "active")
        XCTAssertEqual(saved["buildIdentifier"] as? String, f.binding.buildIdentifier)
        XCTAssertEqual(saved["releasedFamilies"] as? [String], [])
        var info = stat(); XCTAssertEqual(lstat(f.file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o600); XCTAssertEqual(info.st_nlink, 1)
        await refuses(.busy) { _ = try await ledger.begin() }
        let pending = await ledger.pendingWriteCompletion()
        XCTAssertNil(pending)
    }
    func testPriorActiveRemainsByteExactAndRefusesAcrossBootMetadata() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try f.bytes(state: "active", extra: ["bootSessionUUID": UUID().uuidString])
        try f.seed(original); let ledger = try f.ledger()
        await refuses(.recoveryRequired) { _ = try await ledger.begin() }
        XCTAssertEqual(try Data(contentsOf: f.file), original)
    }
    func testExplicitRecoveryRecordRefusesWithoutReplayOrRewrite() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try f.bytes(state: "recoveryRequired", extra: ["reason": "unknown-worker-return"])
        try f.seed(original); let ledger = try f.ledger()
        await refuses(.recoveryRequired) { _ = try await ledger.begin() }
        XCTAssertEqual(try Data(contentsOf: f.file), original)
    }
    func testDuplicateAndUnknownRecordMembersDoNotBecomeClean() async throws {
        for malformed in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            var original = try f.bytes(extra: malformed ? ["unexpected": "not-allowed"] : [:])
            if !malformed {
                original = Data(("{\"formatVersion\":1," + String(decoding: original.dropFirst(), as: UTF8.self)).utf8)
            }
            try f.seed(original); let ledger = try f.ledger()
            await refuses(.unsafeRecord) { _ = try await ledger.begin() }
            XCTAssertEqual(try Data(contentsOf: f.file), original)
        }
    }
    func testOversizedRecordIsRejectedBeforeReadingItsPayload() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = Data(repeating: 32, count: 65_537)
        try f.seed(original); let ledger = try f.ledger()
        await refuses(.unsafeRecord) { _ = try await ledger.begin() }
        XCTAssertEqual(try Data(contentsOf: f.file), original)
    }
    func testSymlinkAndHardlinkRecordsAreNeverAdopted() async throws {
        for hardlink in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let target = f.root.appendingPathComponent("authored-target"), original = try f.bytes()
            XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: original,
                attributes: [.posixPermissions: 0o600]))
            if hardlink { XCTAssertEqual(link(target.path, f.file.path), 0) }
            else { XCTAssertEqual(symlink(target.path, f.file.path), 0) }
            let ledger = try f.ledger()
            await refuses(.unsafeRecord) { _ = try await ledger.begin() }
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }
    func testFifoIsRefusedWithoutOpeningAWriterOrWaitingForOne() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertEqual(mkfifo(f.file.path, 0o600), 0); let ledger = try f.ledger()
        await refuses(.unsafeRecord) { _ = try await ledger.begin() }
        var value = stat(); XCTAssertEqual(lstat(f.file.path, &value), 0)
        XCTAssertEqual(value.st_mode & S_IFMT, S_IFIFO)
    }
    func testOriginalRootReplacementRefusesEvenWithIdenticalRecordBytes() async throws {
        let f = try fixture(), moved = f.root.appendingPathExtension("held")
        defer { try? FileManager.default.removeItem(at: f.root); try? FileManager.default.removeItem(at: moved) }
        let original = try f.bytes(); try f.seed(original); let ledger = try f.ledger()
        try FileManager.default.moveItem(at: f.root, to: moved)
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        try f.seed(original)
        await refuses(.unsafeRoot) { _ = try await ledger.begin() }
        XCTAssertEqual(try Data(contentsOf: f.file), original)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("lifecycle-v1.json")), original)
    }
    func testCreatingAChildDirectoryDoesNotReplaceTheOriginalRoot() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed(f.bytes()); let ledger = try f.ledger()
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("authored-child"),
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _ = try await ledger.begin()
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        XCTAssertEqual(saved["state"] as? String, "active")
    }
    func testSymlinkRootIsRejectedWithoutFollowingOrWritingItsTarget() throws {
        let f = try fixture(), alias = f.root.appendingPathExtension("alias")
        defer { try? FileManager.default.removeItem(at: alias); try? FileManager.default.removeItem(at: f.root) }
        let original = try f.bytes(); try f.seed(original)
        XCTAssertEqual(symlink(f.root.path, alias.path), 0)
        XCTAssertThrowsError(try VoiceLifecycleLedger(root: alias, owner: f.owner, binding: f.binding)) {
            XCTAssertEqual($0 as? VoiceLifecycleFailure, .unsafeRoot)
        }
        XCTAssertEqual(try Data(contentsOf: f.file), original)
    }
    func testChangedActiveRecordCannotBeOverwrittenByRecoveryWrite() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed(f.bytes()); let ledger = try f.ledger(); _ = try await ledger.begin()
        let replacement = try f.bytes(extra: ["buildIdentifier": "external-edit"])
        try replacement.write(to: f.file)
        await refuses(.unsafeRecord) { try await ledger.markRecoveryRequired(reason: "unknown-worker-return") }
        XCTAssertEqual(try Data(contentsOf: f.file), replacement)
    }
    func testRecoveryWriteRetainsEpochAndIsNotASuccessfulClean() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed(f.bytes()); let ledger = try f.ledger(); let epoch = try await ledger.begin()
        try await ledger.markRecoveryRequired(reason: "unknown-worker-return")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        XCTAssertEqual(saved["state"] as? String, "recoveryRequired")
        XCTAssertEqual(saved["epochID"] as? String, epoch.uuidString)
        let successor = try f.ledger()
        await refuses(.recoveryRequired) { _ = try await successor.begin() }
    }

    @MainActor func testActualRegistryWaitsForOriginalFamilyBeforeCommittingClean() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed(f.bytes()); let ledger = try f.ledger(), epoch = try await ledger.begin()
        let registry = VoiceResourceRegistry(epochID: epoch), gate = VoiceLedgerTestGate()
        let entered = expectation(description: "Original authored output-family return is held")
        for family in VoiceResourceFamily.allCases {
            try registry.register(family) { _ in
                if family == .output { entered.fulfill(); await gate.wait() }
                return .released(.cancelled)
            }
        }
        let original = registry.closeAndDrain()
        await fulfillment(of: [entered], timeout: 5)
        let whileHeld = try? Data(contentsOf: f.file)
        XCTAssertThrowsError(try registry.requireAdmission())
        await gate.release()
        let report = await original.value
        XCTAssertTrue(report.fullyReleased)
        let witness = try XCTUnwrap(report.cleanWitness)
        XCTAssertEqual(witness.epochID, epoch)
        XCTAssertEqual(Set(witness.releasedFamilies), Set(VoiceResourceFamily.allCases.map(\.rawValue)))
        try await ledger.commitClean(witness)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        let held = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(whileHeld)) as? [String: Any])
        XCTAssertEqual(held["state"] as? String, "active")
        XCTAssertEqual(saved["state"] as? String, "clean")
        XCTAssertEqual(saved["releasedFamilies"] as? [String], witness.releasedFamilies.sorted())
        // Genuine source-registry witness cannot reopen the permanently sealed
        // original registry; a fresh durable active epoch is a separate admission.
        XCTAssertThrowsError(try registry.requireAdmission())
        let next = try f.ledger(), nextEpoch = try await next.begin()
        XCTAssertNotEqual(nextEpoch, epoch)
    }
    @MainActor func testUnknownOriginalFamilyNeverMintsCleanWitness() async throws {
        let registry = VoiceResourceRegistry(epochID: UUID())
        for family in VoiceResourceFamily.allCases {
            try registry.register(family) { _ in
                family == .output ? .unknown("native-return-unverified") : .released(.failed)
            }
        }
        let report = await registry.closeAndDrain().value
        XCTAssertFalse(report.fullyReleased); XCTAssertNil(report.cleanWitness)
        XCTAssertThrowsError(try registry.requireAdmission())
    }
    @MainActor func testOtherEpochRegistryWitnessCannotRewriteActiveRecord() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.seed(f.bytes()); let ledger = try f.ledger(); _ = try await ledger.begin()
        let originalBytes = try Data(contentsOf: f.file)
        let other = VoiceResourceRegistry(epochID: UUID())
        for family in VoiceResourceFamily.allCases {
            try other.register(family) { _ in .released(.succeeded) }
        }
        let report = await other.closeAndDrain().value, witness = try XCTUnwrap(report.cleanWitness)
        await refuses(.staleWitness) { try await ledger.commitClean(witness) }
        XCTAssertEqual(try Data(contentsOf: f.file), originalBytes)
    }
    func testAlreadyCancelledAdmissionPreservesPriorCleanBytes() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try f.bytes(); try f.seed(original)
        let ledger = try f.ledger(), gate = VoiceLedgerTestGate()
        let task = Task { await gate.wait(); return try await ledger.begin() }
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled startup must not admit a runtime") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: f.file), original)
    }
}

private actor VoiceLedgerTestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let originals = waiters; waiters.removeAll()
        originals.forEach { $0.resume() }
    }
}
