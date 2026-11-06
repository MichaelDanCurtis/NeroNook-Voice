import Foundation
import NookPluginSDK
#if os(macOS)
import Darwin

private func nativeError(_ error: Error) -> LocalServiceError { error as? LocalServiceError ?? .protocolViolation }

func prepareLocalSocket(_ fd: Int32) throws {
    let flags = fcntl(fd, F_GETFL)
    var yes: Int32 = 1
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
          fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
          setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw LocalServiceError.systemCall(errno)
    }
}

private func unixAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw LocalServiceError.unsafeRoot }
    withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

final class LocalSocketDelivery: Sendable {
    let envelope: PluginSharedApplicationEnvelope?
    private let releaseOriginal: @Sendable () -> Void
    init(_ envelope: PluginSharedApplicationEnvelope?, release: @escaping @Sendable () -> Void = {}) {
        self.envelope = envelope; releaseOriginal = release
    }
    func release() { releaseOriginal() }
    deinit { releaseOriginal() }
}

// This is the real bounded IO engine, without a native-principal constructor.
// Public Connection creates it only after mandatory NativePeerProof succeeds.
// Internal socketpair tests exercise the same engine, not a fake Peer/Connection.
final class LocalSocketIO: Sendable {
    private struct Receive {
        let id: UUID
        var continuation: CheckedContinuation<LocalSocketDelivery, Error>?
        var cancelled = false
    }
    private struct Write {
        let id: UUID
        let bytes: Data
        var offset = 0
        var installed = false
        var cancelled = false
        var continuation: CheckedContinuation<Void, Error>?
    }
    private struct State {
        let fd: Int32
        var stopped = false
        var failure: LocalServiceError?
        var raw = Data()
        var decoded: PluginSharedApplicationEnvelope?
        var delivery: UUID?
        var eof = false
        var receive: Receive?
        var writes: [Write] = []
        var queuedBytes = 0
        var finishRequested = false
        var finishNativeStarted = false
        var finishResult: Result<Void, LocalServiceError>?
        var explicitAbort = false
    }
    private let state: LockedState<State>
    private let readWake = DispatchSemaphore(value: 0)
    private let writeWake = DispatchSemaphore(value: 0)
    private let cleanup: Task<LocalServiceIOCompletion, Never>
    private let stopReturned: AsyncStream<Void>.Continuation
    private let deliveryReturned: AsyncStream<Void>.Continuation
    private let finishReturned: AsyncStream<Result<Void, LocalServiceError>>.Continuation
    private let finishCompletion: Task<Result<Void, LocalServiceError>, Never>
    private let validate: @Sendable () throws -> Void
    private let invalidate: @Sendable () -> Void
    private let failureSnapshot: @Sendable () -> LocalServiceError?

