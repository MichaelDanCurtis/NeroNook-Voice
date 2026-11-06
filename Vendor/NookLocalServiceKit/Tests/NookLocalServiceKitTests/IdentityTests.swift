import Foundation
import XCTest
@testable import NookLocalServiceKit
#if os(macOS)
import Darwin
import Security
import CryptoKit

// Explicit mechanics fixture: the actual current test host's own designated
// requirement. This is not an operational Developer ID policy or approval.
func genuineNativeRequirement() throws -> String {
    var code: SecCode?
    var status = SecCodeCopySelf(SecCSFlags(), &code)
    guard status == errSecSuccess, let code else {
        throw NSError(domain: "NativeKitTest.Security", code: Int(status))
    }
    var staticCode: SecStaticCode?
    status = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
    guard status == errSecSuccess, let staticCode else {
        throw NSError(domain: "NativeKitTest.Security", code: Int(status))
    }
    var requirement: SecRequirement?
    status = SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement)
    guard status == errSecSuccess, let requirement else {
        throw NSError(domain: "NativeKitTest.Security", code: Int(status))
    }
    status = SecCodeCheckValidity(code, SecCSFlags.noNetworkAccess, requirement)
    guard status == errSecSuccess else {
        throw NSError(domain: "NativeKitTest.Security", code: Int(status))
    }
    var text: CFString?
    status = SecRequirementCopyString(requirement, SecCSFlags(), &text)
    guard status == errSecSuccess, let text else {
        throw NSError(domain: "NativeKitTest.Security", code: Int(status))
    }
    let value = text as String
    guard !value.isEmpty else { throw NSError(domain: "NativeKitTest.Security", code: -1) }
    return value
}

func genuineNativeTestPolicy(service: String = "test.nero." + "s" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")) throws -> LocalServicePolicy {
    let requirement = try genuineNativeRequirement()
    return try LocalServicePolicy(serviceIdentifier: service,
                                  trustedSelfRequirements: ["test": requirement],
                                  trustedPeerRequirements: ["test": requirement])
}

