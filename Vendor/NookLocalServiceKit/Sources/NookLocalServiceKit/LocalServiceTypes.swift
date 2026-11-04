import Foundation
import NookPluginSDK

public enum LocalServiceError: Error, Equatable, Sendable {
    case unsupportedPlatform, invalidPolicy, unsafeRoot, ownerPresent
    case selfRejected, peerRejected, changedIdentity, disconnected
    case capacity, concurrentReceive, concurrentAccept, protocolViolation
    case systemCall(Int32)
}

public struct LocalServicePolicy: Sendable {
    let serviceIdentifier: String
    let trustedSelfRequirements: [String: String]
    let trustedPeerRequirements: [String: String]

    public init(serviceIdentifier: String, trustedSelfRequirements: [String: String],
                trustedPeerRequirements: [String: String]) throws {
        let parts = serviceIdentifier.split(separator: ".", omittingEmptySubsequences: false)
        func lower(_ c: UInt8) -> Bool { (97...122).contains(c) }
        func digit(_ c: UInt8) -> Bool { (48...57).contains(c) }
        guard serviceIdentifier.utf8.count <= 100, parts.count >= 2,
              parts.enumerated().allSatisfy({ index, part in
                  let bytes = Array(part.utf8)
                  return bytes.first.map(lower) == true && bytes.allSatisfy {
                      lower($0) || digit($0) || (index > 0 && $0 == 45)
                  }
              }) else { throw LocalServiceError.invalidPolicy }
        func mapValid(_ values: [String: String]) -> Bool {
            (1...8).contains(values.count) && values.allSatisfy { key, value in
                (1...64).contains(key.utf8.count) && key.utf8.allSatisfy {
                    lower($0) || (65...90).contains($0) || digit($0) || $0 == 45
                } && (1...4096).contains(value.utf8.count) && !value.utf8.contains(0)
            }
        }
        guard mapValid(trustedSelfRequirements), mapValid(trustedPeerRequirements),
              serviceIdentifier.utf8.count + trustedSelfRequirements.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count })
              + trustedPeerRequirements.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 65_536 else {
            throw LocalServiceError.invalidPolicy
        }
        // Native strings have no serialized policy API: the cap is exactly the
        // sum of UTF8 service/key/requirement bytes checked above.
        self.serviceIdentifier = serviceIdentifier
        self.trustedSelfRequirements = trustedSelfRequirements
        self.trustedPeerRequirements = trustedPeerRequirements
    }
}

public enum LocalServiceIOStatus: Sendable { case closed, failed }
public struct LocalServiceIOCompletion: Sendable {
    public let status: LocalServiceIOStatus
    public let failure: LocalServiceError?
    init(_ failure: LocalServiceError?) {
        self.failure = failure; status = failure == nil ? .closed : .failed
    }
}

// The sole unchecked implementation primitive. Every mutable native handle,
// reservation, queue and continuation is accessed only inside withLock. Native
// calls, continuation delivery, blocking waits and user-visible effects occur
// after leaving it. Generic state never escapes except explicit immutable copies.
final class LockedState<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: State
    init(_ value: State) { self.value = value }
    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}
