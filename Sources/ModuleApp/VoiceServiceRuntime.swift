import AppKit
import Combine
import Foundation
import NookPluginSDK
import VoiceAudio
import ModuleCore
import NookLocalServiceKit

/// The sole model/store/hotkey universe, constructed only after native ownership
/// and a durable active epoch. A Nook connection is a client, not this lifetime.
@MainActor final class VoiceServiceRuntime {
    let owner: LocalServiceOwner
    let policy: VoiceServicePolicy
    let plugin: VoicePlugin
    let approval = VoiceServiceApproval()
    let capabilities = [PluginSpeechConversation.action, PluginSpeechContract.speak]
    private let ledger: VoiceLifecycleLedger
    private let instance = UUID()
    private let resources: VoiceResourceRegistry
    private let activity: VoiceActivityArbiter
    private var listener: LocalServiceListener?
    private var originalAccept: Task<Void, Never>?
    private var contexts: [UUID: VoiceClientContext] = [:]
    private let contextAdmission=VoiceContextAdmission()
    private var quarantinedContexts:[UUID:VoiceClientContext]=[:]
    private var fullContext: VoiceClientContext?
    private var uncertainFull: VoiceClientContext?
    private var closing = false
    private var dispatchOwner: VoiceActivityOwner?
    private var uiLease: VoiceActivityLease?
    private var runs: [UUID: Run] = [:] // Service-private provider ID, not client input.
    private var providers:[UUID:ProviderRecord]=[:]
    private var touched: [VoiceActivityOwner: Set<VoiceResourceFamily>] = [:]
    private var foundationOwners: [VoiceActivityOwner: VoiceFoundationOwner] = [:]
    private var retirementTasks: [UUID: Task<Bool, Never>] = [:]
    private var nativeEffectsEverStarted = false
    private var originalShutdown: Task<Bool, Never>?
    private var originalPresentationRetirement: Task<Bool, Never>?
    // First failure from an actual rejected connection or listener return.
    // Keep the original runtime/listener/owner on uncertainty.
    private var nativeReturnFailure: LocalServiceError?
    private func recordNativeReturn(_ failure: LocalServiceError?) {
        if nativeReturnFailure == nil { nativeReturnFailure = failure }
    }