    init(fd: Int32, validate: @escaping @Sendable () throws -> Void,
         invalidate: @escaping @Sendable () -> Void,
         drain: @escaping @Sendable () async -> LocalServiceError?,
         failureSnapshot: @escaping @Sendable () -> LocalServiceError? = { nil },
         retired: @escaping @Sendable () -> Void = {}) throws {
        try prepareLocalSocket(fd)
        let state = LockedState(State(fd: fd))
        self.state = state; self.validate = validate; self.invalidate = invalidate
        self.failureSnapshot = failureSnapshot
        let reads = AsyncStream<Void>.makeStream(), writes = AsyncStream<Void>.makeStream()
        let stopped = AsyncStream<Void>.makeStream(); stopReturned = stopped.continuation
        let deliveries = AsyncStream<Void>.makeStream(); deliveryReturned = deliveries.continuation
        let finishing = AsyncStream<Result<Void, LocalServiceError>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        finishReturned = finishing.continuation
        // One pre-created result observer; the original serialized writer is
        // the sole producer of the actual drain/SHUT_WR outcome.
        let finishCompletion = Task<Result<Void, LocalServiceError>, Never>.detached {
            for await outcome in finishing.stream { return outcome }
            return .failure(.disconnected)
        }
        self.finishCompletion = finishCompletion
        // Created before either pump. This owner is never replaced/cancelled by
        // any observer. Closing the actual FD follows BOTH original loop returns.
        cleanup = Task.detached {
            for await _ in reads.stream {}
            for await _ in writes.stream {}
            _ = await finishCompletion.value
            for await _ in stopped.stream {}
            for await _ in deliveries.stream {}
            let drainFailure = await drain()
            let closeResult = Darwin.close(fd)
            let closeFailure: LocalServiceError? = closeResult == 0 ? nil : .systemCall(errno)
            state.withLock { value in value.raw.removeAll(); value.decoded = nil; value.writes.removeAll(); value.queuedBytes = 0 }
            retired()
            return LocalServiceIOCompletion(state.withLock { $0.failure } ?? drainFailure ?? closeFailure)
        }
        DispatchQueue(label: "NookLocalServiceKit.read").async { [self] in
            defer { reads.continuation.finish() }
            readLoop()
        }
        DispatchQueue(label: "NookLocalServiceKit.write").async { [self] in
            defer { writes.continuation.finish() }
            writeLoop()
        }
    }

