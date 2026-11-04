import Foundation
import XCTest
import NookPluginSDK
@testable import NookLocalServiceKit
#if os(macOS)
import Darwin

private func frame(_ sequence: UInt64 = 1, large: Bool = false) throws -> PluginSharedApplicationEnvelope {
    let payload: PluginSharedApplicationEnvelope.Payload
    if large {
        let bytes = try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: (0..<4).map { ("field\($0)", String(repeating: "x", count: 1_900)) }))
        payload = .invoke(PluginSharedInvoke(run: UUID(), capability: "test_echo", values: bytes))
    } else {
        let bytes = try JSONSerialization.data(withJSONObject: ["text": "café 🌿"])
        payload = .invoke(PluginSharedInvoke(run: UUID(), capability: "test_echo", values: bytes))
    }
    return PluginSharedApplicationEnvelope(sequence: sequence, session: UUID(), instance: UUID(), connection: UUID(), payload: payload)
}
private func waitFor(_ description: String, _ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        if ContinuousClock.now >= deadline { throw NSError(domain: "NativeKitTest.watchdog.\(description)", code: 1) }
        try await Task.sleep(for: .milliseconds(2))
    }
}
private func writeAll(_ data: Data, _ fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw LocalServiceError.systemCall(errno) }
            offset += written
        }
    }
}
private func withRawSocket(_ body: (LocalSocketIO, Int32) async throws -> Void) async throws -> LocalServiceIOCompletion {
    var pair: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw LocalServiceError.systemCall(errno) }
    var sendBuffer: Int32 = 4096
    guard setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        let failure = LocalServiceError.systemCall(errno); _ = Darwin.close(pair[0]); _ = Darwin.close(pair[1]); throw failure
    }
    let io: LocalSocketIO
    do { io = try LocalSocketIO(fd: pair[0], validate: {}, invalidate: {}, drain: { nil }) }
    catch { _ = Darwin.close(pair[0]); _ = Darwin.close(pair[1]); throw error }
    defer { _ = Darwin.close(pair[1]) }
    do { try await body(io, pair[1]) }
    catch { io.stop(); _ = await io.retirement(); throw error }
    io.stop()
    let completion = await io.retirement()
    XCTAssertEqual(fcntl(pair[0], F_GETFD), -1); XCTAssertEqual(errno, EBADF)
    return completion
}
private func publicPair(_ policy: LocalServicePolicy) async throws -> (LocalServiceOwner, LocalServiceListener, LocalServiceConnection, LocalServiceConnection) {
    let owner = try LocalServiceOwner.acquire(policy: policy)
    let listener = try LocalServiceListener(owner: owner, policy: policy)
    let accepted = Task { try await listener.accept() }
    do {
        let client = try await LocalServiceConnection.connect(policy: policy)
        do {
            guard let server = try await accepted.value else { throw LocalServiceError.disconnected }
            return (owner, listener, client, server)
        } catch { client.stopIO(); _ = await client.retirement(); throw error }
    } catch {
        listener.stopAccepting(); _ = try? await accepted.value; _ = await listener.retirement(); throw error
    }
}
private func retire(_ listener: LocalServiceListener, _ client: LocalServiceConnection, _ server: LocalServiceConnection) async {
    listener.stopAccepting(); client.stopIO(); server.stopIO()
    _ = await listener.retirement(); _ = await client.retirement(); _ = await server.retirement()
}

