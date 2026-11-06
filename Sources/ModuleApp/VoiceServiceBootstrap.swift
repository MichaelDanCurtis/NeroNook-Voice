import AppKit
import Combine
import Foundation
import Darwin
import VoiceAudio
import NookLocalServiceKit

/// A lightweight entry object. No Voice model, store, device or shortcut is
/// constructed in the selected shared lane until native+durable admission.
@MainActor final class VoiceServiceBootstrap: ObservableObject {
    @Published private(set) var status = "Starting Nero Voice…"
    @Published private(set) var legacy: VoicePlugin?
    @Published private(set) var runtime: VoiceServiceRuntime?
    private var originalStart: Task<Void, Never>?
    private var retainedOwner: LocalServiceOwner?
    private var ledger: VoiceLifecycleLedger?
    private var retiring = false
    /// Immutable selection made by native source composition, never an env or
    /// peer flag. The normal application keeps its existing selected behavior.
    let isolatedComposition: Bool
    private var startupFailure: VoiceServiceStartupFailure?
    private var startupRetirementIssue: String?
    @Published private(set) var enrollmentAvailable = false
    private var normalOpportunity:VoiceNormalEnrollment?
    private var enrollmentGeneration=UUID()
    private var enrollmentInFlight=false
    private var enrollmentOriginals:[Task<Void,Never>]=[]
    private var enrollmentPrompt:(any VoiceNormalEnrollmentPrompt)?
    private var normalPromptFactory:@MainActor ()->any VoiceNormalEnrollmentPrompt = {VoiceNativeEnrollmentPrompt()}
    private var beforeMaterialization:(@MainActor (VoiceServicePreparedStart) async->Void)?

    static func usesPlaceholderAppearance(legacyAvailable:Bool,runtimeIsolated:Bool?)->Bool {
        if let runtimeIsolated{return runtimeIsolated}
        return !legacyAvailable
    }
    var usesPlaceholderAppearance:Bool {
        Self.usesPlaceholderAppearance(legacyAvailable:legacy != nil,runtimeIsolated:runtime?.plugin.configuration.isolated)
    }
    /// Actual originals only, for fixture observation without polling/default resources.
    var startupCompletion:Task<Void,Never>?{originalStart}
    var enrollmentCompletion:Task<Void,Never>?{enrollmentOriginals.last}
    var retirementRequested:Bool{retiring}
    var canEnroll:Bool{!retiring && enrollmentAvailable}


    init(bundle: Bundle = .main) {
        isolatedComposition = false
        let kind = bundle.object(forInfoDictionaryKey: "NeroVoiceRuntimeKind") as? String
        if kind == nil {
            legacy = VoicePlugin(); status = "Nero Voice"; return
        }
        guard kind == "shared-service-v1" else {
            status = "Unknown Voice runtime kind. No resources have started."; return
        }
        // Metadata preflight preserves immediate refusal without running native
        // ownership, resource hashing or root opens on MainActor.
        guard bundle.bundleIdentifier == "cafe.nero.plugin.voice" else {
            status = "Shared Voice could not verify native ownership. No microphone, model or library has started."
            return
        }
        start(plan: .normal) { try VoiceServicePolicy.operational(bundle: bundle) }
    }

    /// Internal native-policy fixture composition; no UI/default profile is
    /// touched unless the retained startup reaches real durable admission.
    init(normalPolicy:VoiceServicePolicy,
         prompt:@escaping @MainActor ()->any VoiceNormalEnrollmentPrompt,
         beforeMaterialization:(@MainActor (VoiceServicePreparedStart) async->Void)? = nil) {
        isolatedComposition=false
        normalPromptFactory=prompt;self.beforeMaterialization=beforeMaterialization
        start(plan:.normal){normalPolicy}
    }

    /// Explicit native first-pair composition. Production selection never falls
    /// back here when an existing ledger is missing or needs recovery.
    init(isolatedPolicy: VoiceServicePolicy, parent: URL) {
        isolatedComposition = true
        guard !isolatedPolicy.permitsGlobalControls else {
            status = "Isolated Voice cannot enable global controls. No resources have started."
            return
        }
        start(plan: .freshIsolated(parent: parent)) { isolatedPolicy }
    }

    /// A separately compiled native entry supplies this trusted factory. Its
    /// resource hashing and policy checks run inside the retained original
    /// startup task, before the real full product can be constructed.
    init(isolatedParent: URL,
         policy: @escaping @Sendable () throws -> VoiceServicePolicy) {
        isolatedComposition = true
        start(plan: .freshIsolated(parent: isolatedParent)) {
            let selected = try policy()
            guard !selected.permitsGlobalControls else { throw VoiceLifecycleFailure.invalidBinding }
            return selected
        }
    }