    func receive() async throws -> LocalSocketDelivery {
        try Task.checkCancellation()
        let id = UUID()
        try state.withLock { value in
            guard value.receive == nil, value.delivery == nil else { throw LocalServiceError.concurrentReceive }
            value.receive = Receive(id: id)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var result: Result<LocalSocketDelivery, Error>?
                state.withLock { value in
                    guard var pending = value.receive, pending.id == id else {
                        result = .failure(LocalServiceError.disconnected); return
                    }
                    if pending.cancelled { value.receive = nil; result = .failure(CancellationError()) }
                    else if value.eof { value.receive = nil; result = .success(LocalSocketDelivery(nil)) }
                    else if value.stopped { value.receive = nil; result = .failure(value.failure ?? .disconnected) }
                    else if let frame = value.decoded {
                        value.decoded = nil; value.receive = nil; value.delivery = id
                        result = .success(LocalSocketDelivery(frame, release: { self.releaseDelivery(id) }))
                    } else { pending.continuation = continuation; value.receive = pending }
                }
                if let result { continuation.resume(with: result); readWake.signal() }
            }
        } onCancel: { self.cancelReceive(id) }
    }
    private func cancelReceive(_ id: UUID) {
        let continuation = state.withLock { value -> CheckedContinuation<LocalSocketDelivery, Error>? in
            guard var pending = value.receive, pending.id == id else { return nil }
            if let continuation = pending.continuation { value.receive = nil; return continuation }
            pending.cancelled = true; value.receive = pending; return nil
        }
        continuation?.resume(throwing: CancellationError())
    }

    func send(_ envelope: PluginSharedApplicationEnvelope, observerID id: UUID = UUID()) async throws {
        try Task.checkCancellation()
        let bytes: Data
        do { bytes = try PluginSharedApplicationCodec.encode(envelope) }
        catch { throw LocalServiceError.protocolViolation }
        try state.withLock { value in
            guard !value.stopped, !value.eof, !value.finishRequested else { throw value.failure ?? .disconnected }
            guard !value.writes.contains(where: { $0.id == id }) else { throw LocalServiceError.protocolViolation }
            guard bytes.count <= PluginSharedApplicationLimits.maximumQueuedBytes - value.queuedBytes else {
                throw LocalServiceError.capacity
            }
            value.queuedBytes += bytes.count; value.writes.append(Write(id: id, bytes: bytes))
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var result: Result<Void, Error>?
                state.withLock { value in
                    guard let index = value.writes.firstIndex(where: { $0.id == id }) else {
                        result = .failure(value.failure ?? .disconnected); return
                    }
                    value.writes[index].installed = true
                    if value.writes[index].cancelled { result = .failure(CancellationError()) }
                    else if value.stopped { result = .failure(value.failure ?? .disconnected) }
                    else { value.writes[index].continuation = continuation }
                }
                if let result { continuation.resume(with: result) }
                writeWake.signal()
            }
        } onCancel: { self.cancelSend(id) }
    }
    private func cancelSend(_ id: UUID) {
        let continuation = state.withLock { value -> CheckedContinuation<Void, Error>? in
            guard let index = value.writes.firstIndex(where: { $0.id == id }) else { return nil }
            value.writes[index].cancelled = true
            let continuation = value.writes[index].continuation
            value.writes[index].continuation = nil; return continuation
        }
        // Only the observer is cancelled. Admitted bytes and FIFO remain owned.
        continuation?.resume(throwing: CancellationError())
        writeWake.signal()
    }

    func finishSending() async throws {
        try Task.checkCancellation()
        try state.withLock { value in
            if !value.finishRequested {
                guard !value.stopped, !value.eof else { throw value.failure ?? .disconnected }
                // Same admission lock as send, before the first suspension.
                value.finishRequested = true
            }
        }
        writeWake.signal()
        let original = await finishCompletion.value
        // Cancelling this observer never cancels or replaces the original
        // writer/drain. Its terminal result remains available to other callers.
        try Task.checkCancellation()
        try original.get()
    }
    func stop(_ failure: LocalServiceError? = nil, eof: Bool = false) {
        var receiver: CheckedContinuation<LocalSocketDelivery, Error>?
        var senders: [CheckedContinuation<Void, Error>] = []
        var deliveryDone = false
        let shutdownFD = state.withLock { value -> Int32? in
            guard !value.stopped else { return nil }
            if value.failure == nil { value.failure = failure }
            value.stopped = true; deliveryDone = value.delivery == nil
            value.explicitAbort = failure == nil && !eof
            receiver = value.receive?.continuation
            if receiver != nil { value.receive = nil }
            for index in value.writes.indices {
                if let continuation = value.writes[index].continuation { senders.append(continuation) }
                value.writes[index].continuation = nil
            }
            return value.fd
        }
        guard let shutdownFD else { return }
        // Cleanup also joins this exact native call before closing/reusing fd.
        defer { stopReturned.finish() }
        if deliveryDone { deliveryReturned.finish() }
        invalidate()
        _ = shutdown(shutdownFD, SHUT_RDWR)
        receiver?.resume(throwing: failure ?? .disconnected)
        for sender in senders { sender.resume(throwing: failure ?? .disconnected) }
        readWake.signal(); writeWake.signal()
    }
    private func releaseDelivery(_ id: UUID) {
        let ended = state.withLock { value -> Bool in
            guard value.delivery == id else { return false }
            value.delivery = nil; return value.stopped
        }
        if ended { deliveryReturned.finish() }
        readWake.signal()
    }
    var outboundSealed: Bool { state.withLock { $0.finishRequested } }
    var pendingReceive: Bool { state.withLock { $0.receive != nil } }
    var bufferedByteCount: Int { state.withLock { $0.raw.count } }
    var queuedByteCount: Int { state.withLock { $0.queuedBytes } }
    func containsQueuedWrite(_ id: UUID) -> Bool { state.withLock { $0.writes.contains { $0.id == id } } }
    var cleanEOF: Bool { state.withLock { $0.eof && $0.failure == nil } }
    func retirement() async -> LocalServiceIOCompletion { await cleanup.value }

    private func readLoop() {
        while true {
            let status = state.withLock { ($0.stopped, $0.decoded != nil || $0.delivery != nil, $0.fd) }
            if status.0 { return }
            if status.1 { readWake.wait(); continue }
            // Bounded raw reads/actual zero-byte EOF carry no native authority.
            // Every positive frame still requires strict proof below.
            // Decode exactly ONE LF-terminated line. Additional complete lines
            // remain raw, not decoded-array backlog (Lines.append emits arrays).
            let line: Data? = state.withLock { value in
                guard let end = value.raw.firstIndex(of: 10) else { return nil }
                let result = Data(value.raw[...end]); value.raw.removeSubrange(...end); return result
            }
            if let line {
                let frame: PluginSharedApplicationEnvelope
                do {
                    try validate()
                    frame = try PluginSharedApplicationCodec.decodeLine(line)
                    try validate()
                }
                catch { stop(failureSnapshot() ?? nativeError(error)); return }
                var observer: CheckedContinuation<LocalSocketDelivery, Error>?
                var deliveryID: UUID?
                state.withLock { value in
                    guard !value.stopped else { return }
                    if let pending = value.receive, !pending.cancelled, let continuation = pending.continuation {
                        observer = continuation; value.receive = nil; value.delivery = pending.id; deliveryID = pending.id
                    } else { value.decoded = frame }
                }
                if let observer, let deliveryID {
                    observer.resume(returning: LocalSocketDelivery(frame, release: { self.releaseDelivery(deliveryID) }))
                }
                continue
            }
            let amount = state.withLock { $0.raw.count }
            if amount > PluginSharedApplicationLimits.maximumJSONBytes { stop(.protocolViolation); return }
            var event = pollfd(fd: status.2, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; stop(.systemCall(errno)); return }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: PluginSharedApplicationLimits.maximumReadChunkBytes)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(status.2, $0.baseAddress!, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                stop(.systemCall(errno)); return
            }
            if count == 0 {
                var observer: CheckedContinuation<LocalSocketDelivery, Error>?
                let clean = state.withLock { value in
                    guard !value.stopped else { return true }
                    guard value.raw.isEmpty else { return false }
                    value.eof = true
                    if let continuation = value.receive?.continuation { observer = continuation; value.receive = nil }
                    return true
                }
                if !clean { stop(.protocolViolation) }
                else { observer?.resume(returning: LocalSocketDelivery(nil)); stop(eof: true) }
                return
            }
            let accepted = state.withLock { value -> Bool in
                guard !value.stopped else { return true }
                guard count <= PluginSharedApplicationLimits.maximumBufferedBytes - value.raw.count else { return false }
                value.raw.append(contentsOf: bytes.prefix(count)); return true
            }
            if !accepted { stop(.protocolViolation); return }
        }
    }
    private func completeFinish(_ result: Result<Void, LocalServiceError>) {
        let publish = state.withLock { value -> Bool in
            guard value.finishResult == nil else { return false }
            value.finishResult = result; return true
        }
        if publish { finishReturned.yield(result); finishReturned.finish() }
    }
    private func writeLoop() {
        defer {
            let nativeFailure = failureSnapshot()
            let failure = state.withLock { $0.failure ?? nativeFailure ?? .disconnected }
            completeFinish(.failure(failure))
        }
        while true {
            let item = state.withLock { value -> (Int32, Write)? in
                guard !value.stopped, let first = value.writes.first, first.installed else { return nil }
                return (value.fd, first)
            }
            guard let (fd, job) = item else {
                if state.withLock({ $0.stopped }) { return }
                let shouldFinish = state.withLock { $0.finishRequested && $0.writes.isEmpty }
                if shouldFinish {
                    do { try validate() } catch { stop(failureSnapshot() ?? nativeError(error)); return }
                    let originalFD: Int32? = state.withLock { value in
                        guard !value.stopped, value.finishRequested, value.writes.isEmpty,
                              !value.finishNativeStarted else { return nil }
                        value.finishNativeStarted = true; return value.fd
                    }
                    guard let originalFD else { continue }
                    // The original write loop owns this native call. Cleanup
                    // cannot close/reuse its FD before the loop has returned.
                    let status = shutdown(originalFD, SHUT_WR)
                    let syscallFailure: LocalServiceError? = status == 0 ? nil : .systemCall(errno)
                    // Receipt decision point: observe only an already recorded
                    // native fault, not a fresh post-FIN permission. A later
                    // fault stays in retirement, not retroactive receipt edits.
                    let nativeFailure = failureSnapshot()
                    let result: Result<Void, LocalServiceError> = state.withLock { value in
                        if let failure = value.failure { return .failure(failure) }
                        if let nativeFailure { value.failure = nativeFailure; return .failure(nativeFailure) }
                        if value.explicitAbort { return .failure(.disconnected) }
                        if let syscallFailure { value.failure = syscallFailure; return .failure(syscallFailure) }
                        // Clean peer EOF after this call started joins its real
                        // return; it does not fabricate an abort/fresh grant.
                        return .success(())
                    }
                    completeFinish(result)
                    if case .failure(let failure) = result { stop(failure) }
                    return
                }
                writeWake.wait(); continue
            }
            do { try validate() } catch { stop(failureSnapshot() ?? nativeError(error)); return }
            let written = job.bytes.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: job.offset), $0.count - job.offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    if poll(&event, 1, 100) < 0, errno != EINTR { stop(.systemCall(errno)); return }
                    continue
                }
                stop(.systemCall(errno)); return
            }
            if written == 0 { stop(.disconnected); return }
            do { try validate() } catch { stop(failureSnapshot() ?? nativeError(error)); return }
            let observer = state.withLock { value -> CheckedContinuation<Void, Error>? in
                guard !value.stopped, !value.writes.isEmpty, value.writes[0].id == job.id else { return nil }
                value.writes[0].offset += written
                guard value.writes[0].offset == value.writes[0].bytes.count else { return nil }
                let first = value.writes.removeFirst(); value.queuedBytes -= first.bytes.count
                return first.continuation
            }
            observer?.resume()
        }
    }
}