    private final class Run {
        let original: UUID
        let provider: UUID
        let context: VoiceClientContext
        let definition: PluginRegisteredAction
        let lease: VoiceActivityLease
        let budget:VoiceClientRunBudget.Reservation
        var cancelled = false
        var terminal: PluginSharedRunOutcome?
        var retiring: Task<Bool, Never>?
        init(original: UUID, provider: UUID, context: VoiceClientContext,
             definition: PluginRegisteredAction, lease: VoiceActivityLease,budget:VoiceClientRunBudget.Reservation) {
            self.budget=budget
            self.original = original; self.provider = provider; self.context = context
            self.definition = definition; self.lease = lease
        }
    }
    private struct ProviderRecord{
        let source:VoiceProviderSource
        let generation:UUID
        let context:VoiceClientContext
        let activityOwner:VoiceActivityOwner
        let foundationOwner:VoiceFoundationOwner
        let budget:VoiceClientRunBudget.Reservation
        let handle:VoiceOwnedProviderRequest
    }
    init(owner: LocalServiceOwner, policy: VoiceServicePolicy, ledger: VoiceLifecycleLedger, epochID: UUID, productConfiguration suppliedConfiguration:VoiceProductConfiguration? = nil) throws {
        let productConfiguration = suppliedConfiguration ?? .legacy
        try productConfiguration.validateData()
        try owner.revalidate()
        try productConfiguration.appearance.prepareSharedService(
            observation: productConfiguration.isolated || !productConfiguration.allows(.observation)
                ? .hostDelivered : .system)
        self.owner = owner; self.policy = policy; self.ledger = ledger
        let registry = VoiceResourceRegistry(epochID: epochID)
        resources = registry; activity = VoiceActivityArbiter(epoch: epochID, resources: registry)
        // This is deliberately after the durable begin() in the real bootstrap.
        plugin = VoicePlugin(sharedService: true, permitsGlobalControls: policy.permitsGlobalControls,configuration:productConfiguration)
        for family in VoiceResourceFamily.allCases {
            try registry.register(family) { [weak self] owner in
                guard let self else { return .unknown("runtime-owner-lost") }
                return await self.drain(family, owner: owner)
            }
        }
        plugin.sharedBus = { [weak self] in self?.route($0) ?? true }
        plugin.sharedProviderCapture={ [weak self] request, source in self?.reserveProvider(request, source:source) }
        plugin.sharedFailure = { [weak self] in self?.fullContext?.failTransport() }
        plugin.sharedAdmission = { [weak self] message in
            guard let self else { throw VoiceServiceProblem.unavailable }
            try self.admitModuleEffects(message)
        }
        plugin.model.serviceBeginLocal = { [weak self] in
            guard let self else { throw VoiceServiceProblem.unavailable }
            try self.reserveUI(owner: self.dispatchOwner ?? .localUser)
        }
        plugin.meetings.serviceBeginLocal = plugin.model.serviceBeginLocal
        activity.changed = { [weak self] in
            guard let self else { return }
            if case .client(let connection, _) = self.activity.current?.owner,
               self.contexts[connection]?.role == .capabilityClient { self.plugin.sharedPrivateActivity = true }
            else { self.plugin.sharedPrivateActivity = false }
        }
    }
    func start() throws {
        guard listener == nil, !closing else { throw VoiceServiceProblem.unavailable }
        try owner.revalidate(); try resources.requireAdmission()
        let listener = try LocalServiceListener(owner: owner, policy: policy.native)
        self.listener = listener
        originalAccept = Task { [self] in
            do {
                while let native = try await listener.accept() {
                    guard !closing,let admission=contextAdmission.reserve() else {
                        native.stopIO(); let result = await native.retirement()
                        recordNativeReturn(result.failure)
                        continue
                    }
                    do{try owner.revalidate()}catch{
                        native.stopIO();let result=await native.retirement()
                        recordNativeReturn(result.failure)
                        _=contextAdmission.finish(admission,allReturned:result.failure == nil)
                        throw error
                    }
                    let context = VoiceClientContext(native: native, instance: instance, runtime: self,admission:admission)
                    contexts[context.id] = context; context.start()
                }
            } catch {
                listener.stopAccepting()
                for context in Array(contexts.values) { context.failTransport() }
            }
        }
    }
    // Read-only observation of the exact admitted context, keyed by its
    // genuine hello connection ID. Does not construct, admit or approve a peer.
    func contextForRetirementObservation(_ connection: UUID) -> VoiceClientContext? { contexts[connection] }
    func claim(_ context: VoiceClientContext) -> Bool {
        guard !closing, contexts[context.id] === context else { return false }
        if context.role == .moduleAdapter {
            guard fullContext == nil, uncertainFull == nil else { return false }
            fullContext = context
        }
        return true
    }
    func heartbeat(for context:VoiceClientContext){
        guard !closing,fullContext === context,context.approved else{return}
        plugin.emitSharedHeartbeat()
    }
    func approved(_ context: VoiceClientContext) throws {
        try owner.revalidate()
        guard !closing, contexts[context.id] === context, context.approved else { throw VoiceServiceProblem.staleContext }
        if context.role == .moduleAdapter {
            guard fullContext === context else { throw VoiceServiceProblem.staleContext }
            try plugin.beginSharedSession(context)
        }
    }
    func receiveModule(_ original: PluginMessage, from context: VoiceClientContext) throws {
        guard !closing, fullContext === context, context.approved else { throw VoiceServiceProblem.staleContext }
        var message = original
        var cancelledRun: Run?
        if var bus = message.bus {
            if bus.operation == .execute, let address = bus.address {
                let definition: PluginRegisteredAction
                if address.name == PluginSpeechConversation.action.id { definition = PluginSpeechConversation.action }
                else if address.name == PluginSpeechContract.speak.id { definition = PluginSpeechContract.speak }
                else if address.name == MeetingReadContract.search.id { definition = MeetingReadContract.search }
                else if address.name == MeetingReadContract.read.id { definition = MeetingReadContract.read }
                else if address.name == VoiceContract.submit.id { definition = VoiceContract.submit }
                else { throw VoiceServiceProblem.protocolViolation }
                guard address.plugin == policy.moduleIdentifier else { throw VoiceServiceProblem.protocolViolation }
                let run = try reserve(bus.requestID, definition: definition, from: context)
                bus.requestID = run.provider; message.bus = bus
            } else if bus.operation == .cancel || bus.operation == .stream {
                guard let run = runs.values.first(where: { $0.context === context && $0.original == bus.requestID }) else {
                    _ = context.send(.status(.init(code: .unknownRun, run: bus.requestID))); return
                }
                bus.requestID = run.provider; message.bus = bus
                if bus.operation == .cancel { run.cancelled = true; run.terminal = .cancelled; cancelledRun = run }
            }
        }
        let prior = dispatchOwner
        if let bus=message.bus,let run=runs[bus.requestID]{dispatchOwner=run.lease.owner}
        else if let bus=message.bus,let provider=providers[bus.requestID],provider.context === context{dispatchOwner=provider.activityOwner}
        else{dispatchOwner = .client(connection:context.id,run:nil)}
        defer { dispatchOwner = prior }
        let token = foundationOwner(dispatchOwner ?? .localUser)
        try LocalFoundationModelWork.$currentOwner.withValue(token) { try plugin.receiveShared(message) }
        if let cancelledRun { _ = retireRun(cancelledRun) }
    }
    private func admitModuleEffects(_ message: PluginMessage) throws {
        guard !closing else { throw VoiceServiceProblem.staleContext }
        // Full bus work already has a private retained run. Appearance, catalog,
        // updates and the inner handshake are not recording/effect admission.
        if message.type == "viewEvent" || message.type == "action" {
            try reserveUI(owner: dispatchOwner ?? .localUser)
        }
    }
    private func reserveUI(owner: VoiceActivityOwner) throws {
        guard !closing else { throw VoiceServiceProblem.staleContext }
        if let current = activity.current, current.owner == owner { try activity.requireCurrent(current); return }
        if let uiLease, uiLease.owner == owner { try activity.requireCurrent(uiLease); return }
        let lease = try activity.reserve(owner: owner)
        uiLease = lease
        _ = foundationOwner(owner)
        touched[owner] = Set(VoiceResourceFamily.allCases)
        if !plugin.configuration.isolated{nativeEffectsEverStarted = true}
    }
    private func reserve(_ original: UUID, definition: PluginRegisteredAction, from context: VoiceClientContext) throws -> Run {
        guard !closing, context.approved, !context.closing, contexts[context.id] === context else { throw VoiceServiceProblem.staleContext }
        let budget=try context.runBudget.reserve(original,kind:.incoming)
        let lease:VoiceActivityLease
        do{
            lease=try activity.reserve(owner:.client(connection:context.id,run:original))
            guard !context.closing,context.approved else{throw VoiceServiceProblem.staleContext}
        }catch{context.runBudget.release(budget);throw error}
        let run=Run(original:original,provider:UUID(),context:context,definition:definition,lease:lease,budget:budget)
        runs[run.provider] = run
        _ = foundationOwner(lease.owner)
        if definition.id == MeetingReadContract.search.id || definition.id == MeetingReadContract.read.id {
            touched[lease.owner] = [.files]
        } else if definition.id == PluginSpeechConversation.action.id {
            touched[lease.owner] = [.recognition, .output]
            nativeEffectsEverStarted = true
        } else if definition.id == PluginSpeechContract.speak.id {
            touched[lease.owner] = [.output]
            nativeEffectsEverStarted = true
        } else {
            touched[lease.owner] = [.dictation, .output, .editing, .files, .foundationModels]
            nativeEffectsEverStarted = true
        }
        return run
    }
    func invoke(_ original: UUID, definition: PluginRegisteredAction, values: [String: PluginValue], from context: VoiceClientContext) throws {
        guard context.role == .capabilityClient, capabilities.contains(where: { $0 == definition }) else { throw VoiceServiceProblem.protocolViolation }
        if definition.id != MeetingReadContract.search.id && definition.id != MeetingReadContract.read.id {
            try plugin.configuration.require(.capture)
        }
        try plugin.configuration.validateData()
        do {
            let run = try reserve(original, definition: definition, from: context)
            let prior = dispatchOwner; dispatchOwner = run.lease.owner
            defer { dispatchOwner = prior }
            do {
                try LocalFoundationModelWork.$currentOwner.withValue(foundationOwner(run.lease.owner)) {
                    try plugin.sharedSpeech(run.provider, action: definition.id, values: values)
                }
            }
            catch {
                run.terminal = .failed
                _ = context.send(.update(.init(run: original, update: try JSONEncoder().encode(PluginRunUpdate(.failed, message: "Local speech could not start")))))
                _ = retireRun(run)
            }
        } catch VoiceServiceProblem.busy {
            // No worker was admitted; refusal can retire immediately.
            _ = context.send(.status(.init(code: .ownerBusy, run: original)))
            _ = context.send(.retired(.init(run: original, outcome: .refused)))
        }
    }
    func input(_ input: PluginSharedRunFrame, from context: VoiceClientContext) throws {
        guard let run = runs.values.first(where: { $0.context === context && $0.original == input.run }),
              !run.cancelled, run.terminal == nil, let schema = run.definition.streamInput else { throw VoiceServiceProblem.protocolViolation }
        try activity.requireCurrent(run.lease)
        let frame = try JSONDecoder().decode(PluginRunFrame.self, from: input.frame)
        try frame.validate(schema)
        try LocalFoundationModelWork.$currentOwner.withValue(foundationOwner(run.lease.owner)) {
            try plugin.sharedInput(.init(.stream, requestID: run.provider, frame: frame))
        }
    }
    func cancel(_ original: UUID, from context: VoiceClientContext) throws {
        guard let run = runs.values.first(where: { $0.context === context && $0.original == original }) else {
            _ = context.send(.status(.init(code: .unknownRun, run: original))); return
        }
        guard run.definition.cancellable else { _ = context.send(.status(.init(code: .capabilityRefused, run: original))); return }
        if run.cancelled { return }
        run.cancelled = true; run.terminal = .cancelled
        plugin.cancelShared(run.provider)
        _ = retireRun(run)
    }
    private func route(_ bus: PluginBusMessage) -> Bool {
        guard let run = runs[bus.requestID] else { return false }
        if run.cancelled || run.context.closing { return true }
        do {
            if run.context.role == .capabilityClient {
                if bus.operation == .stream, let frame = bus.frame {
                    _ = run.context.send(.runOutput(.init(run: run.original, frame: try JSONEncoder().encode(frame))))
                } else if bus.operation == .update, let update = bus.update {
                    _ = run.context.send(.update(.init(run: run.original, update: try JSONEncoder().encode(update))))
                }
            } else if run.context.session != nil {
                var mapped = bus; mapped.requestID = run.original
                // Preserve the original full-plugin output sequence through its
                // owned VoiceOutput; only remap the private run ID here.
                plugin.emitSharedBus(mapped)
            }
            if let update = bus.update, update.phase.terminal {
                run.terminal = update.phase == .succeeded ? .succeeded : update.phase == .cancelled ? .cancelled : .failed
                _ = retireRun(run)
            }
        } catch { run.context.failTransport() }
        return true
    }
    private func retireRun(_ run: Run) -> Task<Bool, Never> {
        if let retiring = run.retiring { return retiring }
        let original = Task { [self, run] in
            if [MeetingReadContract.search.id,MeetingReadContract.read.id].contains(run.definition.id){
                await plugin.retireMeetingReads([run.provider])
            }else{await plugin.retireSharedRequests([run.provider])}
            let released: Bool
            if closing { released = await drainOwnedWork(run.lease.owner) }
            else if let retirement = activity.retire(run.lease) { released = await retirement.value.fullyReleased }
            else { released = false }
            if released {
                _ = await run.context.send(.retired(.init(run: run.original, outcome: run.terminal ?? .cancelled))).value
                run.context.runBudget.release(run.budget)
                runs[run.provider] = nil; touched[run.lease.owner] = nil; foundationOwners[run.lease.owner] = nil
            } else { _ = run.context.send(.status(.init(code: .draining, run: run.original))) }
            return released
        }
        run.retiring = original
        return original
    }
    private func reserveProvider(_ request:UUID, source:VoiceProviderSource)->VoiceOwnedProviderRequest?{
        guard !closing,let context=fullContext,context.approved,!context.closing,
              let session=context.session,providers[request]==nil else{return nil}
        do{
            let budget=try context.runBudget.reserve(request,kind:.provider)
            let generation=UUID(),capturedOwner=dispatchOwner ?? .localUser
            let capturedFoundation=LocalFoundationModelWork.currentOwner
            guard let handle=plugin.makeProviderRequest(request,session:session,onRetire:{[weak self] in
                self?.releaseProvider(request,generation:generation)
            }) else{context.runBudget.release(budget);return nil}
            do{try context.providerHistory.record(request,source:source)}catch{context.runBudget.release(budget);return nil}
            providers[request]=ProviderRecord(source:source,generation:generation,context:context,activityOwner:capturedOwner,
                foundationOwner:capturedFoundation,budget:budget,handle:handle)
            return handle
        }catch{_=context.send(.status(.init(code:.ownerBusy)));return nil}
    }
    private func releaseProvider(_ request:UUID,generation:UUID){
        guard let original=providers[request],original.generation==generation else{return}
        original.context.runBudget.release(original.budget)
        providers[request]=nil
    }
    func retire(_ context: VoiceClientContext) async -> Bool {
        if let original = retirementTasks[context.id] { return await original.value }
        let original = Task { [self, context] in
            let owned = runs.values.filter { $0.context === context }
            for run in owned { run.cancelled = true; run.terminal = .cancelled; plugin.cancelShared(run.provider) }
            // This retained history includes completed handles already removed
            // from providers. Seal before waiting, then retire/prune each exact
            // original family. Foreign or unresolved IDs cannot be erased.
            var released = await context.providerHistory.retire { [self] source,requests in
                let result:VoiceResourceRelease
                switch source{
                case .meeting:
                    result=await plugin.meetings.retireProviderRequests(requests)
                    guard result.isReleased else{return result}
                    return await plugin.meetings.pruneProviderRequests(requests)
                case .dictation:
                    result=await plugin.model.retireProviderRequests(requests)
                    guard result.isReleased else{return result}
                    return await plugin.model.pruneProviderRequests(requests)
                }
            }.value
            for run in owned { if !(await retireRun(run).value) { released = false } }
            if let uiLease, case .client(let connection, _) = uiLease.owner, connection == context.id {
                if closing { released = await drainOwnedWork(uiLease.owner) && released }
                else if let original = activity.retire(uiLease) { released = await original.value.fullyReleased && released }
                else { released = false }
            }
            if fullContext === context { await plugin.endSharedSession() }
            return released
        }
        retirementTasks[context.id] = original
        return await original.value
    }
    func finished(_ context: VoiceClientContext, resourcesReleased: Bool) {
        if fullContext === context {
            fullContext = nil
            if !resourcesReleased { uncertainFull = context }
        }
        contexts[context.id] = nil
        _=contextAdmission.finish(context.admission,allReturned:resourcesReleased)
        if resourcesReleased{
            retirementTasks[context.id]=nil;quarantinedContexts[context.id]=nil
        }else{
            // Keep the actual unresolved context and its original joins. Its
            // occupied admission slot survives disconnect and counts toward4.
            quarantinedContexts[context.id]=context
        }
    }
    private func foundationOwner(_ owner: VoiceActivityOwner) -> VoiceFoundationOwner {
        if owner == .localUser { return LocalFoundationModelWork.localUser }
        if let token = foundationOwners[owner] { return token }
        let token = VoiceFoundationOwner(); foundationOwners[owner] = token; return token
    }
    private func drainOwnedWork(_ owner: VoiceActivityOwner) async -> Bool {
        var released = true
        for family in touched[owner] ?? [] { if !(await drain(family, owner: owner)).isReleased { released = false } }
        return released
    }
    private func drain(_ family: VoiceResourceFamily, owner scopedOwner: VoiceActivityOwner?) async -> VoiceResourceRelease {
        if let scopedOwner, touched[scopedOwner]?.contains(family) != true { return .released(.cancelled) }
        switch family {
        case .clients:
            // Global shutdown must join captured physical contexts directly.
            // Never call registry.retire from its own shutdown controller.
            if scopedOwner != nil { return .released(.cancelled) }
            let originals = Array(contexts.values).map { $0.retire(acknowledge: true) }
            var clean = true
            for original in originals { if !(await original.value) { clean = false } }
            return contextAdmission.releaseAfterJoiningClients(originalsReturned:clean,
                quarantinedContexts:quarantinedContexts.count)
        case .files:
            if let scopedOwner, case .client(_, let original?) = scopedOwner,
               let run = runs.values.first(where: { $0.original == original && $0.lease.owner == scopedOwner }),
               [MeetingReadContract.search.id, MeetingReadContract.read.id].contains(run.definition.id) {
                await plugin.retireMeetingReads([run.provider])
                return .released(.cancelled)
            }
            let capturedOwner=scopedOwner.map{foundationOwner($0)}
            let voiceFiles=await plugin.model.sharedFileRetirement(owner:capturedOwner)
            let meetingFiles=await plugin.meetings.retireFileWork(owner:capturedOwner)
            return VoiceFileWork.aggregate([voiceFiles,meetingFiles])
        case .dictation:
            return await plugin.model.sharedDictationRetirement() ? .released(.cancelled):.unknown("owned-dictation-io-return-failed")
        case .recognition:
            return await plugin.conversation.sharedRetirement() ? .released(.cancelled) : .unknown("owned-conversation-output-stop-failed")
        case .output:
            let modelReleased = await plugin.model.sharedSpeechRetirement()
            let conversationReleased = await plugin.conversation.sharedRetirement()
            return modelReleased && conversationReleased ? .released(.cancelled) : .unknown("owned-speech-stop-failed")
        case .meetings: return await plugin.meetings.retireShared(owner: scopedOwner.map { foundationOwner($0) })
        case .editing:
            await plugin.model.sharedEditingRetirement()
            return .released(.cancelled)
        case .foundationModels:
            let original: Task<Void, Never>?
            if let scopedOwner { original = LocalFoundationModelWork.cancelAndWait(owner: foundationOwner(scopedOwner)) }
            else { original = LocalFoundationModelWork.sealAndWait() }
            await original?.value
            return .released(.cancelled)
        case .uiAndHotkeys:
            if scopedOwner != nil { return .released(.cancelled) } // Service-owned controls survive a client detach.
            await plugin.shutdownControls()
            guard let originalPresentationRetirement else {
                return .unknown("appearance-retirement-not-captured")
            }
            guard await originalPresentationRetirement.value else {
                return .unknown("owned-appearance-return-refused")
            }
            return .released(.cancelled)
        }
    }
    func shutdown() async -> Bool {
        if let originalShutdown { return await originalShutdown.value }
        closing = true
        let originalListener = listener
        let accept = originalAccept
        let originalContexts = Array(contexts.values)
        // Publish the sole parent before any observer removal/native close can
        // synchronously reenter. The bounded handoff carries only actual tasks
        // returned by those original contexts, never replacement cleanup.
        let setup = AsyncStream<[Task<Bool, Never>]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let original = Task { [self] in
            var iterator = setup.stream.makeAsyncIterator()
            guard let priorContexts = await iterator.next() else {
                try? await ledger.markRecoveryRequired(reason: "shutdown-originals-missing")
                return false
            }
            for context in priorContexts { _ = await context.value }
            await accept?.value
            if let originalListener {
                let result = await originalListener.retirement()
                recordNativeReturn(result.failure)
            }
            let report = await activity.beginShutdown().value
            guard nativeReturnFailure == nil, let witness = report.cleanWitness else {
                try? await ledger.markRecoveryRequired(reason: "original-resource-return-unknown")
                return false
            }
            do { try await ledger.commitClean(witness); return true }
            catch { return false }
        }
        originalShutdown = original
        // Central presentation admission closes before the first await. Client
        // detach must never retire this service-owned store or its windows.
        originalPresentationRetirement = plugin.sealPresentationForRetirement()
        originalListener?.stopAccepting()
        let priorContexts = originalContexts.map { $0.retire(acknowledge: true) }
        setup.continuation.yield(priorContexts)
        setup.continuation.finish()
        return await original.value
    }
}