// Start each original write and observe its actual queue admission (or real
// successful return) before sealing. No Task-construction-as-admission oracle.
private func admitBackpressuredWrites(_ io: LocalSocketIO, _ envelope: PluginSharedApplicationEnvelope,
                                     count: Int) async throws -> [Task<Void, Error>] {
    var originals: [Task<Void, Error>] = []
    do {
        for _ in 0..<count {
            let id = UUID(), returned = LockedState(false)
            let original = Task {
                defer { returned.withLock { $0 = true } }
                try await io.send(envelope, observerID: id)
            }
            originals.append(original)
            try await waitFor("original write admission") { io.containsQueuedWrite(id) || returned.withLock { $0 } }
            if returned.withLock({ $0 }) { try await original.value }
        }
        return originals
    } catch { io.stop(); for original in originals { _ = try? await original.value }; throw error }
}
private func readActualEOF(_ fd: Int32, maximumBytes: Int) throws -> Int {
    var total = 0, bytes = [UInt8](repeating: 0, count: 65_536)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while true {
        guard ContinuousClock.now < deadline else {
            throw NSError(domain: "NativeKitTest.watchdog.actualEOF", code: 1)
        }
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&event, 1, 100)
        if ready < 0, errno == EINTR { continue }
        guard ready >= 0 else { throw LocalServiceError.systemCall(errno) }
        if ready == 0 { continue }
        // Exactly one fixture reader owns fd. A timeout is a thrown failure;
        // only an actual zero-byte read below can report successful EOF.
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw LocalServiceError.systemCall(errno) }
        if count == 0 { return total }
        guard count <= maximumBytes - total else { throw LocalServiceError.protocolViolation }
        total += count
    }
}

final class ConnectionTests: XCTestCase {
    func testActualPublicDuplexPreservesUnicodeAndNativePeerCannotRevive() async throws {
        let (owner, listener, client, server) = try await publicPair(genuineNativeTestPolicy())
        do {
            let sent = try frame()
            try await client.send(sent)
            let received = try await server.receive()
            XCTAssertEqual(try received.map(PluginSharedApplicationCodec.encode), try PluginSharedApplicationCodec.encode(sent))
            try await server.send(try frame(2))
            let response = try await client.receive()
            XCTAssertEqual(response?.sequence, 2)
            try owner.revalidate(); try server.peer.revalidate(); try client.peer.revalidate()
        } catch { await retire(listener, client, server); throw error }
        await retire(listener, client, server)
        XCTAssertThrowsError(try client.peer.revalidate()) { XCTAssertEqual($0 as? LocalServiceError, .changedIdentity) }
        XCTAssertThrowsError(try server.peer.revalidate()) { XCTAssertEqual($0 as? LocalServiceError, .changedIdentity) }
    }

    func testActualPublicFinalFrameThenCleanEOFUsesOriginalDeliveryCustody() async throws {
        // Changed input from original008: terminal sender now seals/drains its
        // real write side and retains its FD, rather than immediately aborting.
        // Four fixed pairs remain authored cases, never retries on a failure.
        for sequence: UInt64 in 1...4 {
            let (_, listener, client, server) = try await publicPair(genuineNativeTestPolicy())
            let pending = Task { try await server.receive() }
            do {
                try await client.send(try frame(sequence))
                try await client.finishSending()
                let last = try await pending.value
                XCTAssertEqual(last?.sequence, sequence)
                let eof = try await server.receive(), repeatedEOF = try await server.receive()
                XCTAssertNil(eof); XCTAssertNil(repeatedEOF)
                let serverResult = await server.retirement()
                XCTAssertNil(serverResult.failure)
                let senderEOF = try await client.receive()
                XCTAssertNil(senderEOF)
                let clientResult = await client.retirement()
                XCTAssertNil(clientResult.failure)
            } catch { await retire(listener, client, server); _ = try? await pending.value; throw error }
            await retire(listener, client, server)
        }
    }

    func testListenerStopLeavesAdmittedConnectionsAliveAndAcceptedOwnerHeld() async throws {
        let policy = try genuineNativeTestPolicy()
        var pair: (LocalServiceOwner, LocalServiceListener, LocalServiceConnection, LocalServiceConnection)? = try await publicPair(policy)
        let client = try XCTUnwrap(pair).2, server = try XCTUnwrap(pair).3
        do {
            try XCTUnwrap(pair).1.stopAccepting()
            let completion = try await XCTUnwrap(pair).1.retirement()
            XCTAssertNil(completion.failure)
            pair = nil // Only the admitted server's original IO now holds owner.
            XCTAssertThrowsError(try LocalServiceOwner.acquire(policy: policy)) { XCTAssertEqual($0 as? LocalServiceError, .ownerPresent) }
            try await client.send(try frame(5))
            let response = try await server.receive()
            XCTAssertEqual(response?.sequence, 5)
        } catch {
            pair?.1.stopAccepting(); client.stopIO(); server.stopIO()
            if let pair { _ = await pair.1.retirement() }
            _ = await client.retirement(); _ = await server.retirement(); throw error
        }
        client.stopIO(); server.stopIO(); _ = await client.retirement(); _ = await server.retirement()
        let successor = try LocalServiceOwner.acquire(policy: policy)
        try successor.revalidate()
    }

