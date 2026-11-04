import Foundation
import NookPluginSDK
import NookLocalServiceKit

/// One genuine native FD and one independent P1/inner lifetime. The runtime,
/// never the caller's role string, maps the observed native principal to a role.
@MainActor final class VoiceClientContext {
    let id = UUID()
    let native: LocalServiceConnection
    let instance: UUID
    let runBudget=VoiceClientRunBudget()
    let providerHistory=VoiceContextProviderHistory()
    let admission:VoiceContextAdmission.Reservation
    private(set) var session: UUID?
    private(set) var role: PluginSharedApplicationRole?
    private(set) var approved = false
    private(set) var closing = false
    private(set) var retirementUnknown = false
    weak var runtime: VoiceServiceRuntime?
    private var incoming: UInt64 = 0, outgoing: UInt64 = 0
    private var lastReceived = ProcessInfo.processInfo.systemUptime
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private let opened = ProcessInfo.processInfo.systemUptime
    private var receivedAt: [Double] = []
    private var requests = Set<UUID>()
    private var pendingApproval: UUID?
    private var approvedID: UUID?
    private var approvalStarted: Double?
    private var requestedCapabilities = [String]()
    private var definitions = [String: PluginRegisteredAction]()
    private var reader: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var writer: Task<Bool, Never>?
    private var originalRetirement: Task<Bool, Never>?
    private var queuedBytes = 0
    private var ioFailed = false
    private var refusedInitialClaim = false

