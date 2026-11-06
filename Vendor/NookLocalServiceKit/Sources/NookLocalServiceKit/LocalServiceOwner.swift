import Foundation
#if os(macOS)
import Darwin
import CryptoKit

struct LocalNode: Equatable, Sendable {
    let device: dev_t, inode: ino_t
    let mode: mode_t
    let uid: uid_t
    let links: nlink_t
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        uid = value.st_uid; links = (value.st_mode & S_IFMT == S_IFREG) ? value.st_nlink : 0
    }
}

// Physical directory and permanent lock primitives are shared by the public
// owner and real filesystem tests. This type cannot create a native principal.
final class ServiceRoot: Sendable {
    let path: String
    let digest: String
    let socketPath: String
    let directoryFD: Int32
    private let parentFD: Int32
    private let observation: LocalNode
    private let parentObservation: LocalNode
    init(service: String, create: Bool) throws {
        path = "/private/tmp/nero-local-\(geteuid())"
        digest = SHA256.hash(data: Data(service.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        socketPath = path + "/" + digest + ".sock"
        guard socketPath.utf8.count + 1 <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw LocalServiceError.unsafeRoot
        }
        let parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw LocalServiceError.unsafeRoot }
        var keepParent = false
        defer { if !keepParent { _ = Darwin.close(parent) } }
        var p = stat(), namedParent = stat()
        guard fstat(parent, &p) == 0, lstat("/private/tmp", &namedParent) == 0,
              LocalNode(p) == LocalNode(namedParent), p.st_mode & S_IFMT == S_IFDIR,
              p.st_uid == 0, p.st_mode & S_ISVTX != 0 else { throw LocalServiceError.unsafeRoot }
        let name = "nero-local-\(geteuid())"
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
            throw LocalServiceError.systemCall(errno)
        }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw create ? LocalServiceError.unsafeRoot : .disconnected }
        var keepDirectory = false
        defer { if !keepDirectory { _ = Darwin.close(directory) } }
        var d = stat(), named = stat()
        guard fstat(directory, &d) == 0, fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              LocalNode(d) == LocalNode(named), d.st_mode & S_IFMT == S_IFDIR,
              d.st_uid == geteuid(), d.st_mode & 0o7777 == 0o700 else { throw LocalServiceError.unsafeRoot }
        parentFD = parent; directoryFD = directory
        observation = LocalNode(d); parentObservation = LocalNode(p)
        keepParent = true; keepDirectory = true
    }
    func revalidate() throws {
        var parent = stat(), namedParent = stat(), directory = stat(), namedDirectory = stat()
        guard fstat(parentFD, &parent) == 0, lstat("/private/tmp", &namedParent) == 0,
              LocalNode(parent) == parentObservation, LocalNode(namedParent) == parentObservation,
              fstat(directoryFD, &directory) == 0,
              fstatat(parentFD, "nero-local-\(geteuid())", &namedDirectory, AT_SYMLINK_NOFOLLOW) == 0,
              LocalNode(directory) == observation, LocalNode(namedDirectory) == observation else {
            throw LocalServiceError.unsafeRoot
        }
    }
    func namedSocket() throws -> LocalNode? {
        try revalidate()
        var value = stat()
        if fstatat(directoryFD, digest + ".sock", &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw LocalServiceError.systemCall(errno)
        }
        guard value.st_mode & S_IFMT == S_IFSOCK, value.st_uid == geteuid(),
              value.st_mode & 0o7777 == 0o600 else { throw LocalServiceError.unsafeRoot }
        return LocalNode(value)
    }
    func removeSocket(_ original: LocalNode) throws {
        guard try namedSocket() == original else { throw LocalServiceError.unsafeRoot }
        guard unlinkat(directoryFD, digest + ".sock", 0) == 0 else { throw LocalServiceError.systemCall(errno) }
    }
    deinit { _ = Darwin.close(directoryFD); _ = Darwin.close(parentFD) }
}