private func lockPath(_ service: String) -> String {
    let digest = SHA256.hash(data: Data(service.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    return "/private/tmp/nero-local-\(geteuid())/\(digest).lock"
}

final class IdentityTests: XCTestCase {
    func testStructuralPolicyRejectsInvalidServiceKeysCountsAndNul() throws {
        let service = "test.nero.structural"
        func policy(_ service: String = "test.nero.structural", _ own: [String: String] = ["test": "x"],
                    _ peer: [String: String] = ["test": "x"]) throws -> LocalServicePolicy {
            try LocalServicePolicy(serviceIdentifier: service, trustedSelfRequirements: own, trustedPeerRequirements: peer)
        }
        for bad in ["", "single", "Test.nero", "test..nero", "test.1nero", "test.nero_thing", "test.nero\0"] {
            XCTAssertThrowsError(try policy(bad)) { XCTAssertEqual($0 as? LocalServiceError, .invalidPolicy) }
        }
        for bad in [[String: String](), ["": "x"], ["bad.key": "x"], ["test": ""], ["test": "x\0"],
                    [String(repeating: "k", count: 65): "x"], ["test": String(repeating: "x", count: 4097)],
                    Dictionary(uniqueKeysWithValues: (0..<9).map { ("k\($0)", "x") })] {
            XCTAssertThrowsError(try policy(service, bad)) { XCTAssertEqual($0 as? LocalServiceError, .invalidPolicy) }
            XCTAssertThrowsError(try policy(service, ["test": "x"], bad)) { XCTAssertEqual($0 as? LocalServiceError, .invalidPolicy) }
        }
    }

    func testPolicyUsesExactUtf8FieldSumRatherThanEscapedJsonSize() throws {
        let service = "test.nero.policybytes"
        let value = String(repeating: "é", count: 2048) // 4096 actual UTF8 bytes.
        let own = Dictionary(uniqueKeysWithValues: (0..<8).map { ("s\($0)", value) })
        var peer = Dictionary(uniqueKeysWithValues: (0..<8).map { ("p\($0)", value) })
        let overhead = service.utf8.count + own.keys.reduce(0) { $0 + $1.utf8.count } + peer.keys.reduce(0) { $0 + $1.utf8.count }
        peer["p7"] = String(repeating: "x", count: 4096 - overhead)
        let exact = service.utf8.count + own.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            + peer.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        XCTAssertEqual(exact, 65_536)
        _ = try LocalServicePolicy(serviceIdentifier: service, trustedSelfRequirements: own, trustedPeerRequirements: peer)
        peer["p7"]! += "x"
        XCTAssertThrowsError(try LocalServicePolicy(serviceIdentifier: service, trustedSelfRequirements: own, trustedPeerRequirements: peer)) {
            XCTAssertEqual($0 as? LocalServiceError, .invalidPolicy)
        }
    }

    func testActualSelfRequirementMatchesOnlyObservedTestHost() throws {
        let identity = try NativeSelfIdentity(policy: genuineNativeTestPolicy())
        XCTAssertEqual(identity.policyKey, "test")
        try identity.revalidate()
    }

    func testWrongAndAmbiguousSelfRefuseBeforeServiceLockPublication() throws {
        let requirement = try genuineNativeRequirement()
        for own in [["wrong": "identifier \"test.nero.not-this-native-host\""], ["first": requirement, "second": requirement]] {
            let service = "test.nero.s" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let path = lockPath(service)
            var node = stat()
            XCTAssertEqual(lstat(path, &node), -1); XCTAssertEqual(errno, ENOENT)
            let policy = try LocalServicePolicy(serviceIdentifier: service, trustedSelfRequirements: own, trustedPeerRequirements: ["test": requirement])
            XCTAssertThrowsError(try LocalServiceOwner.acquire(policy: policy)) { XCTAssertEqual($0 as? LocalServiceError, .selfRejected) }
            XCTAssertEqual(lstat(path, &node), -1); XCTAssertEqual(errno, ENOENT)
        }
    }

    func testInvalidSecurityRequirementRefusesAtActualSelfCompilation() throws {
        let service = "test.nero.s" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let policy = try LocalServicePolicy(serviceIdentifier: service, trustedSelfRequirements: ["test": "??? not a Security requirement"],
                                           trustedPeerRequirements: ["test": genuineNativeRequirement()])
        XCTAssertThrowsError(try LocalServiceOwner.acquire(policy: policy)) { XCTAssertEqual($0 as? LocalServiceError, .invalidPolicy) }
        var node = stat()
        XCTAssertEqual(lstat(lockPath(service), &node), -1); XCTAssertEqual(errno, ENOENT)
    }

    func testActualSocketpairPeerRejectsWrongAndAmbiguousRequirementsAndCannotReviveAfterStop() throws {
        let policy = try genuineNativeTestPolicy(), requirement = try genuineNativeRequirement()
        let own = try NativeSelfIdentity(policy: policy)
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw LocalServiceError.systemCall(errno) }
        defer { _ = Darwin.close(pair[0]); _ = Darwin.close(pair[1]) }
        for fd in pair { XCTAssertEqual(fcntl(fd, F_SETFD, FD_CLOEXEC), 0) }
        for peers in [["wrong": "identifier \"test.nero.not-this-native-host\""], ["first": requirement, "second": requirement]] {
            let rejected = try LocalServicePolicy(serviceIdentifier: policy.serviceIdentifier,
                trustedSelfRequirements: ["test": requirement], trustedPeerRequirements: peers)
            XCTAssertThrowsError(try NativePeerProof(fd: pair[0], own: own, policy: rejected)) {
                XCTAssertEqual($0 as? LocalServiceError, .peerRejected)
            }
        }
        let proof = try NativePeerProof(fd: pair[0], own: own, policy: policy)
        let peer = LocalServicePeer(proof: proof)
        defer { proof.invalidate() }
        XCTAssertEqual(peer.policyKey, "test"); XCTAssertFalse(peer.displayIdentifier.isEmpty)
        try peer.revalidate()
        proof.invalidate()
        for _ in 0..<2 { XCTAssertThrowsError(try peer.revalidate()) { XCTAssertEqual($0 as? LocalServiceError, .changedIdentity) } }
    }
}
#else
func genuineNativeRequirement() throws -> String { throw LocalServiceError.unsupportedPlatform }
func genuineNativeTestPolicy(service: String = "test.nero.unsupported") throws -> LocalServicePolicy { throw LocalServiceError.unsupportedPlatform }
#endif