    func testConcurrentAcceptAndCancelledObserverDoNotDisplaceSuccessor() async throws {
        let policy = try genuineNativeTestPolicy(), owner = try LocalServiceOwner.acquire(policy: policy)
        let listener = try LocalServiceListener(owner: owner, policy: policy)
        let first = Task { try await listener.accept() }
        do {
            try await waitFor("accept reservation") { listener.pendingAccept }
            do { _ = try await listener.accept(); XCTFail("Second accept admitted") }
            catch { XCTAssertEqual(error as? LocalServiceError, .concurrentAccept) }
            first.cancel()
            do { _ = try await first.value; XCTFail("Cancelled observer succeeded") } catch { XCTAssertTrue(error is CancellationError) }
            let next = Task { try await listener.accept() }
            let client = try await LocalServiceConnection.connect(policy: policy)
            do {
                let accepted = try await next.value
                let server = try XCTUnwrap(accepted)
                try await client.send(try frame(6))
                let response = try await server.receive()
                XCTAssertEqual(response?.sequence, 6)
                await retire(listener, client, server)
            } catch {
                client.stopIO(); _ = await client.retirement(); listener.stopAccepting()
                if let server = try? await next.value { server.stopIO(); _ = await server.retirement() }
                throw error
            }
        } catch {
            listener.stopAccepting(); _ = try? await first.value; _ = await listener.retirement(); throw error
        }
    }

    func testRawFragmentWithoutLFIsHeldAndMultipleFramesStayOrdered() async throws {
        let completion = try await withRawSocket { io, peer in
            let first = try frame(7), bytes = try PluginSharedApplicationCodec.encode(first)
            let pending = Task { try await io.receive() }
            do {
                try writeAll(Data(bytes.dropLast()), peer)
                try await waitFor("fragment read") { io.bufferedByteCount == bytes.count - 1 }
                XCTAssertTrue(io.pendingReceive)
                try writeAll(Data([10]) + (try PluginSharedApplicationCodec.encode(frame(8))), peer)
                let received = try await pending.value
                XCTAssertEqual(received.envelope?.sequence, 7); received.release()
                let next = try await io.receive()
                XCTAssertEqual(next.envelope?.sequence, 8); next.release()
            } catch { io.stop(); if let held = try? await pending.value { held.release() }; throw error }
        }
        XCTAssertNil(completion.failure)
    }

    func testHeldDeliveryRejectsConcurrentReceiveAndRetainsOriginalRetirement() async throws {
        let completion = try await withRawSocket { io, peer in
            try writeAll(try PluginSharedApplicationCodec.encode(frame(9)), peer)
            let held = try await io.receive()
            do {
                do { _ = try await io.receive(); XCTFail("Second delivery admitted") }
                catch { XCTAssertEqual(error as? LocalServiceError, .concurrentReceive) }
                let retired = LockedState(false)
                io.stop()
                let original = Task { let result = await io.retirement(); retired.withLock { $0 = true }; return result }
                // The actual observer still owns its delivery receipt; merely
                // yielding cannot certify closure. Release is the causal gate.
                for _ in 0..<100 { await Task.yield() }
                XCTAssertFalse(retired.withLock { $0 })
                held.release(); _ = await original.value
                XCTAssertTrue(retired.withLock { $0 })
            } catch { held.release(); throw error }
        }
        XCTAssertNil(completion.failure)
    }