    /// Internal original-work injection for lifecycle fixtures. No policy,
    /// model, profile or observer is constructed; shutdown joins this actual
    /// retained task through the same production path as real startup.
    init(retainedStartup: Task<Void, Never>) {
        isolatedComposition = true
        originalStart = retainedStartup
    }

    /// A genuine already-constructed legacy product can use the same binding
    /// route without making nil mean legacy. Fixtures supply the existing
    /// isolated full product, never a default user-profile plugin.
    init(legacyPlugin: VoicePlugin) {
        isolatedComposition = false
        legacy = legacyPlugin
        status = "Nero Voice"
    }

    private func start(plan: VoiceServiceEnrollmentPlan,
                       policy: @escaping @Sendable () throws -> VoiceServicePolicy) {
        originalStart=Task{@MainActor[self] in
            await receiveStartup(await VoiceServiceStartup.prepare(plan:plan,policy:policy))
        }
    }
    private func receiveStartup(_ result:VoiceServiceStartupOutcome) async {
        switch result {
        case .enrollmentRequired(let opportunity):
            normalOpportunity=opportunity;retainedOwner=opportunity.owner
            if !retiring {
                status="Set up shared Voice for this Mac. No recording or model has started."
                if !retiring{enrollmentAvailable=true}
            }

        case .failed(let failure):
            enrollmentAvailable=false
            startupFailure = failure
            retainedOwner = failure.owner
            ledger = failure.ledger
            startupRetirementIssue = failure.cleanupIssue
            status = "Shared Voice is unavailable or needs recovery. The current Voice app has not been replaced."
        case .ready(let prepared):
            retainedOwner = prepared.owner
            ledger = prepared.ledger
            do {
                try Task.checkCancellation()
                try prepared.owner.revalidate()
                guard !retiring else { throw CancellationError() }
                // The real full product is constructed only after the
                // durable active epoch and uses its isolated physical root.
                await beforeMaterialization?(prepared)
                try Task.checkCancellation();try prepared.owner.revalidate()
                guard !retiring else{throw CancellationError()}
                let product: VoiceProductConfiguration
                if prepared.isolated {
                    product = try .isolated(root: prepared.policy.lifecycleRoot.appendingPathComponent("Product", isDirectory: true),
                        revalidate: { try prepared.revalidateProductRoot() })
                } else { product = .legacy }
                try Task.checkCancellation()
                try prepared.owner.revalidate()
                guard !retiring else { throw CancellationError() }
                let current = try VoiceServiceRuntime(owner: prepared.owner, policy: prepared.policy,
                    ledger: prepared.ledger, epochID: prepared.epoch, productConfiguration: product)
                runtime = current
                // Published runtime observers can synchronously request
                // Stop. Do not open a listener after that publication.
                try Task.checkCancellation()
                try prepared.owner.revalidate()
                guard !retiring else { throw CancellationError() }
                try current.start()
                status = "Voice service is available · no recording started"
            } catch {
                // A constructed runtime owns its real drain. Only a failed
                // pre-runtime startup may retire the startup handles here.
                if runtime == nil {
                    let originalIssue = VoiceServiceStartup.cleanupIssue(error)
                    let returned = await prepared.ledger.retireStartupHandles()
                    startupRetirementIssue = startupRetirementIssue ?? originalIssue ?? returned
                }
                status = "Shared Voice is unavailable or needs recovery. The current Voice app has not been replaced."
            }
        }
    }