/// One connection's aggregate data budget. Actual native/consent checks happen
/// before the runtime calls reserve; a ticket is not an execution grant.
@MainActor final class VoiceClientRunBudget{
    enum Kind:Equatable,Sendable{case incoming,provider}
    struct Reservation:Equatable,Sendable{
        let id:UUID
        let generation:UUID
        let kind:Kind
        fileprivate init(id:UUID,kind:Kind){self.id=id;self.generation=UUID();self.kind=kind}
    }
    private var seen=Set<UUID>()
    private var live:[UUID:Reservation]=[:]
    private var closed=false
    func reserve(_ id:UUID,kind:Kind)throws->Reservation{
        guard !closed,!seen.contains(id),seen.count<PluginSharedApplicationLimits.maximumSeenRunsPerConnection else{throw VoiceServiceProblem.protocolViolation}
        seen.insert(id)
        guard live.count<PluginSharedApplicationLimits.maximumLiveRunsPerConnection else{throw VoiceServiceProblem.busy}
        let original=Reservation(id:id,kind:kind);live[id]=original;return original
    }
    func release(_ original:Reservation){if live[original.id]==original{live[original.id]=nil}}
    func close(){closed=true}
}

/// Private context ownership, independent of whether a native FD still appears
/// live. Unknown local I/O/work consumes its original slot until process exit.
@MainActor final class VoiceContextAdmission{
    struct Reservation:Equatable,Sendable{
        let id:UUID
        fileprivate let generation:UUID
        fileprivate init(){id=UUID();generation=UUID()}
    }
    private var occupied:[UUID:Reservation]=[:]
    private var unresolved=Set<UUID>()
    var occupiedCount:Int{occupied.count}
    var unresolvedCount:Int{unresolved.count}
    /// The actual global clients controller calls this AFTER joining its live
    /// originals. Missing live contexts do not erase a previously retained
    /// unknown context or an admission reserved before context construction.
    func releaseAfterJoiningClients(originalsReturned:Bool,quarantinedContexts:Int)->VoiceResourceRelease{
        guard originalsReturned,quarantinedContexts == 0,occupied.isEmpty,unresolved.isEmpty else{
            return .unknown("client-retirement-unknown")
        }
        return .released(.cancelled)
    }
    func reserve()->Reservation?{
        guard occupied.count<PluginSharedApplicationLimits.maximumConnections else{return nil}
        let original=Reservation();occupied[original.id]=original;return original
    }
    @discardableResult func finish(_ original:Reservation,allReturned:Bool)->Bool{
        guard occupied[original.id]==original else{return false}
        if allReturned{occupied[original.id]=nil;unresolved.remove(original.id)}
        else{unresolved.insert(original.id)}
        return true
    }
}