    init(native: LocalServiceConnection, instance: UUID, runtime: VoiceServiceRuntime,admission:VoiceContextAdmission.Reservation) {
        self.native = native; self.instance = instance; self.runtime = runtime;self.admission=admission
    }
    func start() {
        guard reader == nil else { return }
        reader = Task { [self] in
            do {
                while let frame = try await native.receive() { try receive(frame) }
                _ = retire(acknowledge: false)
            } catch { failTransport() }
        }
        clock = Task { [self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                let now = ProcessInfo.processInfo.systemUptime
                if session == nil, now - opened >= Double(PluginSharedApplicationLimits.helloSeconds) { failTransport(); return }
                if now - lastReceived >= Double(PluginSharedApplicationLimits.silentPeerSeconds) { failTransport(); return }
                if let started = approvalStarted, now - started >= Double(PluginSharedApplicationLimits.approvalSeconds), let pendingApproval {
                    runtime?.approval.cancel(context: self)
                    finishApproval(pendingApproval, allowed: false)
                }
                if session != nil, now - lastHeartbeat >= Double(PluginSharedApplicationLimits.heartbeatSeconds), !ioFailed {
                    lastHeartbeat=now;_=send(.heartbeat)
                    if approved && !closing{runtime?.heartbeat(for:self)}
                }
            }
        }
    }
    private func receive(_ frame: PluginSharedApplicationEnvelope) throws {
        if closing, refusedInitialClaim, case .approvalRequest(let request) = frame.payload {
            // The private reader obtained this envelope from native.receive(),
            // which already validated it while retaining its original delivery.
            // Clean EOF may retire that proof after return. This branch has no
            // permission/effect: consume only the exact bounded refused control.
            let now = ProcessInfo.processInfo.systemUptime
            receivedAt.removeAll { now - $0 >= 1 }
            guard receivedAt.count < 128, frame.sequence == incoming,
                  incoming <= PluginSharedApplicationLimits.maximumSequence,
                  frame.session == session, frame.instance == instance, frame.connection == id else { throw VoiceServiceProblem.protocolViolation }
            receivedAt.append(now); lastReceived = now; incoming += 1
            guard requests.count < 4, requests.insert(request.id).inserted else { throw VoiceServiceProblem.protocolViolation }
            return
        }
        try native.revalidate()
        let now = ProcessInfo.processInfo.systemUptime
        receivedAt.removeAll { now - $0 >= 1 }
        guard receivedAt.count < 128, frame.sequence == incoming,
              incoming <= PluginSharedApplicationLimits.maximumSequence else { throw VoiceServiceProblem.protocolViolation }
        receivedAt.append(now); lastReceived = now
        if session == nil {
            guard frame.sequence == 0, frame.instance == nil, frame.connection == nil,
                  case .attach(let attach) = frame.payload, let runtime,
                  attach.serviceIdentifier == runtime.policy.serviceIdentifier,
                  runtime.policy.permits(role: attach.role, peer: native.peer) else { throw VoiceServiceProblem.protocolViolation }
            let feature = attach.role == .moduleAdapter ? "plugin-message-v1" : "capability-runs-v1"
            let selected: Set<String> = ["retirement-v1", feature]
            guard selected.isSubset(of: Set(attach.features)), Set(attach.requiredFeatures).isSubset(of: selected) else { throw VoiceServiceProblem.protocolViolation }
            if attach.role == .moduleAdapter {
                guard attach.moduleIdentifier == runtime.policy.moduleIdentifier,
                      attach.resourceRevision == runtime.policy.resourceRevision else { throw VoiceServiceProblem.protocolViolation }
            }
            session = frame.session; role = attach.role; requestedCapabilities = attach.requestedCapabilities
            incoming = 1
            let admitted = runtime.claim(self)
            _ = send(.hello(.init(role: attach.role, clientNonce: attach.nonce, serviceNonce: UUID(),
                                  features: selected.sorted(), moduleIdentifier: attach.moduleIdentifier,
                                  resourceRevision: attach.resourceRevision)))
            if !admitted {
                refusedInitialClaim = true
                _ = send(.status(.init(code: .ownerBusy)))
                _ = send(.status(.init(code: .draining)))
                _ = retire(acknowledge: true)
            }
            return
        }
        guard frame.session == session, frame.instance == instance, frame.connection == id else { throw VoiceServiceProblem.protocolViolation }
        incoming += 1
        switch frame.payload {
        case .heartbeat: return
        case .detach: _ = retire(acknowledge: true); return
        default: break
        }
        if closing {
            // Admission stays closed. Do not create new grants/inner hellos or
            // start effects from any frames already in flight during detach.
            throw VoiceServiceProblem.staleContext
        }
        if case .approvalRequest(let request) = frame.payload {
            guard !approved, pendingApproval == nil, requests.count < 4, requests.insert(request.id).inserted else { throw VoiceServiceProblem.protocolViolation }
            guard runtime?.approval.request(context: self, request: request.id, capabilities: requestedCapabilities) == true else {
                _ = send(.status(.init(code: .ownerBusy))); return
            }
            pendingApproval = request.id; approvalStarted = now
            _ = send(.approval(.init(id: request.id, state: .pending)))
            return
        }
        guard approved else { throw VoiceServiceProblem.protocolViolation }
        switch frame.payload {
        case .module(let body):
            guard role == .moduleAdapter else { throw VoiceServiceProblem.protocolViolation }
            var lines = PluginLines()
            let messages = try lines.append(body.plugin)
            guard messages.count == 1, let message = messages.first, message.session == session else { throw VoiceServiceProblem.protocolViolation }
            try runtime?.receiveModule(message, from: self)
        case .invoke(let invoke):
            guard role == .capabilityClient, let definition = definitions[invoke.capability] else { throw VoiceServiceProblem.protocolViolation }
            let values = try JSONDecoder().decode([String: PluginValue].self, from: invoke.values)
            try definition.input.validate(values)
            try runtime?.invoke(invoke.run, definition: definition, values: values, from: self)
        case .runInput(let input):
            guard role == .capabilityClient else { throw VoiceServiceProblem.protocolViolation }
            try runtime?.input(input, from: self)
        case .cancel(let reference): try runtime?.cancel(reference.run, from: self)
        default: throw VoiceServiceProblem.protocolViolation
        }
    }
    func finishApproval(_ request: UUID, allowed: Bool) {
        guard !closing, pendingApproval == request, let runtime else { return }
        pendingApproval = nil; approvalStarted = nil
        do {
            try native.revalidate()
            guard runtime.policy.permits(role: role ?? .capabilityClient, peer: native.peer) else { throw VoiceServiceProblem.staleContext }
            let actions = allowed && role == .capabilityClient ? runtime.capabilities.filter { requestedCapabilities.contains($0.id) } : []
            guard !allowed || role == .moduleAdapter || !actions.isEmpty else { throw VoiceServiceProblem.unavailable }
            let encoded = try actions.map { PluginSharedCapability(id: $0.id, definition: try JSONEncoder().encode($0)) }
            let state: PluginSharedApprovalState = allowed ? .granted : .denied
            let approval = PluginSharedApproval(id: request, state: state, capabilities: encoded)
            // Preflight the exact whole approval before installing any admission.
            _ = try PluginSharedApplicationCodec.encode(.init(sequence: outgoing, session: session!, instance: instance, connection: id, payload: .approval(approval)))
            approved = allowed; approvedID = allowed ? request : nil
            definitions = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
            _ = send(.approval(approval))
            if allowed { try runtime.approved(self) }
        } catch { failTransport() }
    }
    func queueModule(_ message:PluginMessage)throws->Task<Bool,Never>{
        guard role == .moduleAdapter,approved,!closing,
              message.session == session,message.pluginID == runtime?.policy.moduleIdentifier else{throw VoiceServiceProblem.staleContext}
        return send(.module(.init(plugin:try message.encoded())))
    }
    func sendModule(_ message: PluginMessage) async throws {
        let original=try queueModule(message)
        guard await original.value else{throw VoiceServiceProblem.unavailable}
    }
    @discardableResult func send(_ payload: PluginSharedApplicationEnvelope.Payload) -> Task<Bool, Never> {
        guard let session, !ioFailed, outgoing <= PluginSharedApplicationLimits.maximumSequence else { return Task { false } }
        let frame = PluginSharedApplicationEnvelope(sequence: outgoing, session: session, instance: instance, connection: id, payload: payload)
        guard let bytes = try? PluginSharedApplicationCodec.encode(frame), queuedBytes <= PluginSharedApplicationLimits.maximumQueuedBytes - bytes.count else {
            failTransport(); return Task { false }
        }
        outgoing += 1; queuedBytes += bytes.count
        let previous = writer
        let original = Task { [self] in
            if let previous, !(await previous.value) { queuedBytes -= bytes.count; return false }
            do {
                try await native.send(frame)
                queuedBytes -= bytes.count; return true
            } catch { queuedBytes -= bytes.count; failTransport(); return false }
        }
        writer = original
        return original
    }
    func failTransport() {
        ioFailed = true; native.stopIO()
        _ = retire(acknowledge: false)
    }
    func retire(acknowledge: Bool) -> Task<Bool, Never> {
        if let originalRetirement { return originalRetirement }
        closing = true; approved = false; runBudget.close();_ = providerHistory.seal()
        runtime?.approval.cancel(context: self)
        pendingApproval = nil; approvalStarted = nil
        let original = Task { [self] in
            let workReleased = await runtime?.retire(self) ?? false
            let priorWriter = writer
            let priorSent = await priorWriter?.value ?? !ioFailed
            var acknowledged = false
            if acknowledge && workReleased && priorSent && !ioFailed {
                acknowledged = await send(.detached).value
                if acknowledged {
                    do { try await native.finishSending() } catch { acknowledged = false; ioFailed = true }
                }
            }
            if !acknowledged { native.stopIO() }
            let completion = await native.retirement()
            clock?.cancel(); await clock?.value
            await reader?.value
            if let writer { _ = await writer.value }
            let cleanIO = completion.failure == nil
            let allReturned=workReleased && cleanIO && !ioFailed && (!acknowledge || acknowledged)
            retirementUnknown = !allReturned
            runtime?.finished(self, resourcesReleased: allReturned)
            return allReturned
        }
        originalRetirement = original
        return original
    }
}