final class PermanentServiceLock: Sendable {
    let root: ServiceRoot
    private let fd: Int32
    private let observation: LocalNode
    private let metadata: Data
    init(root: ServiceRoot, service: String) throws {
        try root.revalidate()
        let name = root.digest + ".lock"
        var created = true
        var opened = openat(root.directoryFD, name, O_RDWR | O_NONBLOCK | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if opened < 0, errno == EEXIST {
            created = false
            opened = openat(root.directoryFD, name, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard opened >= 0 else { throw LocalServiceError.unsafeRoot }
        var keep = false
        defer { if !keep { _ = Darwin.close(opened) } }
        var value = stat(), named = stat()
        guard fstat(opened, &value) == 0, fstatat(root.directoryFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              LocalNode(value) == LocalNode(named), value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o7777 == 0o600, value.st_uid == geteuid(), value.st_nlink == 1 else {
            throw LocalServiceError.unsafeRoot
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw LocalServiceError.ownerPresent }
            throw LocalServiceError.systemCall(errno)
        }
        let metadata = Data(service.utf8)
        if created {
            var written = 0
            try metadata.withUnsafeBytes { bytes in
                while written < bytes.count {
                    let count = Darwin.write(opened, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw LocalServiceError.systemCall(errno) }
                    written += count
                }
            }
            guard fsync(opened) == 0 else { throw LocalServiceError.systemCall(errno) }
        } else {
            guard value.st_size == metadata.count else { throw LocalServiceError.unsafeRoot }
            var buffer = [UInt8](repeating: 0, count: metadata.count + 1)
            let count = buffer.withUnsafeMutableBytes { pread(opened, $0.baseAddress!, $0.count, 0) }
            guard count == metadata.count, Data(buffer.prefix(count)) == metadata else { throw LocalServiceError.unsafeRoot }
        }
        // Size changes on initial metadata write; pin the postimage, never unlink
        // this permanent inode even if a later listener or native check fails.
        guard fstat(opened, &value) == 0 else { throw LocalServiceError.systemCall(errno) }
        self.root = root; fd = opened; observation = LocalNode(value); self.metadata = metadata; keep = true
        try revalidate()
    }
    func revalidate() throws {
        try root.revalidate()
        var original = stat(), named = stat()
        guard fstat(fd, &original) == 0,
              fstatat(root.directoryFD, root.digest + ".lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              LocalNode(original) == observation, LocalNode(named) == observation,
              original.st_size == metadata.count, named.st_size == metadata.count else { throw LocalServiceError.unsafeRoot }
        var buffer = [UInt8](repeating: 0, count: metadata.count + 1)
        let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, 0) }
        guard count == metadata.count, Data(buffer.prefix(count)) == metadata else { throw LocalServiceError.unsafeRoot }
    }
    deinit { _ = Darwin.close(fd) }
}
#endif

public final class LocalServiceOwner: Sendable {
    public let ownPolicyKey: String
    #if os(macOS)
    let policy: LocalServicePolicy
    let own: NativeSelfIdentity
    let lock: PermanentServiceLock
    private let valid = LockedState(true)
    private init(policy: LocalServicePolicy, own: NativeSelfIdentity, lock: PermanentServiceLock) {
        self.policy = policy; self.own = own; self.lock = lock; ownPolicyKey = own.policyKey
    }
    #else
    private init() throws { throw LocalServiceError.unsupportedPlatform }
    #endif
    public static func acquire(policy: LocalServicePolicy) throws -> LocalServiceOwner {
        #if os(macOS)
        let own = try NativeSelfIdentity(policy: policy)
        let lock = try PermanentServiceLock(root: ServiceRoot(service: policy.serviceIdentifier, create: true), service: policy.serviceIdentifier)
        try own.revalidate(); try lock.revalidate()
        return LocalServiceOwner(policy: policy, own: own, lock: lock)
        #else
        throw LocalServiceError.unsupportedPlatform
        #endif
    }
    public func revalidate() throws {
        #if os(macOS)
        do {
            guard valid.withLock({ $0 }) else { throw LocalServiceError.changedIdentity }
            try own.revalidate(); try lock.revalidate()
        } catch { valid.withLock { $0 = false }; own.invalidate(); throw error }
        #else
        throw LocalServiceError.unsupportedPlatform
        #endif
    }
}