    func testCancelledReceivePreservesSubsequentFrameAndOldCancellationIsScoped() async throws {
        let completion = try await withRawSocket { io, peer in
            let first = Task { try await io.receive() }
            do {
                try await waitFor("receive reservation") { io.pendingReceive }
                do { _ = try await io.receive(); XCTFail("Concurrent receive admitted") }
                catch { XCTAssertEqual(error as? LocalServiceError, .concurrentReceive) }
                first.cancel()
                do { _ = try await first.value; XCTFail("Cancelled receive succeeded") } catch { XCTAssertTrue(error is CancellationError) }
                let successor = Task { try await io.receive() }
                try await waitFor("successor reservation") { io.pendingReceive }
                first.cancel()
                try writeAll(try PluginSharedApplicationCodec.encode(frame(10)), peer)
                let delivered = try await successor.value
                XCTAssertEqual(delivered.envelope?.sequence, 10); delivered.release()
            } catch { io.stop(); if let held = try? await first.value { held.release() }; throw error }
        }
        XCTAssertNil(completion.failure)
    }

    func testMalformedAndTruncatedActualSocketFramesFailAndDrain() async throws {
        for bytes in [Data("{\"unknown\":true}\n".utf8), Data("{\"version\":1".utf8)] {
            let completion = try await withRawSocket { io, peer in
                try writeAll(bytes, peer); XCTAssertEqual(shutdown(peer, SHUT_WR), 0)
                do { let held = try await io.receive(); held.release(); XCTFail("Invalid frame admitted") }
                catch { XCTAssertEqual(error as? LocalServiceError, .protocolViolation) }
            }
            XCTAssertEqual(completion.failure, .protocolViolation)
        }
    }

