import Foundation
import Darwin
import NookLocalServiceKit

/// Native composition only. Existing lineages never fall back to enrollment.
enum VoiceServiceEnrollmentPlan: Sendable {
    case existing
    case normal
    case freshIsolated(parent: URL)
}

struct VoiceServicePreparedStart: Sendable {
    let owner: LocalServiceOwner
    let policy: VoiceServicePolicy
    let ledger: VoiceLifecycleLedger
    let epoch: UUID
    let isolated: Bool
    let provision: VoiceIsolatedProvision?

    func revalidateProductRoot() throws {
        try owner.revalidate()
        if isolated {
            guard let provision else { throw VoiceLifecycleFailure.invalidBinding }
            try provision.revalidate()
        }
    }
}

/// Failure retains the original owner and ledger until bootstrap has inspected
/// their actual return. An active record is never changed to clean here.
struct VoiceServiceStartupFailure: @unchecked Sendable {
    let error: Error
    let owner: LocalServiceOwner?
    let ledger: VoiceLifecycleLedger?
    let provision: VoiceIsolatedProvision?
    let cleanupIssue: String?
}

enum VoiceServiceStartupOutcome: Sendable {
    case enrollmentRequired(VoiceNormalEnrollment)
    case ready(VoiceServicePreparedStart)
    case failed(VoiceServiceStartupFailure)
}

enum VoiceServiceStartup {
    /// All native ownership/root opens and initial filesystem publication run
    /// off MainActor. Cancellation joins this exact original, including failure
    /// cleanup, before any caller can construct the real product runtime.
    static func prepare(plan: VoiceServiceEnrollmentPlan,
                        policy: @escaping @Sendable () throws -> VoiceServicePolicy) async -> VoiceServiceStartupOutcome {
        guard !Task.isCancelled else {
            return .failed(.init(error: CancellationError(), owner: nil, ledger: nil,
                                 provision: nil, cleanupIssue: nil))
        }
        let original = Task.detached(priority: .userInitiated) { () -> VoiceServiceStartupOutcome in
            var owner: LocalServiceOwner?
            var ledger: VoiceLifecycleLedger?
            var provision: VoiceIsolatedProvision?
            var normalOpportunity:VoiceNormalEnrollment?
            do {
                try Task.checkCancellation()
                var selected = try policy()
                try Task.checkCancellation()
                let actual = try LocalServiceOwner.acquire(policy: selected.native)
                owner = actual
                try Task.checkCancellation()
                let binding = VoiceLifecycleBinding(serviceIdentifier: selected.serviceIdentifier,
                    buildIdentifier: selected.buildIdentifier, bootSessionUUID: try bootSession(),
                    ownPolicyKey: actual.ownPolicyKey)
                let epoch: UUID
                let isolated: Bool
                switch plan {
                case .existing, .normal:
                    isolated = false
                    if case .normal = plan, let enrollment = try VoiceNormalEnrollment.inspect(policy: selected, owner: actual, binding: binding) {
                        normalOpportunity=enrollment
                        try Task.checkCancellation()
                        return .enrollmentRequired(enrollment)
                    }
                    let opened = try VoiceLifecycleLedger(root: selected.lifecycleRoot,
                                                         owner: actual, binding: binding)
                    ledger = opened
                    epoch = try await opened.begin()
                case .freshIsolated(let parent):
                    isolated = true
                    // Global effects cannot be enabled by an isolated lineage.
                    guard !selected.permitsGlobalControls else { throw VoiceLifecycleFailure.invalidBinding }
                    let created = try await VoiceIsolatedProvision.create(parent: parent, owner: actual, binding: binding)
                    provision = created
                    try Task.checkCancellation()
                    selected = try selected.replacingLifecycleRoot(created.root)
                    let opened = try VoiceLifecycleLedger(root: created.root, owner: actual, binding: binding)
                    ledger = opened
                    epoch = try await opened.beginIsolatedGenesis(created)
                }
                try Task.checkCancellation()
                try actual.revalidate()
                guard let opened = ledger else { throw VoiceLifecycleFailure.invalidBinding }
                return .ready(.init(owner: actual, policy: selected, ledger: opened,
                    epoch: epoch, isolated: isolated, provision: provision))
            } catch {
                // Creation/root-open can fail before assignment to our local
                // variable. Preserve its original cleanup error even when no
                // capability or ledger was returned to this caller.
                var issue = cleanupIssue(error)
                if let ledger {
                    let returned = await ledger.retireStartupHandles()
                    if issue == nil { issue = returned }
                } else if let normalOpportunity {
                    do { try normalOpportunity.closeAfterConsumption() }
                    catch { if issue == nil { issue = "normal-opportunity-close-failed: \(error)" } }
                } else if let provision {
                    do { try provision.closeOriginals() }
                    catch { if issue == nil { issue = "isolated-provision-close-failed: \(error)" } }
                }
                return .failed(.init(error: error, owner: owner, ledger: ledger,
                                     provision: provision, cleanupIssue: issue))
            }
        }
        return await withTaskCancellationHandler { await original.value }
            onCancel: { original.cancel() }
    }

    /// Continues the SAME retained native owner only after native confirmation.
    /// Cancellation joins physical creation/publication; failed artifacts remain.
    static func enroll(_ opportunity: VoiceNormalEnrollment,
                       checkpoint: (@Sendable () -> Void)? = nil) async -> VoiceServiceStartupOutcome {
        let cancelledAtAdmission=Task.isCancelled
        let original=Task.detached(priority:.userInitiated) { () -> VoiceServiceStartupOutcome in
            var ledger:VoiceLifecycleLedger?
            do {
                if cancelledAtAdmission{throw CancellationError()}
                try Task.checkCancellation();try opportunity.owner.revalidate()
                try opportunity.createOriginal(checkpoint:checkpoint)
                let opened=try VoiceLifecycleLedger(root:opportunity.root,owner:opportunity.owner,binding:opportunity.binding)
                ledger=opened
                let epoch=try await opened.beginNormalGenesis(opportunity)
                try Task.checkCancellation();try opportunity.owner.revalidate()
                return .ready(.init(owner:opportunity.owner,policy:opportunity.policy,ledger:opened,
                    epoch:epoch,isolated:false,provision:nil))
            } catch {
                var issue=cleanupIssue(error)
                if let ledger {let returned=await ledger.retireStartupHandles();issue=issue ?? returned}
                else {do{try opportunity.closeAfterConsumption()}catch{issue=issue ?? "normal-enrollment-original-close-failed: \(error)"}}
                return .failed(.init(error:error,owner:opportunity.owner,ledger:ledger,provision:nil,cleanupIssue:issue))
            }
        }
        return await withTaskCancellationHandler {await original.value} onCancel:{original.cancel()}
    }

    static func cleanupIssue(_ error: Error) -> String? {
        guard let failure = error as? VoiceProvisionCleanupFailure else { return nil }
        if !failure.closeErrors.isEmpty {
            return "isolated-startup-original-close-failed: " + failure.closeErrors.map(String.init).joined(separator: ",")
        }
        return cleanupIssue(failure.original)
    }

    private static func bootSession() throws -> UUID {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1, size <= 128 else { throw VoiceServiceProblem.unavailable }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
              let value = UUID(uuidString: String(cString: bytes)) else { throw VoiceServiceProblem.unavailable }
        return value
    }
}
