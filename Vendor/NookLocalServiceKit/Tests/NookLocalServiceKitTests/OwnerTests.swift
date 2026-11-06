import Foundation
import XCTest
@testable import NookLocalServiceKit
#if os(macOS)
import Darwin

private func node(_ root: ServiceRoot, _ name: String) throws -> stat {
    var value = stat()
    guard fstatat(root.directoryFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw LocalServiceError.systemCall(errno) }
    return value
}
private func assertSameNode(_ first: stat, _ second: stat, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(first.st_dev, second.st_dev, file: file, line: line)
    XCTAssertEqual(first.st_ino, second.st_ino, file: file, line: line)
    XCTAssertEqual(first.st_mode, second.st_mode, file: file, line: line)
}
private func removeAuthoredNode(_ root: ServiceRoot, _ name: String, _ original: stat, directory: Bool = false) {
    guard let current = try? node(root, name), current.st_dev == original.st_dev,
          current.st_ino == original.st_ino, current.st_mode == original.st_mode else { return }
    _ = unlinkat(root.directoryFD, name, directory ? AT_REMOVEDIR : 0)
}
private func writeAuthoredFile(_ root: ServiceRoot, _ name: String, _ bytes: Data) throws -> stat {
    let fd = openat(root.directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw LocalServiceError.systemCall(errno) }
    defer { _ = Darwin.close(fd) }
    try bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw LocalServiceError.systemCall(errno) }
            offset += written
        }
    }
    return try node(root, name)
}

final class OwnerTests: XCTestCase {
    func testPublicOwnerExcludesAnotherOpenAndKeepsPermanentInodeAfterRelease() throws {
        let policy = try genuineNativeTestPolicy()
        var first: LocalServiceOwner? = try LocalServiceOwner.acquire(policy: policy)
        let root = try XCTUnwrap(first).lock.root, name = root.digest + ".lock"
        let original = try node(root, name)
        XCTAssertEqual(original.st_mode & S_IFMT, S_IFREG); XCTAssertEqual(original.st_nlink, 1)
        XCTAssertEqual(try XCTUnwrap(first).ownPolicyKey, "test")
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try LocalServiceOwner.acquire(policy: policy)) { XCTAssertEqual($0 as? LocalServiceError, .ownerPresent) }
        }
        first = nil
        let second = try LocalServiceOwner.acquire(policy: policy)
        try second.revalidate()
        assertSameNode(original, try node(root, name))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root.path + "/" + name)), Data(policy.serviceIdentifier.utf8))
        // Permanent lock inode intentionally remains. No unlink/recreate shortcut.
    }

    func testListenerRetainsPublicOwnerThroughOriginalAcceptCleanup() async throws {
        let policy = try genuineNativeTestPolicy()
        var owner: LocalServiceOwner? = try LocalServiceOwner.acquire(policy: policy)
        let root = try XCTUnwrap(owner).lock.root
        let original = try node(root, root.digest + ".lock")
        var listener: LocalServiceListener? = try LocalServiceListener(owner: XCTUnwrap(owner), policy: policy)
        owner = nil
        XCTAssertThrowsError(try LocalServiceOwner.acquire(policy: policy)) { XCTAssertEqual($0 as? LocalServiceError, .ownerPresent) }
        try XCTUnwrap(listener).stopAccepting()
        let completion = try await XCTUnwrap(listener).retirement()
        XCTAssertNil(completion.failure)
        switch completion.status { case .closed: break; case .failed: XCTFail("Original listener cleanup failed") }
        listener = nil
        let successor = try LocalServiceOwner.acquire(policy: policy)
        try successor.revalidate()
        assertSameNode(original, try node(root, root.digest + ".lock"))
    }

    func testConflictingFullServiceMetadataRefusesWithoutRewritingPermanentFile() throws {
        let policy = try genuineNativeTestPolicy(), root = try ServiceRoot(service: policy.serviceIdentifier, create: true)
        let name = root.digest + ".lock", bytes = Data("different-service".utf8)
        let original = try writeAuthoredFile(root, name, bytes)
        XCTAssertThrowsError(try LocalServiceOwner.acquire(policy: policy)) { XCTAssertEqual($0 as? LocalServiceError, .unsafeRoot) }
        assertSameNode(original, try node(root, name))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root.path + "/" + name)), bytes)
        // Preserve this exact refused lock metadata; never unlink a permanent lock.
    }

    func testSymlinkLockRefusesAndDoesNotFollowOrModifyTarget() throws {
        let policy = try genuineNativeTestPolicy(), root = try ServiceRoot(service: policy.serviceIdentifier, create: true)
        let name = root.digest + ".lock", target = root.digest + ".target", bytes = Data("authored untouched target".utf8)
        let targetNode = try writeAuthoredFile(root, target, bytes)
        defer { removeAuthoredNode(root, target, targetNode) }
        guard symlinkat(target, root.directoryFD, name) == 0 else { throw LocalServiceError.systemCall(errno) }
        let original = try node(root, name)
        defer { removeAuthoredNode(root, name, original) }
        XCTAssertEqual(original.st_mode & S_IFMT, S_IFLNK)
        XCTAssertThrowsError(try LocalServiceOwner.acquire(policy: policy)) { XCTAssertEqual($0 as? LocalServiceError, .unsafeRoot) }
        assertSameNode(original, try node(root, name)); assertSameNode(targetNode, try node(root, target))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root.path + "/" + target)), bytes)
    }

    func testFifoLockRefusesWithoutAdoptingOrMutatingNode() throws {
        let policy = try genuineNativeTestPolicy(), root = try ServiceRoot(service: policy.serviceIdentifier, create: true)
        let name = root.digest + ".lock"
        guard mkfifo(root.path + "/" + name, 0o600) == 0 else { throw LocalServiceError.systemCall(errno) }
        let original = try node(root, name)
        defer { removeAuthoredNode(root, name, original) }
        XCTAssertEqual(original.st_mode & S_IFMT, S_IFIFO)
        XCTAssertThrowsError(try LocalServiceOwner.acquire(policy: policy)) { XCTAssertEqual($0 as? LocalServiceError, .unsafeRoot) }
        assertSameNode(original, try node(root, name))
    }

    func testUnrelatedDirectoryLinkCountChangeDoesNotReplaceRootIdentity() throws {
        let policy = try genuineNativeTestPolicy()
        let owner = try LocalServiceOwner.acquire(policy: policy), root = owner.lock.root
        let name = root.digest + ".authored-directory"
        guard mkdirat(root.directoryFD, name, 0o700) == 0 else { throw LocalServiceError.systemCall(errno) }
        let original = try node(root, name)
        defer { removeAuthoredNode(root, name, original, directory: true) }
        try root.revalidate(); try owner.revalidate()
        // On filesystems exposing directory link counts, unrelated children may
        // change that count. Stable root identity/mode/owner must still match.
    }
}
#endif
