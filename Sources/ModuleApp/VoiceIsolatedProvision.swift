import Foundation
import Darwin
import NookLocalServiceKit

// Preserve a primary creation error and any original descriptor close failure.
struct VoiceProvisionCleanupFailure: Error {
    let original: Error
    let closeErrors: [Int32]
}

// This capability is created only by the retained, exclusive creation below.
// A URL, copied directory, metadata record or caller assertion cannot mint it.
final class VoiceIsolatedProvision: VoiceLifecycleGenesisProvision, @unchecked Sendable {
    let root: URL
    private let owner: LocalServiceOwner
    private let binding: VoiceLifecycleBinding
    private let parent: URL
    private let name: String
    private let parentFD: Int32
    private let rootFD: Int32
    private let parentDevice: dev_t, parentInode: ino_t, rootDevice: dev_t, rootInode: ino_t
    private let lock = NSLock()
    private var claimed = false
    private var closed = false
    private var closeError: Int32?

    private init(parent: URL, name: String, parentFD: Int32, rootFD: Int32,
                 parentStat: stat, rootStat: stat, owner: LocalServiceOwner, binding: VoiceLifecycleBinding) {
        self.parent = parent; self.name = name; self.parentFD = parentFD; self.rootFD = rootFD
        self.root = parent.appendingPathComponent(name, isDirectory: true)
        self.parentDevice = parentStat.st_dev; self.parentInode = parentStat.st_ino
        self.rootDevice = rootStat.st_dev; self.rootInode = rootStat.st_ino
        self.owner = owner; self.binding = binding
    }

