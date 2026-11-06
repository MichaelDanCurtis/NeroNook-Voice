import XCTest
import Foundation
import Darwin
import Security
import NookPluginSDK
@testable import NookLocalServiceKit
@testable import ModuleApp

// The service authenticates this real same-process Unix peer through the SDK.
// This raw fixture intentionally leaves its write half open after observing FIN,
// unlike LocalServiceConnection, so the late application-fault case is observable.
private final class BusyRawPeer: @unchecked Sendable {
    let fd: Int32
    private var buffered = Data()
    private let closeLock = NSLock()
    private var closed = false
    init(path: String) throws {
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalServiceError.systemCall(errno) }
        do {
            try prepareLocalSocket(fd)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8) + [0]
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw LocalServiceError.unsafeRoot }
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw LocalServiceError.systemCall(errno) }
                try ready(Int16(POLLOUT), until: ContinuousClock.now.advanced(by: .seconds(5)))
                var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { throw LocalServiceError.systemCall(error) }
            }
        } catch { _ = Darwin.close(fd); throw error }
    }
    private func ready(_ event: Int16, until deadline: ContinuousClock.Instant) throws {
        while ContinuousClock.now < deadline {
            var value = pollfd(fd: fd, events: event, revents: 0)
            let result = Darwin.poll(&value, 1, 50)
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw LocalServiceError.systemCall(errno) }
            if result > 0 { return }
        }
        throw NSError(domain: "BusyPeer.watchdog", code: 1)
    }
    func send(_ envelope: PluginSharedApplicationEnvelope) async throws {
        let bytes = try PluginSharedApplicationCodec.encode(envelope)
        let original = Task.detached { [self] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    try ready(Int16(POLLOUT), until: deadline)
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR || errno == EAGAIN { continue }
                    guard count > 0 else { throw LocalServiceError.systemCall(errno) }
                    offset += count
                }
            }
        }
        try await original.value
    }
    // Exactly one fixture receive runs at a time. Each original is awaited even
    // if its caller is cancelled, and its finite watchdog fails rather than hangs.
    func receive() async throws -> PluginSharedApplicationEnvelope? {
        let original = Task.detached { [self] () throws -> PluginSharedApplicationEnvelope? in
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while true {
                if let end = buffered.firstIndex(of: 10) {
                    let bytes = Data(buffered[...end]); buffered.removeSubrange(...end)
                    return try PluginSharedApplicationCodec.decodeLine(bytes)
                }
                guard buffered.count <= PluginSharedApplicationLimits.maximumJSONBytes else { throw LocalServiceError.protocolViolation }
                try ready(Int16(POLLIN), until: deadline)
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, 4096) }
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count >= 0 else { throw LocalServiceError.systemCall(errno) }
                if count == 0 {
                    guard buffered.isEmpty else { throw LocalServiceError.protocolViolation }
                    return nil
                }
                buffered.append(contentsOf: bytes.prefix(count))
            }
        }
        return try await original.value
    }
    func finishSending() throws {
        guard Darwin.shutdown(fd, SHUT_WR) == 0 else { throw LocalServiceError.systemCall(errno) }
    }
    func close() throws {
        closeLock.lock(); let first = !closed; closed = true; closeLock.unlock()
        if first, Darwin.close(fd) != 0 { throw LocalServiceError.systemCall(errno) }
    }
    deinit { try? close() }
}

