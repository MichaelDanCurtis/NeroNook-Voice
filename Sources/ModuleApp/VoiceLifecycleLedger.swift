import Foundation
import Darwin
import NookPluginSDK
import NookLocalServiceKit

/// Metadata, not authentication. Live authority remains the retained native owner.
struct VoiceLifecycleBinding: Sendable {
    let serviceIdentifier: String
    let buildIdentifier: String
    let bootSessionUUID: UUID
    let ownPolicyKey: String
}

enum VoiceLifecycleFailure: Error, Equatable {
    case invalidBinding, unsafeRoot, unsafeRecord, missingRecord
    case recoveryRequired, busy, staleWitness, io(Int32)
}

/// One durable active epoch covers all work in the separately owned runtime.
/// Ordinary begin never enrolls, resets or performs PID-based recovery. First
/// ACTIVE publication requires a separate original-creation capability.
actor VoiceLifecycleLedger {
    private enum Phase { case unopened, writing, active(UUID), finished, failed }
    private let storage: VoiceLifecycleStorage
    private let binding: VoiceLifecycleBinding
    private var phase: Phase = .unopened
    private var activeBytes: Data?
    private var originalWrite: Task<Result<Void, Error>, Never>?
    private var writeCompletion: Task<Void, Never>?
    // Retains the exact native owner and original created directory descriptors.
    private var isolatedProvision: (any VoiceLifecycleGenesisProvision)?
    private let nativeOwner: LocalServiceOwner

    init(root: URL, owner: LocalServiceOwner, binding: VoiceLifecycleBinding) throws {
        guard binding.ownPolicyKey == owner.ownPolicyKey,
              !binding.serviceIdentifier.isEmpty, binding.serviceIdentifier.utf8.count <= 100,
              !binding.buildIdentifier.isEmpty, binding.buildIdentifier.utf8.count <= 160,
              !binding.buildIdentifier.utf8.contains(0),
              !binding.ownPolicyKey.isEmpty, binding.ownPolicyKey.utf8.count <= 64 else {
            throw VoiceLifecycleFailure.invalidBinding
        }
        self.binding = binding; self.nativeOwner = owner
        storage = try VoiceLifecycleStorage(root: root, owner: owner)
    }

    func begin() async throws -> UUID {
        guard case .unopened = phase else { throw VoiceLifecycleFailure.busy }
        try Task.checkCancellation()
        let epoch = UUID()
        let next = try VoiceLifecycleRecord(binding: binding, epoch: epoch, state: "active").encoded()
        phase = .writing
        let storage = storage, binding = binding
        do {
            try await perform {
                let prior = try storage.read()
                let record = try VoiceLifecycleRecord.decode(prior.bytes)
                guard record.state == "clean", record.serviceIdentifier == binding.serviceIdentifier,
                      record.ownPolicyKey == binding.ownPolicyKey else {
                    throw VoiceLifecycleFailure.recoveryRequired
                }
                try storage.replace(prior: prior, with: next)
            }
            // A cancelled startup cannot hand an epoch to an eager factory. The
            // durable active record stays closed for a separately reviewed recovery.
            try Task.checkCancellation()
            activeBytes = next
            phase = .active(epoch)
            return epoch
        } catch { phase = .failed; throw error }
    }

    // A distinct entry, never a fallback from begin(): its capability comes
    // only from this process's original exclusive directory creation.
    func beginIsolatedGenesis(_ provision: VoiceIsolatedProvision,
                              checkpoint: (@Sendable () -> Void)? = nil) async throws -> UUID {
        try await beginGenesis(provision, checkpoint: checkpoint)
    }

    func beginNormalGenesis(_ provision: VoiceNormalEnrollment,
                            checkpoint: (@Sendable () -> Void)? = nil) async throws -> UUID {
        try await beginGenesis(provision, checkpoint: checkpoint)
    }

    private func beginGenesis(_ provision: any VoiceLifecycleGenesisProvision,
                              checkpoint: (@Sendable () -> Void)?) async throws -> UUID {
        guard case .unopened = phase else { throw VoiceLifecycleFailure.busy }
        try Task.checkCancellation()
        try provision.consume(owner: nativeOwner, binding: binding)
        isolatedProvision = provision
        let epoch = UUID()
        phase = .writing
        let storage = storage
        do {
            let next = try VoiceLifecycleRecord(binding: binding, epoch: epoch, state: "active").encoded()
            try await performGenesis {
                try provision.matches(rootFD: storage.retainedRootFD)
                try storage.createFirst(with: next, provision: provision, checkpoint: checkpoint)
            }
            try Task.checkCancellation()
            try provision.revalidate()
            activeBytes = next; phase = .active(epoch)
            return epoch
        } catch {
            let originalError = error
            phase = .failed
            do { try provision.closeAfterConsumption() }
            catch let cleanup as VoiceProvisionCleanupFailure {
                throw VoiceProvisionCleanupFailure(original:originalError,closeErrors:cleanup.closeErrors)
            }
            catch let cleanup as VoiceLifecycleFailure {
                if case .io(let code) = cleanup { throw VoiceProvisionCleanupFailure(original: originalError, closeErrors: [code]) }
                throw cleanup
            }
            throw originalError
        }
    }

    func commitClean(_ witness: VoiceResourceCleanWitness) async throws {
        guard case .active(let epoch) = phase,
              epoch == witness.epochID, let expected = activeBytes,
              VoiceLifecycleRecord.validFamilies(witness.releasedFamilies) else {
            throw VoiceLifecycleFailure.staleWitness
        }
        // The original genesis descriptors have their own actual close result.
        // Keep the ledger storage's independently opened root/owner through the
        // following durable commit; a failed capability close forbids clean.
        if let isolatedProvision {
            do { try isolatedProvision.revalidate(); try isolatedProvision.closeAfterConsumption() }
            catch { phase = .failed; throw error }
            self.isolatedProvision = nil
        }
        let bytes = try VoiceLifecycleRecord(binding: binding, epoch: epoch, state: "clean",
                                             families: witness.releasedFamilies).encoded()
        phase = .writing
        let storage = storage
        do {
            try await perform {
                let prior = try storage.read()
                guard prior.bytes == expected else { throw VoiceLifecycleFailure.unsafeRecord }
                try storage.replace(prior: prior, with: bytes)
            }
            activeBytes = nil
            phase = .finished
        } catch { phase = .failed; throw error }
    }

    func markRecoveryRequired(reason: String) async throws {
        guard case .active(let epoch) = phase, let expected = activeBytes else {
            throw VoiceLifecycleFailure.recoveryRequired
        }
        guard VoiceLifecycleRecord.validCode(reason) else { throw VoiceLifecycleFailure.invalidBinding }
        let bytes = try VoiceLifecycleRecord(binding: binding, epoch: epoch,
                                             state: "recoveryRequired", reason: reason).encoded()
        phase = .writing
        let storage = storage
        do {
            try await perform {
                let prior = try storage.read()
                guard prior.bytes == expected else { throw VoiceLifecycleFailure.unsafeRecord }
                try storage.replace(prior: prior, with: bytes)
            }
            activeBytes = nil
            phase = .failed
        } catch { phase = .failed; throw error }
    }

    // Only after bootstrap has cancelled AND joined its original startup task,
    // when no runtime was constructed. This does not write or imply clean; an
    // active or failed durable record is preserved. Close errors are latched.
    func retireStartupHandles() async -> String? {
        await writeCompletion?.value
        if case .writing = phase { return "startup-writer-still-owned" }
        phase = .failed
        var first: String?
        if let isolatedProvision {
            do { try isolatedProvision.closeAfterConsumption() }
            catch { first = "isolated-provision-close: \(error)" }
        }
        do { try storage.closeRoot() }
        catch { if first == nil { first = "lifecycle-root-close: \(error)" } }
        return first
    }

    /// This observer joins the retained original writer; cancellation never
    /// substitutes a timer/idle flag for its actual filesystem return.
    func pendingWriteCompletion() -> Task<Void, Never>? { writeCompletion }

    private func performGenesis(_ operation: @escaping @Sendable () throws -> Void) async throws {
        let original = Task.detached(priority: .userInitiated) { Result { try Task.checkCancellation(); try operation() } }
        originalWrite = original
        writeCompletion = Task { _ = await original.value }
        let result = await withTaskCancellationHandler { await original.value } onCancel: { original.cancel() }
        originalWrite = nil; writeCompletion = nil
        try result.get()
    }

    private func perform(_ operation: @escaping @Sendable () throws -> Void) async throws {
        let original = Task.detached(priority: .userInitiated) { Result { try operation() } }
        originalWrite = original
        writeCompletion = Task { _ = await original.value }
        let result = await original.value
        originalWrite = nil
        writeCompletion = nil
        try result.get()
    }
}