/// Bounded original provider IDs survive terminal delivery until this exact
/// context detaches. A snapshot is private, immutable and context-specific; it
/// is neither a caller-supplied owner nor an SDK permission.
@MainActor final class VoiceContextProviderHistory{
    struct Snapshot:Sendable{
        fileprivate let generation:UUID
        fileprivate let records:[UUID:VoiceProviderSource]
    }
    private let generation=UUID()
    private var records:[UUID:VoiceProviderSource]=[:]
    private var sealed:Snapshot?
    private var originalRetirement:Task<Bool,Never>?
    var retainedCount:Int{records.count}
    func record(_ request:UUID,source:VoiceProviderSource)throws{
        guard sealed == nil,records[request] == nil,
              records.count<PluginSharedApplicationLimits.maximumSeenRunsPerConnection else{throw VoiceServiceProblem.staleContext}
        records[request]=source
    }
    @discardableResult func seal()->Snapshot{
        if let sealed{return sealed}
        let original=Snapshot(generation:generation,records:records);sealed=original;return original
    }
    /// Only the joined original family may be pruned. Validation is all-or-none
    /// and refuses a foreign/stale snapshot without touching any retained ID.
    @discardableResult func pruneJoined(_ original:Snapshot,source:VoiceProviderSource)->Bool{
        guard sealed != nil,original.generation==generation else{return false}
        let matching=original.records.filter{$0.value==source}
        guard !matching.isEmpty,matching.allSatisfy({records[$0.key]==$0.value})else{return false}
        for id in matching.keys{records[id]=nil}
        return true
    }
    func retire(using join:@escaping @MainActor (VoiceProviderSource,Set<UUID>) async -> VoiceResourceRelease)->Task<Bool,Never>{
        if let originalRetirement{return originalRetirement}
        let original=seal()
        let task=Task{[self] in
            var returned=true
            for source in [VoiceProviderSource.meeting,.dictation]{
                let ids=Set(original.records.filter{$0.value==source}.map(\.key))
                if ids.isEmpty{continue}
                let result=await join(source,ids)
                if !result.isReleased || !pruneJoined(original,source:source){returned=false}
            }
            return returned && records.isEmpty
        }
        originalRetirement=task;return task
    }
}