#endif

public final class LocalServiceConnection: Sendable {
    public let ownPolicyKey: String
    public let peer: LocalServicePeer
    #if os(macOS)
    private let proof: NativePeerProof
    private let io: LocalSocketIO
    init(fd: Int32, own: NativeSelfIdentity, policy: LocalServicePolicy,
         owner: LocalServiceOwner? = nil, released: @escaping @Sendable () -> Void = {}) throws {
        try prepareLocalSocket(fd)
        let proof = try NativePeerProof(fd: fd, own: own, policy: policy, owner: owner)
        self.proof = proof; ownPolicyKey = own.policyKey; peer = LocalServicePeer(proof: proof)
        do {
            io = try LocalSocketIO(fd: fd, validate: { try proof.revalidate() }, invalidate: { proof.invalidate() }, drain: {
                return await proof.drain()
            }, failureSnapshot: { proof.recordedFailure() }, retired: { proof.releaseOwner(); released() })
        } catch { proof.invalidate(); throw error }
    }
    #else
    private init() throws { throw LocalServiceError.unsupportedPlatform }
    #endif
    public static func connect(policy: LocalServicePolicy) async throws -> LocalServiceConnection {
        #if os(macOS)
        // Cancellation does not detach the original connect/auth syscall work.
        let original = Task.detached { () throws -> LocalServiceConnection in
            let own = try NativeSelfIdentity(policy: policy)
            let root = try ServiceRoot(service: policy.serviceIdentifier, create: false)
            guard let socketNode = try root.namedSocket() else { throw LocalServiceError.disconnected }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw LocalServiceError.systemCall(errno) }
            var transferred = false
            defer { if !transferred { _ = Darwin.close(fd) } }
            try prepareLocalSocket(fd)
            var address = try unixAddress(root.socketPath)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw LocalServiceError.systemCall(errno) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(PluginSharedApplicationLimits.connectSeconds))
                while true {
                    guard ContinuousClock.now < deadline else { throw LocalServiceError.disconnected }
                    var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let ready = poll(&event, 1, 100)
                    if ready < 0 { if errno == EINTR { continue }; throw LocalServiceError.systemCall(errno) }
                    if ready == 0 { continue }
                    var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
                    guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { throw LocalServiceError.systemCall(errno) }
                    guard error == 0 else { throw LocalServiceError.systemCall(error) }
                    break
                }
            }
            guard try root.namedSocket() == socketNode else { throw LocalServiceError.unsafeRoot }
            try own.revalidate()
            let connection = try LocalServiceConnection(fd: fd, own: own, policy: policy)
            transferred = true; return connection
        }
        let connection = try await original.value
        if Task.isCancelled { connection.stopIO(); _ = await connection.retirement(); throw CancellationError() }
        do { try connection.revalidate(); return connection }
        catch { connection.stopIO(); _ = await connection.retirement(); throw error }
        #else
        throw LocalServiceError.unsupportedPlatform
        #endif
    }
    public func revalidate() throws {
        #if os(macOS)
        do { try proof.revalidate() }
        catch { io.stop(proof.recordedFailure() ?? nativeError(error)); throw error }
        #else
        throw LocalServiceError.unsupportedPlatform
        #endif
    }
    public func receive() async throws -> PluginSharedApplicationEnvelope? {
        #if os(macOS)
        if io.cleanEOF { return nil }
        // Registering an observer/receiving real EOF is not positive authority.
        // The original pump and this post-await fence strictly check all data.
        let delivery = try await io.receive()
        defer { delivery.release() }
        if delivery.envelope != nil { try revalidate() }
        return delivery.envelope
        #else
        throw LocalServiceError.unsupportedPlatform
        #endif
    }
    public func send(_ envelope: PluginSharedApplicationEnvelope) async throws {
        #if os(macOS)
        if io.outboundSealed { throw LocalServiceError.disconnected }
        try revalidate(); try await io.send(envelope); try revalidate()
        #else
        throw LocalServiceError.unsupportedPlatform
        #endif
    }
    public func finishSending() async throws {
        #if os(macOS)
        try await io.finishSending()
        #else
        throw LocalServiceError.unsupportedPlatform
        #endif
    }
    public func stopIO() {
        #if os(macOS)
        io.stop()
        #endif
    }
    public func retirement() async -> LocalServiceIOCompletion {
        #if os(macOS)
        return await io.retirement()
        #else
        return LocalServiceIOCompletion(.unsupportedPlatform)
        #endif
    }
    deinit {
        #if os(macOS)
        io.stop()
        #endif
    }
}