    func testActualWriteFIFOIncludingActiveBytesIsBoundedUnderBackpressure() async throws {
        let completion = try await withRawSocket { io, peer in
            var small: Int32 = 1024
            XCTAssertEqual(setsockopt(peer, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size)), 0)
            let large = try frame(11, large: true)
            let refusals = LockedState(0)
            let sends = (0..<180).map { _ in Task<LocalServiceError?, Never> {
                do { try await io.send(large); return nil }
                catch {
                    let reason = error as? LocalServiceError
                    if reason == .capacity { refusals.withLock { $0 += 1 } }
                    return reason
                }
            } }
            do {
                try await waitFor("actual capacity refusal") { refusals.withLock { $0 > 0 } }
                XCTAssertLessThanOrEqual(io.queuedByteCount, PluginSharedApplicationLimits.maximumQueuedBytes)
                io.stop()
                var capacity = 0
                for send in sends { if await send.value == .capacity { capacity += 1 } }
                XCTAssertGreaterThan(capacity, 0)
            } catch { io.stop(); for send in sends { _ = await send.value }; throw error }
        }
        XCTAssertNil(completion.failure)
    }

    func testCancelledSendObserverRetainsAdmittedQueueUntilOriginalStopDrains() async throws {
        let completion = try await withRawSocket { io, peer in
            var small: Int32 = 1024
            XCTAssertEqual(setsockopt(peer, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size)), 0)
            let large = try frame(12, large: true)
            let originals = (0..<50).map { _ in Task { try await io.send(large) } }
            var cancelled: Task<Void, Error>?
            do {
                try await waitFor("original backpressure") { io.queuedByteCount > 100_000 }
                let id = UUID()
                let own = Task { try await io.send(large, observerID: id) }; cancelled = own
                try await waitFor("cancelled admission") { io.containsQueuedWrite(id) }
                do { try await io.send(large, observerID: id); XCTFail("Duplicate active observer ID admitted") }
                catch { XCTAssertEqual(error as? LocalServiceError, .protocolViolation) }
                own.cancel()
                do { try await own.value; XCTFail("Cancelled send observer succeeded") }
                catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertTrue(io.containsQueuedWrite(id))
                io.stop()
                for original in originals { _ = try? await original.value }
            } catch {
                io.stop(); if let cancelled { _ = try? await cancelled.value }
                for original in originals { _ = try? await original.value }; throw error
            }
        }
        XCTAssertNil(completion.failure)
    }

    func testClosedPeerSendDoesNotStrandOriginalObservers() async throws {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw LocalServiceError.systemCall(errno) }
        let io: LocalSocketIO
        do { io = try LocalSocketIO(fd: pair[0], validate: {}, invalidate: {}, drain: { nil }) }
        catch { _ = Darwin.close(pair[0]); _ = Darwin.close(pair[1]); throw error }
        XCTAssertEqual(Darwin.close(pair[1]), 0)
        do { try await io.send(try frame(12, large: true)); XCTFail("Disconnected write succeeded") } catch {}
        io.stop(); _ = await io.retirement()
        XCTAssertEqual(fcntl(pair[0], F_GETFD), -1); XCTAssertEqual(errno, EBADF)
        // This proves closed-peer send/cleanup returns in the actual host. The
        // read pump may win EOF before write, so it does not claim an observed
        // EPIPE syscall or independently qualify the SO_NOSIGPIPE branch.
    }
    func testImmediateFullCloseBeforeReceiveRefusesUnprovedFinalFrame() async throws {
        let (_, listener, client, server) = try await publicPair(genuineNativeTestPolicy())
        do {
            try await client.send(try frame(20))
            client.stopIO()
            _ = await client.retirement() // Actual full FD retirement, not a delay.
            do { _ = try await server.receive(); XCTFail("Unproved final data admitted after full peer retirement") }
            catch { XCTAssertEqual(error as? LocalServiceError, .changedIdentity) }
            let completion = await server.retirement()
            XCTAssertEqual(completion.failure, .changedIdentity)
        } catch { await retire(listener, client, server); throw error }
        await retire(listener, client, server)
    }

    func testRepeatedFinishSealsNewSendsAndRetainsItsOriginalReceiptAfterEOF() async throws {
        let (_, listener, client, server) = try await publicPair(genuineNativeTestPolicy())
        do {
            try await client.send(try frame(21))
            let first = Task { try await client.finishSending() }
            let second = Task { try await client.finishSending() }
            try await first.value; try await second.value
            do { try await client.send(try frame(22)); XCTFail("Send admitted after outbound seal") }
            catch { XCTAssertEqual(error as? LocalServiceError, .disconnected) }
            let last = try await server.receive()
            XCTAssertEqual(last?.sequence, 21)
            let receiverEOF = try await server.receive()
            XCTAssertNil(receiverEOF)
            let receiverResult = await server.retirement()
            XCTAssertNil(receiverResult.failure)
            let senderEOF = try await client.receive()
            XCTAssertNil(senderEOF)
            let originalResult = await client.retirement()
            XCTAssertNil(originalResult.failure)
            try await client.finishSending() // Observe original receipt, no new syscall.
            XCTAssertThrowsError(try client.peer.revalidate()) { XCTAssertEqual($0 as? LocalServiceError, .changedIdentity) }
            let afterStaleQuery = await client.retirement()
            XCTAssertNil(afterStaleQuery.failure) // Stale query cannot poison completed cleanup.
        } catch { await retire(listener, client, server); throw error }
        await retire(listener, client, server)
    }

    func testCancelledFinishObserverWaitsForOriginalBackpressuredHalfClose() async throws {
        let completion = try await withRawSocket { io, peer in
            let envelope = try frame(23, large: true), count = 30
            let originals = try await admitBackpressuredWrites(io, envelope, count: count)
            let settled = LockedState(false)
            let cancelled = Task {
                defer { settled.withLock { $0 = true } }
                try await io.finishSending()
            }
            var repeated: Task<Void, Error>?, reader: Task<Int, Error>?
            do {
                try await waitFor("finish outbound seal") { io.outboundSealed }
                XCTAssertGreaterThan(io.queuedByteCount, 100_000)
                cancelled.cancel()
                for _ in 0..<100 { await Task.yield() }
                XCTAssertFalse(settled.withLock { $0 }) // Held FIFO is the causal gate.
                repeated = Task { try await io.finishSending() }
                let expected = try PluginSharedApplicationCodec.encode(envelope).count * count
                let drain = Task.detached { try readActualEOF(peer, maximumBytes: expected) }; reader = drain
                let actualBytes = try await drain.value
                XCTAssertEqual(actualBytes, expected)
                try await repeated?.value
                do { try await cancelled.value; XCTFail("Cancelled finish observer succeeded") }
                catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertTrue(settled.withLock { $0 })
                for original in originals { try await original.value }
                try await io.finishSending() // Same completed owner, no new half-close.
                do { try await io.send(envelope); XCTFail("Sealed IO accepted another line") }
                catch { XCTAssertEqual(error as? LocalServiceError, .disconnected) }
            } catch {
                io.stop(); _ = try? await cancelled.value; _ = try? await repeated?.value; _ = try? await reader?.value
                for original in originals { _ = try? await original.value }; throw error
            }
        }
        XCTAssertNil(completion.failure)
    }

    func testStopBeforeFinishDrainCannotReportSuccessfulHalfClose() async throws {
        let completion = try await withRawSocket { io, _ in
            let originals = try await admitBackpressuredWrites(io, frame(24, large: true), count: 30)
            let finish = Task { try await io.finishSending() }
            do {
                try await waitFor("aborted finish outbound seal") { io.outboundSealed }
                XCTAssertGreaterThan(io.queuedByteCount, 100_000)
                io.stop() // Explicit abort wins while real whole lines remain.
                do { try await finish.value; XCTFail("Abort discarded queued bytes but reported finish success") }
                catch { XCTAssertEqual(error as? LocalServiceError, .disconnected) }
                do { try await io.finishSending(); XCTFail("Repeated finish replaced the original aborted result") }
                catch { XCTAssertEqual(error as? LocalServiceError, .disconnected) }
                for original in originals { _ = try? await original.value }
            } catch { io.stop(); _ = try? await finish.value; for original in originals { _ = try? await original.value }; throw error }
        }
        XCTAssertNil(completion.failure) // Intentional Stop is not a later native fault.
    }

    func testActivePublicPeerOwnerFaultSurvivesRestoredMetadataAndActualEOF() async throws {
        let (owner, listener, client, server) = try await publicPair(genuineNativeTestPolicy())
        let root = owner.lock.root, name = root.digest + ".lock"
        let fd = openat(root.directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { await retire(listener, client, server); throw LocalServiceError.systemCall(errno) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_uid == geteuid(), original.st_nlink == 1, original.st_mode & 0o7777 == 0o600 else {
            _ = Darwin.close(fd); await retire(listener, client, server); throw LocalServiceError.unsafeRoot
        }
        defer { _ = fchmod(fd, original.st_mode & 0o7777); _ = Darwin.close(fd) }
        do {
            listener.stopAccepting()
            let listenerResult = await listener.retirement()
            XCTAssertNil(listenerResult.failure) // No competing periodic listener check.
            var named = stat()
            guard fstatat(root.directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_dev == original.st_dev, named.st_ino == original.st_ino else { throw LocalServiceError.unsafeRoot }
            guard fchmod(fd, 0o640) == 0 else { throw LocalServiceError.systemCall(errno) }
            XCTAssertThrowsError(try server.peer.revalidate()) { XCTAssertEqual($0 as? LocalServiceError, .unsafeRoot) }
            guard fchmod(fd, original.st_mode & 0o7777) == 0 else { throw LocalServiceError.systemCall(errno) }
            XCTAssertThrowsError(try server.peer.revalidate()) { XCTAssertEqual($0 as? LocalServiceError, .changedIdentity) }
            try await client.finishSending()
            let actualEOF = try await server.receive()
            XCTAssertNil(actualEOF) // Actual zero-byte read, never a timeout/cached proof.
            let failed = await server.retirement()
            XCTAssertEqual(failed.failure, .unsafeRoot) // Original active cause survives EOF/close.
            switch failed.status { case .failed: break; case .closed: XCTFail("EOF rehabilitated failed native ownership") }
            let senderEOF = try await client.receive()
            XCTAssertNil(senderEOF)
            _ = await client.retirement()
            let again = await server.retirement()
            XCTAssertEqual(again.failure, .unsafeRoot)
        } catch { await retire(listener, client, server); throw error }
        await retire(listener, client, server)
    }

}
#endif