    // The detached operation, including both native descriptors and successful
    // mkdir, remains alive until its actual return even if the caller cancels.
    static func create(parent: URL, owner: LocalServiceOwner, binding: VoiceLifecycleBinding,
                       checkpoint: (@Sendable () -> Void)? = nil) async throws -> VoiceIsolatedProvision {
        try Task.checkCancellation()
        let original = Task.detached { try createOriginal(parent: parent, owner: owner, binding: binding, checkpoint: checkpoint) }
        let result = await withTaskCancellationHandler { await original.result } onCancel: { original.cancel() }
        let provision = try result.get()
        if Task.isCancelled {
            do { try provision.closeOriginals() }
            catch let failure as VoiceLifecycleFailure {
                if case .io(let code) = failure { throw VoiceProvisionCleanupFailure(original: CancellationError(), closeErrors: [code]) }
                throw failure
            }
            throw CancellationError()
        }
        return provision
    }
    private static func createOriginal(parent: URL, owner: LocalServiceOwner, binding: VoiceLifecycleBinding,
                                       checkpoint: (@Sendable () -> Void)?) throws -> VoiceIsolatedProvision {
        try Task.checkCancellation(); try owner.revalidate()
        guard binding.ownPolicyKey == owner.ownPolicyKey, parent.isFileURL,
              parent.path.hasPrefix("/"), !parent.path.hasSuffix("/"),
              let physical = realpath(parent.path, nil) else { throw VoiceLifecycleFailure.unsafeRoot }
        defer { free(physical) }
        guard String(cString: physical) == parent.path else { throw VoiceLifecycleFailure.unsafeRoot }
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw VoiceLifecycleFailure.io(errno) }
        var childFD: Int32 = -1
        do {
        var held = stat(), named = stat()
        guard fstat(parentFD, &held) == 0, lstat(parent.path, &named) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              held.st_mode & S_IFMT == S_IFDIR, held.st_uid == geteuid(), held.st_mode & 0o7777 == 0o700 else {
            throw VoiceLifecycleFailure.unsafeRoot
        }
        try Task.checkCancellation(); try owner.revalidate()
        let name = "isolated-" + UUID().uuidString.lowercased()
        guard mkdirat(parentFD, name, mode_t(0o700)) == 0 else { throw VoiceLifecycleFailure.io(errno) }
        // Pin the first named observation immediately after successful mkdir;
        // later open must refer to exactly this observed original directory.
        var created = stat()
        guard fstatat(parentFD, name, &created, AT_SYMLINK_NOFOLLOW) == 0,
              created.st_mode & S_IFMT == S_IFDIR, created.st_uid == geteuid(),
              created.st_mode & 0o7777 == 0o700 else { throw VoiceLifecycleFailure.unsafeRoot }
        guard fsync(parentFD) == 0 else { throw VoiceLifecycleFailure.io(errno) }
        checkpoint?()
        try Task.checkCancellation()
        let rootFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw VoiceLifecycleFailure.io(errno) }
        childFD = rootFD
        var child = stat(), childNamed = stat(), parentAgain = stat()
        guard fstat(rootFD, &child) == 0, fstatat(parentFD, name, &childNamed, AT_SYMLINK_NOFOLLOW) == 0,
              lstat(parent.path, &parentAgain) == 0,
              parentAgain.st_dev == held.st_dev, parentAgain.st_ino == held.st_ino,
              child.st_dev == childNamed.st_dev, child.st_ino == childNamed.st_ino,
              child.st_dev == created.st_dev, child.st_ino == created.st_ino,
              child.st_mode & S_IFMT == S_IFDIR, child.st_uid == geteuid(), child.st_mode & 0o7777 == 0o700 else {
            throw VoiceLifecycleFailure.unsafeRoot
        }
        try Task.checkCancellation(); try owner.revalidate()
        let result = VoiceIsolatedProvision(parent: parent, name: name, parentFD: parentFD, rootFD: rootFD,
                                            parentStat: held, rootStat: child, owner: owner, binding: binding)
        return result
        } catch {
            var closeErrors: [Int32] = []
            if childFD >= 0, Darwin.close(childFD) != 0 { closeErrors.append(errno) }
            if Darwin.close(parentFD) != 0 { closeErrors.append(errno) }
            if !closeErrors.isEmpty { throw VoiceProvisionCleanupFailure(original: error, closeErrors: closeErrors) }
            throw error
        }
    }
    func consume(owner expected: LocalServiceOwner, binding expectedBinding: VoiceLifecycleBinding) throws {
        guard owner === expected, binding.serviceIdentifier == expectedBinding.serviceIdentifier,
              binding.buildIdentifier == expectedBinding.buildIdentifier, binding.bootSessionUUID == expectedBinding.bootSessionUUID,
              binding.ownPolicyKey == expectedBinding.ownPolicyKey else { throw VoiceLifecycleFailure.invalidBinding }
        lock.lock(); let used = claimed || closed
        if !used { claimed = true }
        lock.unlock()
        guard !used else { throw VoiceLifecycleFailure.busy }
        do { try revalidate() }
        catch {
            let originalError = error
            do { try closeAfterConsumption() }
            catch let cleanup as VoiceLifecycleFailure {
                if case .io(let code) = cleanup { throw VoiceProvisionCleanupFailure(original: originalError, closeErrors: [code]) }
                throw cleanup
            }
            throw originalError
        }
    }
    func revalidate() throws {
        try owner.revalidate()
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw VoiceLifecycleFailure.unsafeRoot }
        guard let physical = realpath(parent.path, nil) else { throw VoiceLifecycleFailure.unsafeRoot }
        defer { free(physical) }
        guard String(cString: physical) == parent.path else { throw VoiceLifecycleFailure.unsafeRoot }
        var heldParent = stat(), namedParent = stat(), heldRoot = stat(), namedRoot = stat()
        guard fstat(parentFD, &heldParent) == 0, lstat(parent.path, &namedParent) == 0,
              fstat(rootFD, &heldRoot) == 0, fstatat(parentFD, name, &namedRoot, AT_SYMLINK_NOFOLLOW) == 0,
              heldParent.st_dev == parentDevice, heldParent.st_ino == parentInode,
              namedParent.st_dev == parentDevice, namedParent.st_ino == parentInode,
              heldRoot.st_dev == rootDevice, heldRoot.st_ino == rootInode,
              namedRoot.st_dev == rootDevice, namedRoot.st_ino == rootInode,
              heldParent.st_mode & 0o7777 == 0o700, heldParent.st_uid == geteuid(),
              heldRoot.st_mode & 0o7777 == 0o700, heldRoot.st_uid == geteuid() else {
            throw VoiceLifecycleFailure.unsafeRoot
        }
    }
    func matches(rootFD candidate: Int32) throws {
        try revalidate()
        var other = stat()
        guard fstat(candidate, &other) == 0, other.st_dev == rootDevice, other.st_ino == rootInode else {
            throw VoiceLifecycleFailure.unsafeRoot
        }
    }
    // Close each original exactly once and report the first actual error; never
    // retry a numeric descriptor that the OS may already have reused.
    // Before consumption, the creator can explicitly close a failed handoff.
    // Once claimed, only the ledger's retained cleanup path may close them.
    func closeOriginals() throws { try close(allowClaimed: false) }
    func closeAfterConsumption() throws { try close(allowClaimed: true) }
    private func close(allowClaimed: Bool) throws {
        lock.lock()
        if claimed && !allowClaimed { lock.unlock(); throw VoiceLifecycleFailure.busy }
        if closed {
            let error = closeError; lock.unlock()
            if let error { throw VoiceLifecycleFailure.io(error) }
            return
        }
        closed = true
        let childStatus = Darwin.close(rootFD), childError = errno
        let parentStatus = Darwin.close(parentFD), parentError = errno
        closeError = childStatus != 0 ? childError : (parentStatus != 0 ? parentError : nil)
        let error = closeError; lock.unlock()
        if let error { throw VoiceLifecycleFailure.io(error) }
    }
    deinit { try? close(allowClaimed: true) }
}