    /// The actual startup button is the sole production caller. Reserve original
    /// confirmation/creation work before published state or native callouts.
    func requestNormalEnrollment(from parent: VoiceEnrollmentWindowAnchor.Snapshot? = nil) {
        guard !isolatedComposition,!retiring,!enrollmentInFlight,enrollmentAvailable,
              let opportunity=normalOpportunity,enrollmentOriginals.count<32 else{return}
        guard let parent, parent.isCurrent else {
            status="The setup window is unavailable. Reopen Nero Voice and try again."
            return
        }
        enrollmentInFlight=true
        let generation=enrollmentGeneration,prior=originalStart
        let original=Task{@MainActor[self,opportunity] in
            await prior?.value
            guard !retiring,enrollmentGeneration==generation,normalOpportunity === opportunity, parent.isCurrent else{return}
            let prompt=normalPromptFactory();enrollmentPrompt=prompt
            guard !retiring,!Task.isCancelled,enrollmentGeneration==generation else{prompt.cancel();return}
            let accepted=await prompt.confirm(opportunity, parent: parent)
            enrollmentPrompt=nil // The exact native callback and response task have joined.
            guard !retiring,!Task.isCancelled,enrollmentGeneration==generation,normalOpportunity === opportunity, parent.isCurrent else{return}
            guard accepted else{status="Setup cancelled. No service history was created.";return}
            // Keep the exact opportunity/owner through physical creation and all
            // original writer/close returns. Never reacquire a different owner.
            await receiveStartup(await VoiceServiceStartup.enroll(opportunity))
            normalOpportunity=nil
        }
        enrollmentOriginals.append(original)
        let returned=Task{@MainActor[self,opportunity] in
            await original.value
            guard !retiring,enrollmentGeneration==generation else{return}
            enrollmentInFlight=false
            if normalOpportunity === opportunity {
                enrollmentAvailable=enrollmentOriginals.count<32
            }
        }
        enrollmentOriginals.append(returned)
        enrollmentAvailable=false
    }
    func shutdown() async -> Bool {
        if retiring { return false }
        retiring = true
        enrollmentGeneration=UUID();enrollmentAvailable=false
        originalStart?.cancel()
        let originals=enrollmentOriginals
        originals.forEach{$0.cancel()};enrollmentPrompt?.cancel()
        await originalStart?.value
        for original in originals{await original.value}
        enrollmentPrompt=nil // Its original confirm/native callback has joined.
        if let normalOpportunity {
            do{try normalOpportunity.closeAfterConsumption()}
            catch{startupRetirementIssue=startupRetirementIssue ?? "normal-enrollment-close-failed: \(error)"}
        }
        if let runtime {
            let clean = await runtime.shutdown()
            if clean { self.runtime = nil; self.ledger = nil; retainedOwner = nil }
            else { status = "Voice is still draining or requires recovery. Its owner remains held." }
            return clean
        }
        // Startup failure is not fabricated clean state. No runtime exists, but
        // any active/unknown durable marker remains for supported recovery.
        if let ledger { await ledger.pendingWriteCompletion()?.value }
        guard startupRetirementIssue == nil else {
            status = "Voice startup resources need recovery. Its original owner remains held."
            return false
        }
        startupFailure = nil
        normalOpportunity=nil
        self.ledger = nil
        retainedOwner = nil
        return true
    }

}

/// Global Quit has a real asynchronous owner. willTerminate/deinit are too late
/// to certify resource return or commit clean on behalf of the selected service.
@MainActor final class VoiceServiceAppDelegate: NSObject, NSApplicationDelegate {
    private var boundBootstrap: VoiceServiceBootstrap?
    private var pendingSender: NSApplication?
    private var quitPending = false
    private var originalTermination: Task<Void, Never>?
    private let shutdownOriginal: @MainActor (VoiceServiceBootstrap) async -> Bool
    private let replyOriginal: @MainActor (NSApplication, Bool) -> Void

    /// First binding owns Quit permanently. Later view deliveries, nil or a
    /// replacement cannot retarget an already admitted termination.
    var bootstrap: VoiceServiceBootstrap? {
        get { boundBootstrap }
        set {
            guard let newValue, boundBootstrap == nil else { return }
            boundBootstrap = newValue
            resumePendingTermination()
        }
    }
    /// The actual retained task, exposed read-only for owned-tail fixtures.
    var terminationCompletion: Task<Void, Never>? { originalTermination }

    override init() {
        shutdownOriginal = { await $0.shutdown() }
        replyOriginal = { $0.reply(toApplicationShouldTerminate: $1) }
        super.init()
    }
    init(shutdown: @escaping @MainActor (VoiceServiceBootstrap) async -> Bool = { await $0.shutdown() },
         reply: @escaping @MainActor (NSApplication, Bool) -> Void) {
        shutdownOriginal = shutdown
        replyOriginal = reply
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitPending, originalTermination == nil else { return .terminateCancel }
        if let bootstrap = boundBootstrap, bootstrap.legacy != nil { return .terminateNow }
        // Nil is pending ownership, never proof that this is the legacy app.
        // Reserve the original sender before any future binding/callout.
        quitPending = true
        pendingSender = sender
        resumePendingTermination()
        return .terminateLater
    }

    private func resumePendingTermination() {
        guard originalTermination == nil, let sender = pendingSender,
              let originalBootstrap = boundBootstrap else { return }
        let shutdown = shutdownOriginal, reply = replyOriginal
        let legacy = originalBootstrap.legacy != nil
        originalTermination = Task { @MainActor [self, originalBootstrap, sender] in
            let clean = legacy ? true : await shutdown(originalBootstrap)
            // Keep original sender, bootstrap and pending state through this
            // synchronous callout. Reentrant Quit cannot start another drain.
            reply(sender, clean)
            pendingSender = nil
            quitPending = false
            // Retain the completed original. A false drain is a conservative
            // hold; bootstrap.retiring is intentionally never reset/retried.
        }
    }
}