private struct VoiceLifecycleRecord {
    let epochID: UUID
    let serviceIdentifier: String
    let buildIdentifier: String
    let bootSessionUUID: UUID
    let ownPolicyKey: String
    let state: String
    let families: [String]
    let reason: String

    init(binding: VoiceLifecycleBinding, epoch: UUID, state: String,
         families: [String] = [], reason: String = "") {
        epochID = epoch; serviceIdentifier = binding.serviceIdentifier
        buildIdentifier = binding.buildIdentifier; bootSessionUUID = binding.bootSessionUUID
        ownPolicyKey = binding.ownPolicyKey; self.state = state
        self.families = families; self.reason = reason
    }

    static func validCode(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...80).contains(bytes.count) && bytes.first.map { (97...122).contains($0) } == true &&
            bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
    static func validFamilies(_ values: [String]) -> Bool {
        values.count <= 32 && Set(values).count == values.count && values.allSatisfy(validCode)
    }

    func encoded() throws -> Data {
        let object: [String: Any] = ["formatVersion": 1, "epochID": epochID.uuidString,
            "serviceIdentifier": serviceIdentifier, "buildIdentifier": buildIdentifier,
            "bootSessionUUID": bootSessionUUID.uuidString, "ownPolicyKey": ownPolicyKey,
            "state": state, "releasedFamilies": families.sorted(), "reason": reason]
        var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        bytes.append(10)
        _ = try Self.decode(bytes)
        return bytes
    }

