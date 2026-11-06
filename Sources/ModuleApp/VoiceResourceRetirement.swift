import Foundation

/// Internal service facts, never SDK grants or decodable caller assertions.
enum VoiceResourceFamily: String, CaseIterable, Sendable {
    case dictation, recognition, output, meetings, files, editing, clients
    case foundationModels = "foundation-models"
    case uiAndHotkeys = "ui-and-hotkeys"
}
enum VoiceOperationOutcome: Sendable { case succeeded, cancelled, failed, effectUncertain }
enum VoiceResourceRelease: Sendable {
    case released(VoiceOperationOutcome)
    case unknown(String)
    var isReleased: Bool { if case .released = self { return true }; return false }
}
enum VoiceActivityOwner: Hashable, Sendable {
    case localUser
    // IDs are created by the native admitted context, never accepted as a role
    // or owner supplied by an untrusted payload.
    case client(connection: UUID, run: UUID?)
}

/// Only this file can construct a clean witness. A copied witness cannot reopen
/// its permanently sealed registry or authorize work in another epoch.
struct VoiceResourceCleanWitness: Sendable {
    let epochID: UUID
    let releasedFamilies: [String]
    fileprivate init(epochID: UUID, releasedFamilies: [String]) {
        self.epochID = epochID; self.releasedFamilies = releasedFamilies
    }
}
struct VoiceResourceDrainReport: Sendable {
    let outcomes: [String: VoiceResourceRelease]
    let cleanWitness: VoiceResourceCleanWitness?
    var fullyReleased: Bool { outcomes.count == VoiceResourceFamily.allCases.count && outcomes.values.allSatisfy(\.isReleased) }
}

/// The actual runtime supplies one controller for EVERY known family before it
/// admits effects. A controller must capture/stop/join actual original owners and
/// return an explicit family result; a settled arbitrary Task is not inferred to
/// mean released. Missing/unknown controllers cannot mint a clean witness.
@MainActor final class VoiceResourceRegistry {
    typealias Controller = @MainActor (VoiceActivityOwner?) async -> VoiceResourceRelease
    private let epochID: UUID
    private var controllers: [VoiceResourceFamily: Controller] = [:]
    private var originals: [UUID: Task<VoiceResourceDrainReport, Never>] = [:]
    private(set) var admissionClosed = false
    private var shutdown: Task<VoiceResourceDrainReport, Never>?
    init(epochID: UUID) { self.epochID = epochID }
    func register(_ family: VoiceResourceFamily, controller: @escaping Controller) throws {
        guard !admissionClosed, controllers[family] == nil else { throw VoiceServiceProblem.resourceRegistry }
        controllers[family] = controller
    }
    func requireAdmission() throws {
        guard !admissionClosed, controllers.count == VoiceResourceFamily.allCases.count else {
            throw VoiceServiceProblem.resourceRegistry
        }
    }
    func retire(owner: VoiceActivityOwner) -> Task<VoiceResourceDrainReport, Never> {
        if let shutdown { return shutdown }
        let id = UUID(), captured = controllers
        let original = Task { @MainActor [weak self] in
            var outcomes: [String: VoiceResourceRelease] = [:]
            for family in VoiceResourceFamily.allCases {
                outcomes[family.rawValue] = await captured[family]?(owner) ?? .unknown("missing-controller")
            }
            let report = VoiceResourceDrainReport(outcomes: outcomes, cleanWitness: nil)
            self?.originals[id] = nil
            return report
        }
        originals[id] = original // Before any asynchronous controller callout.
        return original
    }
    func closeAndDrain() -> Task<VoiceResourceDrainReport, Never> {
        if let shutdown { return shutdown }
        // Permanent seal before callbacks/await. The original snapshot excludes
        // this new shutdown owner, preventing a self-await/dependency cycle.
        admissionClosed = true
        let captured = controllers, previous = Array(originals.values), epoch = epochID
        let original = Task { @MainActor in
            for pending in previous { _ = await pending.value }
            var outcomes: [String: VoiceResourceRelease] = [:]
            for family in VoiceResourceFamily.allCases {
                outcomes[family.rawValue] = await captured[family]?(nil) ?? .unknown("missing-controller")
            }
            let released = outcomes.count == VoiceResourceFamily.allCases.count && outcomes.values.allSatisfy(\.isReleased)
            let witness = released ? VoiceResourceCleanWitness(epochID: epoch, releasedFamilies: outcomes.keys.sorted()) : nil
            return VoiceResourceDrainReport(outcomes: outcomes, cleanWitness: witness)
        }
        shutdown = original
        return original
    }
}
