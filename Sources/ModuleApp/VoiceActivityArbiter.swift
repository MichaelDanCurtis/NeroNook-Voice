import Foundation

enum VoiceServiceProblem: Error, LocalizedError, Sendable {
    case unavailable, busy, resourceRegistry, staleContext, protocolViolation, recoveryRequired
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The shared Voice service is unavailable."
        case .busy: return "Voice is in use. Finish its current activity first."
        case .resourceRegistry: return "Voice resource ownership is incomplete; new activity is blocked."
        case .staleContext: return "This Voice connection has ended."
        case .protocolViolation: return "The Voice connection sent an invalid message."
        case .recoveryRequired: return "Voice needs recovery before it can start."
        }
    }
}
struct VoiceActivityLease: Hashable, Sendable {
    let id: UUID
    let owner: VoiceActivityOwner
    let epoch: UUID
    fileprivate init(owner: VoiceActivityOwner, epoch: UUID) { id = UUID(); self.owner = owner; self.epoch = epoch }
}

/// One process-wide physical activity owner. Native eligibility/consent is
/// checked by the context before reaching this class; this is not a grant API.
@MainActor final class VoiceActivityArbiter {
    private let epoch: UUID
    private let resources: VoiceResourceRegistry
    private(set) var current: VoiceActivityLease?
    private var retirement: Task<VoiceResourceDrainReport, Never>?
    private var closing = false
    private var uncertain = false
    var changed: (() -> Void)?
    init(epoch: UUID, resources: VoiceResourceRegistry) { self.epoch = epoch; self.resources = resources }
    var busy: Bool { current != nil || retirement != nil || uncertain || closing }
    func reserve(owner: VoiceActivityOwner) throws -> VoiceActivityLease {
        try resources.requireAdmission()
        guard !busy else { throw VoiceServiceProblem.busy }
        let lease = VoiceActivityLease(owner: owner, epoch: epoch)
        current = lease // Reserve before a reentrant status callback.
        changed?()
        guard current == lease, retirement == nil, !closing else { throw VoiceServiceProblem.staleContext }
        return lease
    }
    func requireCurrent(_ lease: VoiceActivityLease) throws {
        guard !closing, !uncertain, retirement == nil, current == lease, lease.epoch == epoch else { throw VoiceServiceProblem.staleContext }
    }
    func retire(_ lease: VoiceActivityLease) -> Task<VoiceResourceDrainReport, Never>? {
        guard !closing, current == lease else { return nil }
        if let retirement { return retirement }
        let original = resources.retire(owner: lease.owner)
        // Keep the same actual original family owner through all callbacks.
        retirement = original
        Task { @MainActor [weak self] in
            let report = await original.value
            guard let self, self.current == lease else { return }
            self.retirement = nil
            if report.fullyReleased { self.current = nil } else { self.uncertain = true }
            self.changed?()
        }
        return original
    }
    func beginShutdown() -> Task<VoiceResourceDrainReport, Never> {
        closing = true
        let original = resources.closeAndDrain()
        changed?()
        return original
    }
}