    static func decode(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 65_536,
              let node = try? PluginFlowJSON.parse(bytes), let members = node.members,
              Set(members.map(\.name)) == Set(["formatVersion", "epochID", "serviceIdentifier",
                  "buildIdentifier", "bootSessionUUID", "ownPolicyKey", "state", "releasedFamilies", "reason"]),
              node["formatVersion"]?.integer == 1,
              let rawEpoch = node["epochID"]?.string, let epoch = UUID(uuidString: rawEpoch),
              rawEpoch == epoch.uuidString,
              let rawBoot = node["bootSessionUUID"]?.string, let boot = UUID(uuidString: rawBoot),
              rawBoot == boot.uuidString,
              let service = node["serviceIdentifier"]?.string, !service.isEmpty, service.utf8.count <= 100,
              let build = node["buildIdentifier"]?.string, !build.isEmpty, build.utf8.count <= 160,
              !build.utf8.contains(0),
              let key = node["ownPolicyKey"]?.string, !key.isEmpty, key.utf8.count <= 64,
              let state = node["state"]?.string, ["active", "clean", "recoveryRequired"].contains(state),
              let familyNodes = node["releasedFamilies"]?.array,
              let reason = node["reason"]?.string else { throw VoiceLifecycleFailure.unsafeRecord }
        let families = familyNodes.compactMap(\.string)
        guard families.count == familyNodes.count, validFamilies(families),
              (state == "clean" || families.isEmpty),
              (state == "recoveryRequired" ? validCode(reason) : reason.isEmpty) else {
            throw VoiceLifecycleFailure.unsafeRecord
        }
        return Self(binding: .init(serviceIdentifier: service, buildIdentifier: build,
                                  bootSessionUUID: boot, ownPolicyKey: key),
                    epoch: epoch, state: state, families: families, reason: reason)
    }
}

private struct VoiceLifecycleNode: Equatable, Sendable {
    let device: dev_t, inode: ino_t, uid: uid_t, mode: mode_t, links: nlink_t
    let birthSeconds: Int, birthNanos: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; uid = value.st_uid
        // Child-directory creation changes a directory's link count, not its
        // identity. Regular record/temp files still retain exact nlink == 1.
        mode = value.st_mode; links = value.st_mode & S_IFMT == S_IFDIR ? 0 : value.st_nlink
        birthSeconds = value.st_birthtimespec.tv_sec; birthNanos = value.st_birthtimespec.tv_nsec
    }
}

private enum VoiceLifecyclePhysicalPath {
    static func isExact(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasSuffix("/"),
              path.utf8.count < Int(PATH_MAX), !path.utf8.contains(0) else { return false }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let actual = realpath(path, nil) else { return false }
        defer { free(actual) }
        // Foundation's standardized/resolved URL deliberately rewrites the
        // physical /private/tmp spelling to /tmp on macOS; it is not realpath.
        return String(cString: actual).utf8.elementsEqual(path.utf8)
    }
}