#if os(macOS)
private final class LocalListenerIO: Sendable {
    private struct Accept {
        let id: UUID
        var continuation: CheckedContinuation<LocalServiceConnection?, Error>?
        var cancelled = false
    }
    private struct State {
        let fd: Int32
        var stopped = false
        var failure: LocalServiceError?
        var observer: Accept?
        var buffered: LocalServiceConnection?
        var leases = 0
    }
    private let state: LockedState<State>
    private let wake = DispatchSemaphore(value: 0)
    private let cleanup: Task<LocalServiceIOCompletion, Never>
    private let stopReturned: AsyncStream<Void>.Continuation
    init(owner: LocalServiceOwner, policy: LocalServicePolicy) throws {
        try owner.revalidate()
        guard owner.policy.serviceIdentifier == policy.serviceIdentifier,
              owner.policy.trustedSelfRequirements == policy.trustedSelfRequirements,
              owner.policy.trustedPeerRequirements == policy.trustedPeerRequirements else {
            throw LocalServiceError.invalidPolicy
        }
        let root = owner.lock.root
        // Unknown preexisting sockets are never automatically stolen or adopted.
        guard try root.namedSocket() == nil else { throw LocalServiceError.unsafeRoot }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalServiceError.systemCall(errno) }
        var transferred = false
        var published: LocalNode?
        defer {
            if !transferred {
                _ = Darwin.close(fd)
                if let published { try? root.removeSocket(published) }
            }
        }
        try prepareLocalSocket(fd)
        var address = try unixAddress(root.socketPath)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw LocalServiceError.systemCall(errno) }
        // Only this just-bound node is eligible for mode setting and cleanup.
        var boundNode = stat()
        guard fstatat(root.directoryFD, root.digest + ".sock", &boundNode, AT_SYMLINK_NOFOLLOW) == 0,
              boundNode.st_mode & S_IFMT == S_IFSOCK, boundNode.st_uid == geteuid() else {
            throw LocalServiceError.unsafeRoot
        }
        guard fchmodat(root.directoryFD, root.digest + ".sock", 0o600, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw LocalServiceError.systemCall(errno)
        }
        guard let node = try root.namedSocket(), node.device == boundNode.st_dev, node.inode == boundNode.st_ino else {
            throw LocalServiceError.unsafeRoot
        }
        published = node
        guard listen(fd, Int32(PluginSharedApplicationLimits.maximumConnections)) == 0 else {
            throw LocalServiceError.systemCall(errno)
        }
        try owner.revalidate()
        let state = LockedState(State(fd: fd)); self.state = state
        let ended = AsyncStream<Void>.makeStream()
        let stopped = AsyncStream<Void>.makeStream(); stopReturned = stopped.continuation
        cleanup = Task.detached {
            for await _ in ended.stream {}
            for await _ in stopped.stream {}
            let closed = Darwin.close(fd)
            var failure = state.withLock { $0.failure }
            if closed != 0, failure == nil { failure = .systemCall(errno) }
            do { try root.removeSocket(node) } catch { if failure == nil { failure = nativeError(error) } }
            _ = owner // Retained through original listener cleanup.
            return LocalServiceIOCompletion(failure)
        }
        transferred = true
        DispatchQueue(label: "NookLocalServiceKit.accept").async { [self] in
            defer { ended.continuation.finish() }
            acceptLoop(owner: owner, policy: policy)
        }
    }
    func accept() async throws -> LocalServiceConnection? {
        try Task.checkCancellation()
        let id = UUID()
        try state.withLock { value in
            guard value.observer == nil else { throw LocalServiceError.concurrentAccept }
            value.observer = Accept(id: id)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var result: Result<LocalServiceConnection?, Error>?
                state.withLock { value in
                    guard var pending = value.observer, pending.id == id else { result = .failure(LocalServiceError.disconnected); return }
                    if pending.cancelled { value.observer = nil; result = .failure(CancellationError()) }
                    else if value.stopped {
                        value.observer = nil
                        result = value.failure.map { .failure($0) } ?? .success(nil)
                    } else if let buffered = value.buffered {
                        value.buffered = nil; value.observer = nil; result = .success(buffered)
                    } else { pending.continuation = continuation; value.observer = pending }
                }
                if let result { continuation.resume(with: result); wake.signal() }
            }
        } onCancel: { self.cancelAccept(id) }
    }
    private func cancelAccept(_ id: UUID) {
        let observer = state.withLock { value -> CheckedContinuation<LocalServiceConnection?, Error>? in
            guard var pending = value.observer, pending.id == id else { return nil }
            if let continuation = pending.continuation { value.observer = nil; return continuation }
            pending.cancelled = true; value.observer = pending; return nil
        }
        observer?.resume(throwing: CancellationError())
    }
    func stop(_ failure: LocalServiceError? = nil) {
        var observer: CheckedContinuation<LocalServiceConnection?, Error>?
        var buffered: LocalServiceConnection?
        let fd = state.withLock { value -> Int32? in
            guard !value.stopped else { return nil }
            if value.failure == nil { value.failure = failure }
            value.stopped = true; observer = value.observer?.continuation
            if observer != nil { value.observer = nil }
            buffered = value.buffered; return value.fd
        }
        guard let fd else { return }
        defer { stopReturned.finish() }
        _ = shutdown(fd, SHUT_RDWR)
        buffered?.stopIO()
        if let observer {
            if let failure { observer.resume(throwing: failure) } else { observer.resume(returning: nil) }
        }
        wake.signal()
    }
    var pendingAccept: Bool { state.withLock { $0.observer != nil } }
    func retirement() async -> LocalServiceIOCompletion { await cleanup.value }
    private func waitForRetirement(_ connection: LocalServiceConnection) {
        // This runs only on the dedicated accept queue, never a Swift executor.
        let ended = DispatchSemaphore(value: 0)
        Task.detached { _ = await connection.retirement(); ended.signal() }
        ended.wait()
    }
    private func acceptLoop(owner: LocalServiceOwner, policy: LocalServicePolicy) {
        while true {
            let status = state.withLock { ($0.stopped, $0.buffered != nil || $0.leases >= PluginSharedApplicationLimits.maximumConnections, $0.fd) }
            if status.0 {
                let buffered = state.withLock { value -> LocalServiceConnection? in
                    let buffered = value.buffered; value.buffered = nil; return buffered
                }
                if let buffered { buffered.stopIO(); waitForRetirement(buffered) }
                return
            }
            if status.1 { wake.wait(); continue }
            do { try owner.revalidate() } catch { stop(nativeError(error)); continue }
            var event = pollfd(fd: status.2, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; stop(.systemCall(errno)); continue }
            if ready == 0 { continue }
            let fd = Darwin.accept(status.2, nil, nil)
            if fd < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                if state.withLock({ $0.stopped }) { continue }
                stop(.systemCall(errno)); continue
            }
            let admitted = state.withLock { value -> Bool in
                guard !value.stopped, value.leases < PluginSharedApplicationLimits.maximumConnections else { return false }
                value.leases += 1; return true
            }
            if !admitted { _ = Darwin.close(fd); continue }
            let state = self.state, wake = self.wake
            let released: @Sendable () -> Void = {
                state.withLock { $0.leases -= 1 }; wake.signal()
            }
            let connection: LocalServiceConnection
            do {
                try owner.revalidate()
                connection = try LocalServiceConnection(fd: fd, own: owner.own, policy: policy, owner: owner, released: released)
            } catch {
                _ = Darwin.close(fd); released()
                // A refused candidate does not retire the valid listener or
                // present a principal; one original auth call has returned.
                continue
            }
            var observer: CheckedContinuation<LocalServiceConnection?, Error>?
            let discard = state.withLock { value -> Bool in
                guard !value.stopped else { return true }
                if let pending = value.observer, !pending.cancelled, let continuation = pending.continuation {
                    observer = continuation; value.observer = nil
                } else { value.buffered = connection }
                return false
            }
            if discard { connection.stopIO(); waitForRetirement(connection) }
            else { observer?.resume(returning: connection) }
        }
    }
}
#endif

public final class LocalServiceListener: Sendable {
    #if os(macOS)
    private let io: LocalListenerIO
    #endif
    public init(owner: LocalServiceOwner, policy: LocalServicePolicy) throws {
        #if os(macOS)
        io = try LocalListenerIO(owner: owner, policy: policy)
        #else
        throw LocalServiceError.unsupportedPlatform
        #endif
    }
    public func accept() async throws -> LocalServiceConnection? {
        #if os(macOS)
        guard let connection = try await io.accept() else { return nil }
        do { try connection.revalidate(); return connection }
        catch { connection.stopIO(); _ = await connection.retirement(); throw error }
        #else
        throw LocalServiceError.unsupportedPlatform
        #endif
    }
    #if os(macOS)
    var pendingAccept: Bool { io.pendingAccept }
    #endif
    public func stopAccepting() {
        #if os(macOS)
        io.stop()
        #endif
    }
    public func retirement() async -> LocalServiceIOCompletion {
        #if os(macOS)
        return await io.retirement()
        #else
        return LocalServiceIOCompletion(.unsupportedPlatform)
        #endif
    }
    deinit {
        #if os(macOS)
        io.stop()
        #endif
    }
}
