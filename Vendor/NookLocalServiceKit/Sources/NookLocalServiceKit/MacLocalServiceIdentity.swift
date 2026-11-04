import Foundation
#if os(macOS)
import Darwin
import Security

private func auditBytes(_ value: audit_token_t) -> Data {
    var copy = value
    return withUnsafeBytes(of: &copy) { Data($0) }
}

private func currentAudit() throws -> audit_token_t {
    var token = audit_token_t()
    let expected = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    var count = expected
    let result = withUnsafeMutablePointer(to: &token) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(expected)) {
            task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
        }
    }
    guard result == KERN_SUCCESS, count == expected else { throw LocalServiceError.selfRejected }
    return token
}

private struct NativeCode {
    let code: SecCode
    let requirements: [String: SecRequirement]
}

private func compileRequirements(_ strings: [String: String]) throws -> [String: SecRequirement] {
    var result: [String: SecRequirement] = [:]
    for (key, text) in strings {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { throw LocalServiceError.invalidPolicy }
        result[key] = requirement
    }
    return result
}

private func uniqueMatch(_ native: NativeCode, rejected: LocalServiceError) throws -> String {
    // Explicit offline validity. A matching requirement is eligibility only,
    // never the caller's application approval or resource-clean witness.
    let flags = SecCSFlags.noNetworkAccess
    let matches = native.requirements.compactMap { key, requirement in
        SecCodeCheckValidity(native.code, flags, requirement) == errSecSuccess ? key : nil
    }
    guard matches.count == 1, let key = matches.first else { throw rejected }
    return key
}

final class NativeSelfIdentity: Sendable {
    let policyKey: String
    private struct State {
        let token: Data
        let native: NativeCode
        let euid: uid_t
        let session: au_asid_t
        var valid = true
    }
    private let state: LockedState<State>
    init(policy: LocalServicePolicy) throws {
        let token = try currentAudit()
        guard audit_token_to_euid(token) == geteuid() else { throw LocalServiceError.selfRejected }
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            throw LocalServiceError.selfRejected
        }
        let native = NativeCode(code: code, requirements: try compileRequirements(policy.trustedSelfRequirements))
        policyKey = try uniqueMatch(native, rejected: .selfRejected)
        state = LockedState(State(token: auditBytes(token), native: native,
                                  euid: audit_token_to_euid(token), session: audit_token_to_asid(token)))
        try revalidate()
    }
    func revalidate() throws {
        do {
            let snapshot = try state.withLock { value in
                guard value.valid else { throw LocalServiceError.changedIdentity }
                return value
            }
            let now = try currentAudit()
            guard auditBytes(now) == snapshot.token, geteuid() == snapshot.euid,
                  audit_token_to_asid(now) == snapshot.session,
                  try uniqueMatch(snapshot.native, rejected: .changedIdentity) == policyKey,
                  state.withLock({ $0.valid }) else { throw LocalServiceError.changedIdentity }
        } catch { invalidate(); throw error }
    }
    func invalidate() { state.withLock { $0.valid = false } }
    func matchesSession(_ token: audit_token_t) -> Bool {
        state.withLock { $0.valid && audit_token_to_euid(token) == $0.euid && audit_token_to_asid(token) == $0.session }
    }
}