/// Initialization validates/opens the root synchronously before eager runtime
/// construction; bootstrap must keep that native startup work off MainActor.
/// Subsequent jobs run in the original detached writer and retain this root FD
/// and native owner through their actual return.
private final class VoiceLifecycleStorage: @unchecked Sendable {
    struct Snapshot: Sendable { let bytes: Data; let node: VoiceLifecycleNode }
    private let root: URL
    private let rootFD: Int32
    // The root descriptor is closed only after the actor joins its original
    // writer; this lock prevents a second close or numeric-FD retry.
    private let closeLock = NSLock()
    private var rootClosed = false
    private var rootCloseError: Int32?
    var retainedRootFD: Int32 { rootFD }
    private let rootNode: VoiceLifecycleNode
    private let owner: LocalServiceOwner
    private let name = "lifecycle-v1.json"

    init(root: URL, owner: LocalServiceOwner) throws {
        try owner.revalidate()
        guard root.isFileURL, VoiceLifecyclePhysicalPath.isExact(root.path) else {
            throw VoiceLifecycleFailure.unsafeRoot
        }
        var before = stat()
        guard lstat(root.path, &before) == 0, before.st_mode & S_IFMT == S_IFDIR,
              before.st_mode & 0o7777 == 0o700, before.st_uid == geteuid() else {
            throw VoiceLifecycleFailure.unsafeRoot
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VoiceLifecycleFailure.io(errno) }
        var held = stat()
        guard fstat(fd, &held) == 0, VoiceLifecycleNode(before) == VoiceLifecycleNode(held) else {
            let original = VoiceLifecycleFailure.unsafeRoot
            if Darwin.close(fd) != 0 { throw VoiceProvisionCleanupFailure(original: original, closeErrors: [errno]) }
            throw original
        }
        do {
            try owner.revalidate()
            var named = stat()
            guard VoiceLifecyclePhysicalPath.isExact(root.path),
                  lstat(root.path, &named) == 0, VoiceLifecycleNode(named) == VoiceLifecycleNode(held) else {
                throw VoiceLifecycleFailure.unsafeRoot
            }
        } catch {
            let original = error
            if Darwin.close(fd) != 0 { throw VoiceProvisionCleanupFailure(original: original, closeErrors: [errno]) }
            throw original
        }
        self.root = root; rootFD = fd; rootNode = VoiceLifecycleNode(held); self.owner = owner
    }
    func closeRoot() throws {
        closeLock.lock()
        if rootClosed {
            let saved = rootCloseError; closeLock.unlock()
            if let saved { throw VoiceLifecycleFailure.io(saved) }
            return
        }
        rootClosed = true
        if Darwin.close(rootFD) != 0 { rootCloseError = errno }
        let saved = rootCloseError; closeLock.unlock()
        if let saved { throw VoiceLifecycleFailure.io(saved) }
    }
    deinit { try? closeRoot() }

    private func validateRoot() throws {
        try owner.revalidate()
        var held = stat(), named = stat()
        guard VoiceLifecyclePhysicalPath.isExact(root.path),
              fstat(rootFD, &held) == 0, lstat(root.path, &named) == 0,
              VoiceLifecycleNode(held) == rootNode, VoiceLifecycleNode(named) == rootNode else {
            throw VoiceLifecycleFailure.unsafeRoot
        }
    }