final class VoiceOwnerBusyRetirementTests: XCTestCase {
    @MainActor private final class Fixture {
        let runtime: VoiceServiceRuntime
        let prepared: VoiceServicePreparedStart
        let parent: URL
        var peers: [BusyRawPeer] = []
        var contexts: [VoiceClientContext] = []
        init(runtime: VoiceServiceRuntime, prepared: VoiceServicePreparedStart, parent: URL) {
            self.runtime = runtime; self.prepared = prepared; self.parent = parent
        }
        func attach() async throws -> (BusyRawPeer, VoiceClientContext, PluginSharedApplicationEnvelope) {
            let peer = try BusyRawPeer(path: prepared.owner.lock.root.socketPath); peers.append(peer)
            let session = UUID(), nonce = UUID()
            try await peer.send(.init(sequence: 0, session: session, payload: .attach(.init(
                serviceIdentifier: runtime.policy.serviceIdentifier, role: .moduleAdapter, nonce: nonce,
                features: ["retirement-v1", "plugin-message-v1"], requiredFeatures: ["retirement-v1", "plugin-message-v1"],
                requestedCapabilities: [], moduleIdentifier: runtime.policy.moduleIdentifier,
                resourceRevision: runtime.policy.resourceRevision))))
            let received = try await peer.receive()
            let hello = try XCTUnwrap(received)
            guard case .hello(let body) = hello.payload else { throw LocalServiceError.protocolViolation }
            XCTAssertEqual(body.clientNonce, nonce); XCTAssertEqual(hello.session, session)
            let context = try XCTUnwrap(runtime.contextForRetirementObservation(try XCTUnwrap(hello.connection)))
            contexts.append(context)
            XCTAssertFalse(context.approved)
            return (peer, context, hello)
        }
        func cleanUp() async {
            for peer in peers { do { try peer.close() } catch { XCTFail("Original fixture close failed: \(error)") } }
            for context in contexts {
                if !context.closing { context.failTransport() }
                _ = await context.retire(acknowledge: false).value
            }
            // Unknown fixtures remain diagnostic roots; never erase an uncertain
            // lineage or infer clean from a fixture destructor.
            if await runtime.shutdown() { try? FileManager.default.removeItem(at: parent) }
        }
    }
    @MainActor private func fixture() async throws -> Fixture {
        var code: SecCode?, staticCode: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              SecCodeCopyStaticCode(try XCTUnwrap(code), SecCSFlags(), &staticCode) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode), SecCSFlags(), &requirement) == errSecSuccess,
              SecCodeCheckValidity(try XCTUnwrap(code), SecCSFlags.noNetworkAccess, try XCTUnwrap(requirement)) == errSecSuccess,
              SecRequirementCopyString(try XCTUnwrap(requirement), SecCSFlags(), &text) == errSecSuccess else { throw VoiceServiceProblem.unavailable }
        let service = "test.nero.busy.s" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let native = try LocalServicePolicy(serviceIdentifier: service,
            trustedSelfRequirements: ["busy-test": try XCTUnwrap(text) as String],
            trustedPeerRequirements: ["busy-test": try XCTUnwrap(text) as String])
        let parent = URL(fileURLWithPath: "/private/tmp/nero-busy-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let policy = try VoiceServicePolicy(native: native, serviceIdentifier: service, moduleIdentifier: service,
            fullModulePolicyKey: "busy-test", capabilityPolicyKeys: [], lifecycleRoot: parent,
            resourceRevision: String(repeating: "0", count: 64), buildIdentifier: "authored-busy", permitsGlobalControls: false)
        let outcome = await VoiceServiceStartup.prepare(plan: .freshIsolated(parent: parent)) { policy }
        guard case .ready(let prepared) = outcome else { throw VoiceServiceProblem.unavailable }
        let product = try VoiceProductConfiguration.isolated(root: prepared.policy.lifecycleRoot.appendingPathComponent("Product", isDirectory: true),
                                                           revalidate: { try prepared.revalidateProductRoot() })
        let runtime = try VoiceServiceRuntime(owner: prepared.owner, policy: policy, ledger: prepared.ledger, epochID: prepared.epoch, productConfiguration: product)
        try runtime.start()
        return Fixture(runtime: runtime, prepared: prepared, parent: parent)
    }
    private func incoming(_ hello: PluginSharedApplicationEnvelope, sequence: UInt64,
                          payload: PluginSharedApplicationEnvelope.Payload, foreign: Bool = false) -> PluginSharedApplicationEnvelope {
        .init(sequence: sequence, session: foreign ? UUID() : hello.session,
              instance: hello.instance, connection: hello.connection, payload: payload)
    }
    @MainActor private func refusal(_ peer: BusyRawPeer, context: VoiceClientContext) async throws -> [PluginSharedStatusCode] {
        var statuses: [PluginSharedStatusCode] = [], detached = false
        for _ in 0..<12 {
            guard let envelope = try await peer.receive() else { break }
            switch envelope.payload {
            case .status(let value): statuses.append(value.code)
            case .heartbeat: break
            case .detached: detached = true
            default: XCTFail("Refused claim emitted approval/application data")
            }
            if detached { break }
        }
        XCTAssertTrue(detached)
        let eof = try await peer.receive(); XCTAssertNil(eof)
        try peer.finishSending()
        let returned = await context.retire(acknowledge: true).value
        XCTAssertTrue(returned); XCTAssertFalse(context.retirementUnknown); XCTAssertFalse(context.approved)
        return statuses
    }
    @MainActor private func stopOwner(_ peer: BusyRawPeer, context: VoiceClientContext,
                                     hello: PluginSharedApplicationEnvelope) async throws {
        try await peer.send(incoming(hello, sequence: 1, payload: .detach))
        var detached = false
        for _ in 0..<12 {
            guard let value = try await peer.receive() else { break }
            if case .detached = value.payload { detached = true; break }
        }
        XCTAssertTrue(detached)
        let eof = try await peer.receive(); XCTAssertNil(eof)
        try peer.finishSending()
        let released = await context.retire(acknowledge: true).value; XCTAssertTrue(released)
    }

    @MainActor func testSecondClaimDrainsOnlyItselfAndOriginalOwnerCanDetach() async throws {
        let f = try await fixture()
        do {
            let (owner, original, ownerHello) = try await f.attach()
            let (other, rejected, _) = try await f.attach()
            let statuses = try await refusal(other, context: rejected)
            XCTAssertEqual(statuses, [.ownerBusy, .draining])
            XCTAssertFalse(original.closing)
            let (third, thirdContext, _) = try await f.attach()
            let thirdStatuses = try await refusal(third, context: thirdContext)
            XCTAssertEqual(thirdStatuses.first, .ownerBusy)
            XCTAssertFalse(original.closing)
            try await stopOwner(owner, context: original, hello: ownerHello)
            let (successor, newOwner, successorHello) = try await f.attach()
            XCTAssertFalse(newOwner.closing)
            try await stopOwner(successor, context: newOwner, hello: successorHello)
        } catch { await f.cleanUp(); throw error }
        await f.cleanUp()
    }
    @MainActor func testFourUniqueApprovalRequestsAlreadyInFlightCannotPromptOrGrant() async throws {
        let f = try await fixture()
        do {
            let (_, owner, _) = try await f.attach()
            let (peer, rejected, hello) = try await f.attach()
            for sequence: UInt64 in 1...4 {
                try await peer.send(incoming(hello, sequence: sequence, payload: .approvalRequest(.init(id: UUID()))))
            }
            let statuses = try await refusal(peer, context: rejected)
            XCTAssertEqual(statuses, [.ownerBusy, .draining]); XCTAssertFalse(owner.closing)
        } catch { await f.cleanUp(); throw error }
        await f.cleanUp()
    }
    @MainActor func testDuplicateAndFifthClosingApprovalRequestsRemainUnknown() async throws {
        for duplicate in [true, false] {
            let f = try await fixture()
            do {
                let (_, owner, _) = try await f.attach()
                let (peer, rejected, hello) = try await f.attach()
                let first = UUID()
                for sequence: UInt64 in 1...(duplicate ? 2 : 5) {
                    try await peer.send(incoming(hello, sequence: sequence, payload: .approvalRequest(.init(id: duplicate ? first : UUID()))))
                }
                try? peer.finishSending()
                let returned = await rejected.retire(acknowledge: true).value
                XCTAssertFalse(returned); XCTAssertTrue(rejected.retirementUnknown)
                XCTAssertFalse(rejected.approved); XCTAssertFalse(owner.closing)
            } catch { await f.cleanUp(); throw error }
            await f.cleanUp()
        }
    }
    @MainActor func testForeignTupleAndApplicationFramesCannotEnterRejectedClaim() async throws {
        for foreign in [true, false] {
            let f = try await fixture()
            do {
                let (_, owner, _) = try await f.attach()
                let (peer, rejected, hello) = try await f.attach()
                let payload: PluginSharedApplicationEnvelope.Payload = foreign ? .heartbeat : .module(.init(plugin:
                    try PluginMessage(type: "hello", pluginID: f.runtime.policy.moduleIdentifier, session: hello.session).encoded()))
                try await peer.send(incoming(hello, sequence: 1, payload: payload, foreign: foreign))
                try? peer.finishSending()
                let returned = await rejected.retire(acknowledge: true).value
                XCTAssertFalse(returned); XCTAssertTrue(rejected.retirementUnknown); XCTAssertFalse(owner.closing)
            } catch { await f.cleanUp(); throw error }
            await f.cleanUp()
        }
    }
    @MainActor func testLateFaultAfterActualDetachedAndFINCannotBecomeClean() async throws {
        let f = try await fixture()
        do {
            let (_, owner, _) = try await f.attach()
            let (peer, rejected, hello) = try await f.attach()
            var detached = false
            for _ in 0..<12 {
                guard let envelope = try await peer.receive() else { break }
                if case .detached = envelope.payload { detached = true; break }
            }
            XCTAssertTrue(detached)
            let fin = try await peer.receive(); XCTAssertNil(fin) // raw client keeps write half open
            try await peer.send(incoming(hello, sequence: 1, payload: .heartbeat, foreign: true))
            let returned = await rejected.retire(acknowledge: true).value
            let native = await rejected.native.retirement()
            XCTAssertNil(native.failure) // actual physical completion alone is insufficient
            XCTAssertFalse(returned); XCTAssertTrue(rejected.retirementUnknown); XCTAssertFalse(owner.closing)
        } catch { await f.cleanUp(); throw error }
        await f.cleanUp()
    }
    @MainActor func testExplicitTransportFailureStaysUnknownWithoutStoppingOwner() async throws {
        let f = try await fixture()
        do {
            let (_, owner, _) = try await f.attach()
            let (_, rejected, _) = try await f.attach()
            rejected.failTransport()
            let returned = await rejected.retire(acknowledge: true).value
            XCTAssertFalse(returned); XCTAssertTrue(rejected.retirementUnknown); XCTAssertFalse(owner.closing)
        } catch { await f.cleanUp(); throw error }
        await f.cleanUp()
    }
}