// A private duplicate of the actual connected descriptor pins the open-file
// description while Security calls are in flight. Stop permanently invalidates
// it; the last original native call, not a timer, releases that duplicate.
final class NativePeerProof: Sendable {
    let policyKey: String
    let displayIdentifier: String
    let own: NativeSelfIdentity
    private struct State {
        var fd: Int32
        let token: Data
        let device: dev_t
        let inode: ino_t
        let native: NativeCode
        var owner: LocalServiceOwner?
        var valid = true
        var calls = 0
        var closing = false
        var failure: LocalServiceError?
        var drained: [CheckedContinuation<LocalServiceError?, Never>] = []
    }
    private let state: LockedState<State>
    init(fd: Int32, own: NativeSelfIdentity, policy: LocalServicePolicy, owner: LocalServiceOwner? = nil) throws {
        try own.revalidate()
        let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { throw LocalServiceError.systemCall(errno) }
        var taken = false
        defer { if !taken { _ = Darwin.close(duplicate) } }
        var observation = stat()
        var type: Int32 = 0; var typeSize = socklen_t(MemoryLayout<Int32>.size)
        var address = sockaddr_un(); var addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let addressStatus = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(duplicate, $0, &addressSize) }
        }
        var token = audit_token_t(); var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard fstat(duplicate, &observation) == 0, observation.st_mode & S_IFMT == S_IFSOCK,
              getsockopt(duplicate, SOL_SOCKET, SO_TYPE, &type, &typeSize) == 0, type == SOCK_STREAM,
              addressStatus == 0, Int32(address.sun_family) == AF_UNIX,
              getsockopt(duplicate, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0,
              size == MemoryLayout<audit_token_t>.size, own.matchesSession(token) else {
            throw LocalServiceError.peerRejected
        }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditBytes(token)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess, let code else {
            throw LocalServiceError.peerRejected
        }
        let native = NativeCode(code: code, requirements: try compileRequirements(policy.trustedPeerRequirements))
        policyKey = try uniqueMatch(native, rejected: .peerRejected)
        var staticCode: SecStaticCode?; var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(), &info) == errSecSuccess,
              let identifier = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String,
              !identifier.isEmpty, identifier.utf8.count <= 1024, !identifier.utf8.contains(0) else {
            throw LocalServiceError.peerRejected
        }
        displayIdentifier = identifier; self.own = own
        state = LockedState(State(fd: duplicate, token: auditBytes(token), device: observation.st_dev,
                                  inode: observation.st_ino, native: native, owner: owner))
        taken = true
        do { try revalidate() } catch { invalidate(); throw error }
    }
    func revalidate() throws {
        let snapshot: (Int32, Data, dev_t, ino_t, NativeCode, LocalServiceOwner?) = try state.withLock {
            guard $0.valid, $0.fd >= 0 else { throw LocalServiceError.changedIdentity }
            $0.calls += 1
            return ($0.fd, $0.token, $0.device, $0.inode, $0.native, $0.owner)
        }
        defer { releaseCall() }
        do {
        try snapshot.5?.revalidate()
        try own.revalidate()
        var observation = stat(), token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard fstat(snapshot.0, &observation) == 0,
              observation.st_dev == snapshot.2, observation.st_ino == snapshot.3,
              getsockopt(snapshot.0, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size, auditBytes(token) == snapshot.1,
              own.matchesSession(token), try uniqueMatch(snapshot.4, rejected: .changedIdentity) == policyKey,
              state.withLock({ $0.valid && $0.fd == snapshot.0 }), own.matchesSession(token) else {
            throw LocalServiceError.changedIdentity
        }
        } catch {
            // Capture only an actual failure of this still-active proof. An
            // intentional Stop that won invalidation, or a stale query after
            // retirement, must not poison the completed clean IO outcome.
            state.withLock { value in
                if value.valid {
                    if value.failure == nil { value.failure = error as? LocalServiceError ?? .changedIdentity }
                    value.valid = false
                }
            }
            invalidate(); throw error
        }
    }
    func invalidate() {
        let closeFD: Int32? = state.withLock {
            $0.valid = false
            guard $0.calls == 0, $0.fd >= 0, !$0.closing else { return nil }
            $0.closing = true; return $0.fd
        }
        if let closeFD { closeOriginal(closeFD) }
    }
    private func releaseCall() {
        let closeFD: Int32? = state.withLock {
            $0.calls -= 1
            guard !$0.valid, $0.calls == 0, $0.fd >= 0, !$0.closing else { return nil }
            $0.closing = true; return $0.fd
        }
        if let closeFD { closeOriginal(closeFD) }
    }
    private func closeOriginal(_ fd: Int32) {
        let result = Darwin.close(fd)
        let closeFailure: LocalServiceError? = result == 0 ? nil : .systemCall(errno)
        let outcome = state.withLock { value -> ([CheckedContinuation<LocalServiceError?, Never>], LocalServiceError?) in
            value.fd = -1; value.closing = false
            value.failure = value.failure ?? closeFailure
            let pending = value.drained; value.drained.removeAll(); return (pending, value.failure)
        }
        for waiter in outcome.0 { waiter.resume(returning: outcome.1) }
    }
    // Negative-only observation of an already recorded original native fault.
    // nil is not a new validity/permission witness.
    func recordedFailure() -> LocalServiceError? { state.withLock { $0.failure } }
    func releaseOwner() {
        let original = state.withLock { value -> LocalServiceOwner? in
            let original = value.owner; value.owner = nil; return original
        }
        withExtendedLifetime(original) {}
    }
    func drain() async -> LocalServiceError? {
        invalidate()
        return await withCheckedContinuation { continuation in
            let result: (Bool, LocalServiceError?) = state.withLock { value in
                if value.fd < 0 && !value.closing { return (true, value.failure) }
                value.drained.append(continuation); return (false, nil)
            }
            if result.0 { continuation.resume(returning: result.1) }
        }
    }
    deinit { invalidate() }
}
#endif

public final class LocalServicePeer: Sendable {
    public let policyKey: String
    public let displayIdentifier: String
    #if os(macOS)
    private let proof: NativePeerProof
    init(proof: NativePeerProof) {
        self.proof = proof; policyKey = proof.policyKey; displayIdentifier = proof.displayIdentifier
    }
    #else
    private init() throws { throw LocalServiceError.unsupportedPlatform }
    #endif
    public func revalidate() throws {
        #if os(macOS)
        try proof.revalidate()
        #else
        throw LocalServiceError.unsupportedPlatform
        #endif
    }
}