    func read() throws -> Snapshot {
        try validateRoot()
        let fd = openat(rootFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw VoiceLifecycleFailure.missingRecord }
            throw VoiceLifecycleFailure.unsafeRecord
        }
        var closed = false
        do {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_mode & 0o7777 == 0o600, before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 65_536 else { throw VoiceLifecycleFailure.unsafeRecord }
        var bytes = Data(count: Int(before.st_size))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pread(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw VoiceLifecycleFailure.unsafeRecord }
                offset += count
            }
        }
        var after = stat(), named = stat()
        guard fstat(fd, &after) == 0, fstatat(rootFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              VoiceLifecycleNode(after) == VoiceLifecycleNode(before),
              VoiceLifecycleNode(named) == VoiceLifecycleNode(before), after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw VoiceLifecycleFailure.unsafeRecord }
        _ = try VoiceLifecycleRecord.decode(bytes)
        try validateRoot()
        let closeResult = close(fd), closeError = errno
        closed = true // Never retry a possibly released/reused numeric descriptor.
        guard closeResult == 0 else { throw VoiceLifecycleFailure.io(closeError) }
        return Snapshot(bytes: bytes, node: VoiceLifecycleNode(after))
        } catch {
            if !closed {
                closed = true
                if Darwin.close(fd) != 0 { throw VoiceProvisionCleanupFailure(original: error, closeErrors: [errno]) }
            }
            throw error
        }
    }

    // Publish the first active record only into an absent destination. Unlike
    // replace(), this never overwrites an existing name, including one raced in
    // after the directory was created.
    func createFirst(with bytes: Data, provision: any VoiceLifecycleGenesisProvision,
                     checkpoint: (@Sendable () -> Void)?) throws {
        try Task.checkCancellation()
        _ = try VoiceLifecycleRecord.decode(bytes)
        try validateRoot(); try provision.matches(rootFD: rootFD)
        let temporary = ".lifecycle-" + UUID().uuidString + ".tmp"
        let fd = openat(rootFD, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw VoiceLifecycleFailure.io(errno) }
        var closed = false
        // On failure retain the original temporary artifact for diagnosis.
        do {
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_mode & 0o7777 == 0o600, initial.st_uid == geteuid(), initial.st_nlink == 1 else {
            throw VoiceLifecycleFailure.unsafeRecord
        }
        let temporaryNode = VoiceLifecycleNode(initial)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw VoiceLifecycleFailure.io(errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw VoiceLifecycleFailure.io(errno) }
        checkpoint?()
        var named = stat(), held = stat()
        guard fstat(fd, &held) == 0, fstatat(rootFD, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
              VoiceLifecycleNode(held) == temporaryNode, VoiceLifecycleNode(named) == temporaryNode,
              held.st_size == bytes.count else { throw VoiceLifecycleFailure.unsafeRecord }
        try Task.checkCancellation()
        try validateRoot(); try provision.matches(rootFD: rootFD)
        let result = close(fd), closeError = errno; closed = true
        guard result == 0 else { throw VoiceLifecycleFailure.io(closeError) }
        guard renameatx_np(rootFD, temporary, rootFD, name, UInt32(RENAME_EXCL)) == 0 else {
            throw VoiceLifecycleFailure.io(errno)
        }
        guard fsync(rootFD) == 0 else { throw VoiceLifecycleFailure.io(errno) }
        let committed = try read()
        guard committed.node == temporaryNode, committed.bytes == bytes else { throw VoiceLifecycleFailure.unsafeRecord }
        try provision.matches(rootFD: rootFD)
        } catch {
            if !closed {
                closed = true
                if close(fd) != 0 { throw VoiceProvisionCleanupFailure(original: error, closeErrors: [errno]) }
            }
            throw error
        }
    }

    func replace(prior: Snapshot, with bytes: Data) throws {
        _ = try VoiceLifecycleRecord.decode(bytes)
        try validateRoot()
        let temporary = ".lifecycle-" + UUID().uuidString + ".tmp"
        let fd = openat(rootFD, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw VoiceLifecycleFailure.io(errno) }
        var initial = stat()
        guard fstat(fd, &initial) == 0 else { close(fd); throw VoiceLifecycleFailure.io(errno) }
        let temporaryNode = VoiceLifecycleNode(initial)
        var renamed = false, closed = false
        defer {
            if !closed { _ = close(fd) }
            if !renamed {
                var named = stat()
                if fstatat(rootFD, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   VoiceLifecycleNode(named) == temporaryNode { _ = unlinkat(rootFD, temporary, 0) }
            }
        }
        guard initial.st_mode & S_IFMT == S_IFREG, initial.st_mode & 0o7777 == 0o600,
              initial.st_uid == geteuid(), initial.st_nlink == 1 else { throw VoiceLifecycleFailure.unsafeRecord }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw VoiceLifecycleFailure.io(errno) }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw VoiceLifecycleFailure.io(errno) }
        let current = try read()
        guard current.node == prior.node, current.bytes == prior.bytes else { throw VoiceLifecycleFailure.unsafeRecord }
        var tempNamed = stat(), tempHeld = stat()
        guard fstat(fd, &tempHeld) == 0, fstatat(rootFD, temporary, &tempNamed, AT_SYMLINK_NOFOLLOW) == 0,
              VoiceLifecycleNode(tempNamed) == temporaryNode, VoiceLifecycleNode(tempHeld) == temporaryNode,
              tempHeld.st_size == bytes.count else { throw VoiceLifecycleFailure.unsafeRecord }
        try validateRoot()
        // Close the actual writer successfully before publishing its record.
        let closeResult = close(fd), closeError = errno
        closed = true
        guard closeResult == 0 else { throw VoiceLifecycleFailure.io(closeError) }
        guard renameat(rootFD, temporary, rootFD, name) == 0 else { throw VoiceLifecycleFailure.io(errno) }
        renamed = true
        guard fsync(rootFD) == 0 else { throw VoiceLifecycleFailure.io(errno) }
        let committed = try read()
        guard committed.node == temporaryNode, committed.bytes == bytes else { throw VoiceLifecycleFailure.unsafeRecord }
        try owner.revalidate()
    }
}
