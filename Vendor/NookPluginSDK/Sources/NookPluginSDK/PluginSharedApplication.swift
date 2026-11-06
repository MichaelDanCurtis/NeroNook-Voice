import Foundation

// Generic local attachment data. Codable DTO construction alone is neither
// strict wire validation nor authentication/approval. Use the bounded codec;
// actual live/native direction, currentness and resource custody stay separate.

public enum PluginSharedApplicationLimits {
    public static let version = 1
    public static let maximumJSONBytes = 262_144 // LF not included
    public static let maximumControlJSONBytes = 65_536 // every non-module envelope
    public static let maximumBufferedBytes = 524_290 // two maximum framed lines
    public static let maximumQueuedBytes = 1_048_576 // per connection, whole lines
    public static let maximumReadChunkBytes = 65_536
    public static let maximumConnections = 4 // includes unapproved/pending peers
    public static let maximumLiveRunsPerConnection = 32
    public static let maximumSeenRunsPerConnection = 4_096
    public static let maximumSequence: UInt64 = 9_007_199_254_740_991
    public static let maximumActionDefinitionBytes = 8_192
    public static let maximumValuesBytes = 8_192
    public static let maximumRunFrameBytes = 16_384
    public static let maximumRunUpdateBytes = 32_768
    public static let maximumFeatures = 16
    public static let maximumCapabilities = 16
    public static let connectSeconds = 3, helloSeconds = 5, approvalSeconds = 120
    public static let heartbeatSeconds = 5, silentPeerSeconds = 15
}

/// Signed connector expectation only. Actual selected application location,
/// trust requirements, principal proof and install/update custody stay native.
public struct PluginSharedApplicationDescriptor: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let connectorBundleIdentifier: String
    public let serviceIdentifier: String
    public let resourceRevision: String
    public init(connectorBundleIdentifier: String, serviceIdentifier: String, resourceRevision: String) {
        protocolVersion = 1; self.connectorBundleIdentifier = connectorBundleIdentifier
        self.serviceIdentifier = serviceIdentifier; self.resourceRevision = resourceRevision
    }
    /// Structural expectation only; never verifies an executable or grants use.
    /// The logical module ID is separate and may equal a legacy service ID.
    public func validate() throws {
        func full(_ value: String, _ pattern: String) -> Bool {
            guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
            return range == value.startIndex..<value.endIndex
        }
        func identifier(_ value: String) -> Bool {
            value.utf8.count <= 100 && full(value, #"^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$"#)
        }
        guard protocolVersion == 1, identifier(connectorBundleIdentifier), identifier(serviceIdentifier),
              connectorBundleIdentifier != serviceIdentifier,
              full(resourceRevision, #"^[0-9a-f]{64}$"#) else {
            throw ModuleProblem("Invalid shared application descriptor.")
        }
    }
}
public enum PluginSharedApplicationRole: String, Codable, Sendable { case moduleAdapter, capabilityClient }
public enum PluginSharedApprovalState: String, Codable, Sendable { case pending, granted, denied, revoked }
public enum PluginSharedRunOutcome: String, Codable, Sendable { case succeeded, failed, cancelled, refused }
public enum PluginSharedStatusCode: String, Codable, Sendable {
    case ownerBusy, approvalRequired, draining, unknownRun, protocolViolation, ownerStopping, capabilityRefused
}
public struct PluginSharedAttach: Codable, Sendable {
    public let serviceIdentifier: String
    public let role: PluginSharedApplicationRole
    public let nonce: UUID
    public let features: [String], requiredFeatures: [String], requestedCapabilities: [String]
    public let moduleIdentifier: String?
    public let resourceRevision: String?
    public init(serviceIdentifier: String, role: PluginSharedApplicationRole, nonce: UUID,
                features: [String], requiredFeatures: [String], requestedCapabilities: [String], moduleIdentifier: String? = nil, resourceRevision: String? = nil) {
        self.serviceIdentifier = serviceIdentifier; self.role = role; self.nonce = nonce
        self.features = features; self.requiredFeatures = requiredFeatures
        self.requestedCapabilities = requestedCapabilities; self.moduleIdentifier = moduleIdentifier; self.resourceRevision = resourceRevision
    }
}
public struct PluginSharedHello: Codable, Sendable {
    public let role: PluginSharedApplicationRole
    public let clientNonce: UUID, serviceNonce: UUID
    public let features: [String]
    public let moduleIdentifier: String?
    public let resourceRevision: String?
    public init(role: PluginSharedApplicationRole, clientNonce: UUID, serviceNonce: UUID,
                features: [String], moduleIdentifier: String? = nil, resourceRevision: String? = nil) {
        self.role = role; self.clientNonce = clientNonce; self.serviceNonce = serviceNonce
        self.features = features; self.moduleIdentifier = moduleIdentifier; self.resourceRevision = resourceRevision
    }
}
/// Bytes of ONE existing PluginRegisteredAction JSON value, <=8192 bytes.
/// The codec decodes/validates the existing type and requires matching id.
/// This definition describes a capability; it never establishes a native grant.
public struct PluginSharedCapability: Codable, Sendable {
    public let id: String
    public let definition: Data
    public init(id: String, definition: Data) { self.id = id; self.definition = definition }
}
public struct PluginSharedApprovalRequest: Codable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}
public struct PluginSharedApproval: Codable, Sendable {
    public let id: UUID
    public let state: PluginSharedApprovalState
    public let capabilities: [PluginSharedCapability]
    public init(id: UUID, state: PluginSharedApprovalState, capabilities: [PluginSharedCapability] = []) {
        self.id = id; self.state = state; self.capabilities = capabilities
    }
}
public struct PluginSharedModulePayload: Codable, Sendable {
    public let plugin: Data // exact PluginMessage.encoded(): <=131072 JSON bytes + LF
    public init(plugin: Data) { self.plugin = plugin }
}
public struct PluginSharedInvoke: Codable, Sendable {
    public let run: UUID
    public let capability: String
    public let values: Data // JSON of existing [String: PluginValue], not a bus
    public init(run: UUID, capability: String, values: Data) {
        self.run = run; self.capability = capability; self.values = values
    }
}
public struct PluginSharedRunFrame: Codable, Sendable {
    public let run: UUID
    public let frame: Data // JSON of exactly one existing PluginRunFrame
    public init(run: UUID, frame: Data) { self.run = run; self.frame = frame }
}
public struct PluginSharedRunUpdate: Codable, Sendable {
    public let run: UUID
    public let update: Data // JSON of exactly one existing PluginRunUpdate
    public init(run: UUID, update: Data) { self.run = run; self.update = update }
}
public struct PluginSharedRunReference: Codable, Sendable {
    public let run: UUID
    public init(run: UUID) { self.run = run }
}
public struct PluginSharedStatus: Codable, Sendable {
    public let code: PluginSharedStatusCode
    public let run: UUID?
    public init(code: PluginSharedStatusCode, run: UUID? = nil) { self.code = code; self.run = run }
}
public struct PluginSharedRetired: Codable, Sendable {
    public let run: UUID
    public let outcome: PluginSharedRunOutcome
    public init(run: UUID, outcome: PluginSharedRunOutcome) { self.run = run; self.outcome = outcome }
}

/// The encoder emits kind+body, never Swift's synthesized enum representation.
/// Headers bind data to one observed physical connection, not a claimed peer.
public struct PluginSharedApplicationEnvelope: Codable, Sendable {
    public enum Payload: Sendable {
        case attach(PluginSharedAttach), hello(PluginSharedHello)
        case approvalRequest(PluginSharedApprovalRequest), approval(PluginSharedApproval)
        case module(PluginSharedModulePayload), invoke(PluginSharedInvoke)
        case runInput(PluginSharedRunFrame), runOutput(PluginSharedRunFrame), update(PluginSharedRunUpdate)
        case cancel(PluginSharedRunReference), status(PluginSharedStatus), retired(PluginSharedRetired)
        case detach, detached, heartbeat
    }
    public let version: Int
    public let sequence: UInt64
    public let session: UUID
    public let instance: UUID?, connection: UUID?
    public let payload: Payload
    public init(sequence: UInt64, session: UUID, instance: UUID? = nil, connection: UUID? = nil, payload: Payload) {
        version = 1; self.sequence = sequence; self.session = session
        self.instance = instance; self.connection = connection; self.payload = payload
    }
    private enum Keys: String, CodingKey { case version, sequence, session, instance, connection, kind, body }
    private enum Kind: String, Codable { case attach, hello, approvalRequest, approval, module, invoke, runInput, runOutput, update, cancel, status, retired, detach, detached, heartbeat }
    private struct Empty: Codable {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        version = try c.decode(Int.self, forKey: .version); sequence = try c.decode(UInt64.self, forKey: .sequence)
        session = try c.decode(UUID.self, forKey: .session)
        instance = try c.decodeIfPresent(UUID.self, forKey: .instance); connection = try c.decodeIfPresent(UUID.self, forKey: .connection)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .attach: payload = .attach(try c.decode(PluginSharedAttach.self, forKey: .body))
        case .hello: payload = .hello(try c.decode(PluginSharedHello.self, forKey: .body))
        case .approvalRequest: payload = .approvalRequest(try c.decode(PluginSharedApprovalRequest.self, forKey: .body))
        case .approval: payload = .approval(try c.decode(PluginSharedApproval.self, forKey: .body))
        case .module: payload = .module(try c.decode(PluginSharedModulePayload.self, forKey: .body))
        case .invoke: payload = .invoke(try c.decode(PluginSharedInvoke.self, forKey: .body))
        case .runInput: payload = .runInput(try c.decode(PluginSharedRunFrame.self, forKey: .body))
        case .runOutput: payload = .runOutput(try c.decode(PluginSharedRunFrame.self, forKey: .body))
        case .update: payload = .update(try c.decode(PluginSharedRunUpdate.self, forKey: .body))
        case .cancel: payload = .cancel(try c.decode(PluginSharedRunReference.self, forKey: .body))
        case .status: payload = .status(try c.decode(PluginSharedStatus.self, forKey: .body))
        case .retired: payload = .retired(try c.decode(PluginSharedRetired.self, forKey: .body))
        case .detach: _ = try c.decode(Empty.self, forKey: .body); payload = .detach
        case .detached: _ = try c.decode(Empty.self, forKey: .body); payload = .detached
        case .heartbeat: _ = try c.decode(Empty.self, forKey: .body); payload = .heartbeat
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(version, forKey: .version); try c.encode(sequence, forKey: .sequence); try c.encode(session, forKey: .session)
        try c.encodeIfPresent(instance, forKey: .instance); try c.encodeIfPresent(connection, forKey: .connection)
        func put<T: Encodable>(_ kind: Kind, _ value: T) throws { try c.encode(kind, forKey: .kind); try c.encode(value, forKey: .body) }
        switch payload {
        case .attach(let v): try put(.attach, v)
        case .hello(let v): try put(.hello, v)
        case .approvalRequest(let v): try put(.approvalRequest, v)
        case .approval(let v): try put(.approval, v)
        case .module(let v): try put(.module, v)
        case .invoke(let v): try put(.invoke, v)
        case .runInput(let v): try put(.runInput, v)
        case .runOutput(let v): try put(.runOutput, v)
        case .update(let v): try put(.update, v)
        case .cancel(let v): try put(.cancel, v)
        case .status(let v): try put(.status, v)
        case .retired(let v): try put(.retired, v)
        case .detach: try put(.detach, Empty())
        case .detached: try put(.detached, Empty())
        case .heartbeat: try put(.heartbeat, Empty())
        }
    }
}

/// Pure bounded representation only. No native principal, approval, connection
/// state or resource-ready value can be supplied to this codec as authority.
public enum PluginSharedApplicationCodec {
    public static func encode(_ envelope: PluginSharedApplicationEnvelope) throws -> Data {
        do {
            try SharedApplicationShape.preflight(envelope)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
            let node = try PluginFlowJSON.parse(encoder.encode(envelope))
            try SharedApplicationShape.validate(node)
            var data = try node.canonicalData()
            try SharedApplicationShape.byteLimit(data, node: node)
            data.append(10); return data
        } catch { throw ModuleProblem("Invalid shared application frame.") }
    }
    public static func decodeLine(_ line: Data) throws -> PluginSharedApplicationEnvelope {
        do {
            guard line.count >= 2, line.count <= PluginSharedApplicationLimits.maximumJSONBytes + 1,
                  line.last == 10 else { throw ModuleProblem("Invalid shared application frame.") }
            let data = Data(line.dropLast())
            guard !data.contains(10) else { throw ModuleProblem("Invalid shared application frame.") }
            let node = try PluginFlowJSON.parse(data)
            try SharedApplicationShape.byteLimit(data, node: node)
            try SharedApplicationShape.validate(node)
            // Decode the validated integer-domain representation, so permitted
            // JSON numeric spellings (1.0/1e0) cannot vary by Codable coercion.
            return try JSONDecoder().decode(PluginSharedApplicationEnvelope.self, from: node.canonicalData())
        } catch { throw ModuleProblem("Invalid shared application frame.") }
    }
}

/// One physical reader's framing state. Closing/failure is terminal; this value
/// has no reconnect, permission, callback or native-resource side effects.
public struct PluginSharedApplicationLines: Sendable {
    private var buffer = Data()
    private var failed = false, closed = false
    public init() {}
    public mutating func append(_ data: Data) throws -> [PluginSharedApplicationEnvelope] {
        do {
            guard !failed, !closed,
                  data.count <= PluginSharedApplicationLimits.maximumBufferedBytes - buffer.count else {
                throw ModuleProblem("Invalid shared application stream.")
            }
            buffer.append(data)
            var result = [PluginSharedApplicationEnvelope]()
            while let end = buffer.firstIndex(of: 10) {
                let after = buffer.index(after: end)
                result.append(try PluginSharedApplicationCodec.decodeLine(Data(buffer[..<after])))
                buffer.removeSubrange(..<after)
            }
            guard buffer.count <= PluginSharedApplicationLimits.maximumJSONBytes else {
                throw ModuleProblem("Invalid shared application stream.")
            }
            return result
        } catch {
            failed = true; buffer.removeAll(keepingCapacity: false)
            throw ModuleProblem("Invalid shared application stream.")
        }
    }
    public mutating func finish() throws {
        guard !failed, !closed, buffer.isEmpty else {
            failed = true; buffer.removeAll(keepingCapacity: false)
            throw ModuleProblem("Invalid shared application stream.")
        }
        closed = true
    }
}

private enum SharedApplicationShape {
    typealias J = PluginFlowJSON
    static func require(_ value: Bool) throws { if !value { throw ModuleProblem("Invalid shared application shape.") } }
    static func full(_ value: String, _ pattern: String) -> Bool {
        guard let range = value.range(of: pattern, options: .regularExpression) else { return false }
        return range == value.startIndex..<value.endIndex
    }
    /// Bound already-typed payloads before JSONEncoder allocates base64/JSON.
    /// Decoder input has its independent wire cap before parsing.
    static func preflight(_ envelope: PluginSharedApplicationEnvelope) throws {
        let handshake: Bool, attach: Bool
        switch envelope.payload { case .attach: handshake = true; attach = true
        case .hello: handshake = true; attach = false
        default: handshake = false; attach = false }
        try require(envelope.version == 1 && envelope.sequence <= PluginSharedApplicationLimits.maximumSequence)
        try require(handshake ? envelope.sequence == 0 : envelope.sequence >= 1)
        try require(attach ? (envelope.instance == nil && envelope.connection == nil) : (envelope.instance != nil && envelope.connection != nil))
        func bounded(_ value: String, _ count: Int) throws { try require(value.utf8.count <= count) }
        func list(_ values: [String], _ count: Int) throws {
            try require(values.count <= 16)
            for value in values { try bounded(value, count) }
        }
        func optional(_ value: String?, _ count: Int) throws { if let value { try bounded(value, count) } }
        switch envelope.payload {
        case .attach(let body):
            try bounded(body.serviceIdentifier, 100); try optional(body.moduleIdentifier, 100); try optional(body.resourceRevision, 64)
            try list(body.features, 80); try list(body.requiredFeatures, 80); try list(body.requestedCapabilities, 64)
        case .hello(let body):
            try list(body.features, 80); try optional(body.moduleIdentifier, 100); try optional(body.resourceRevision, 64)
        case .approval(let body):
            try require(body.capabilities.count <= 16)
            for capability in body.capabilities {
                try bounded(capability.id, 64); try require(capability.definition.count <= 8192)
            }
        case .module(let body): try require(body.plugin.count <= PluginLines.maximumBytes + 1)
        case .invoke(let body): try bounded(body.capability, 64); try require(body.values.count <= 8192)
        case .runInput(let body), .runOutput(let body): try require(body.frame.count <= 16384)
        case .update(let body): try require(body.update.count <= 32768)
        case .approvalRequest, .cancel, .status, .retired, .detach, .detached, .heartbeat: break
        }
    }
    static func object(_ node: J?, required: [String], optional: [String] = []) throws -> [String: J] {
        guard let members = node?.members else { throw ModuleProblem("Invalid shared application shape.") }
        let allowed = required + optional
        try require(members.allSatisfy { member in allowed.contains { $0.utf8.elementsEqual(member.name.utf8) } })
        let values = Dictionary(uniqueKeysWithValues: members.map { ($0.name, $0.value) })
        try require(required.allSatisfy { values[$0] != nil })
        return values
    }
    static func string(_ node: J?) throws -> String {
        guard let value = node?.string else { throw ModuleProblem("Invalid shared application shape.") }; return value
    }
    static func uuid(_ node: J?) throws -> UUID {
        let value = try string(node)
        try require(full(value, #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#))
        guard let id = UUID(uuidString: value) else { throw ModuleProblem("Invalid shared application shape.") }; return id
    }
    static func identifier(_ node: J?) throws {
        let value = try string(node)
        try require(value.utf8.count <= 100 && full(value, #"^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$"#))
    }
    static func key(_ node: J?) throws -> String {
        let value = try string(node); try require(full(value, #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#)); return value
    }
    static func strings(_ node: J?, feature: Bool) throws -> [String] {
        guard let array = node?.array else { throw ModuleProblem("Invalid shared application shape.") }
        try require(array.count <= 16)
        let values = try array.map { try string($0) }
        try require(Set(values).count == values.count)
        for value in values {
            if feature { try require(full(value, #"^[a-z][a-z0-9-]{0,79}$"#)) }
            else { try require(full(value, #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#)) }
        }
        return values
    }
    static func data(_ node: J?, maximum: Int) throws -> Data {
        let text = try string(node)
        try require(text.utf8.count <= 4 * ((maximum + 2) / 3))
        guard let bytes = Data(base64Encoded: text), bytes.count <= maximum,
              bytes.base64EncodedString() == text else { throw ModuleProblem("Invalid shared application base64.") }
        return bytes
    }
    static func legacy<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try require(String(data: data, encoding: .utf8) != nil && !data.starts(with: [239, 187, 191]))
        // Existing fractional SDK values keep their existing JSON domain, not
        // the integer-only outer representation. No generic bus is admitted.
        _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(type, from: data)
    }
    static func values(_ values: [String: PluginValue]) throws {
        let encoded = try JSONEncoder().encode(values)
        try require(values.count <= 16 && encoded.count <= 8192)
        for (key, value) in values {
            try require(full(key, #"^[A-Za-z][A-Za-z0-9_]{0,63}$"#))
            switch value {
            case .string(let text): try require(text.utf8.count <= 2048)
            case .number(let number): try require(number.isFinite)
            case .boolean: break
            }
        }
    }
    static func role(_ body: [String: J], attach: Bool) throws -> String {
        let value = try string(body["role"])
        try require(["moduleAdapter", "capabilityClient"].contains(value))
        let features = try strings(body["features"], feature: true)
        let required = Set(["retirement-v1", value == "moduleAdapter" ? "plugin-message-v1" : "capability-runs-v1"])
        try require(required.isSubset(of: Set(features)))
        if attach {
            let requested = try strings(body["requiredFeatures"], feature: true)
            try require(required.isSubset(of: Set(requested)) && Set(requested).isSubset(of: Set(features)))
            let capabilities = try strings(body["requestedCapabilities"], feature: false)
            try require(value == "moduleAdapter" ? capabilities.isEmpty : !capabilities.isEmpty)
        }
        if value == "moduleAdapter" {
            try identifier(body["moduleIdentifier"])
            let revision = try string(body["resourceRevision"])
            try require(full(revision, #"^[0-9a-f]{64}$"#))
        } else { try require(body["moduleIdentifier"] == nil && body["resourceRevision"] == nil) }
        return value
    }
    static func byteLimit(_ bytes: Data, node: J) throws {
        let module = node["kind"]?.string == "module"
        try require(bytes.count <= (module ? PluginSharedApplicationLimits.maximumJSONBytes : PluginSharedApplicationLimits.maximumControlJSONBytes))
    }
    static func validate(_ node: J) throws {
        let kind = try string(node["kind"])
        let handshake = kind == "attach" || kind == "hello"
        let header = try object(node, required: ["version", "sequence", "session", "kind", "body"] + (kind == "attach" ? [] : ["instance", "connection"]))
        try require(header["version"]?.integer == 1)
        guard let sequence = header["sequence"]?.integer else { throw ModuleProblem("Invalid shared application sequence.") }
        try require(handshake ? sequence == 0 : (1...PluginFlowJSON.maximumSafeInteger).contains(sequence))
        let session = try uuid(header["session"])
        if kind != "attach" { _ = try uuid(header["instance"]); _ = try uuid(header["connection"]) }
        let raw = header["body"]
        switch kind {
        case "attach":
            let b = try object(raw, required: ["serviceIdentifier", "role", "nonce", "features", "requiredFeatures", "requestedCapabilities"], optional: ["moduleIdentifier", "resourceRevision"])
            try identifier(b["serviceIdentifier"]); _ = try uuid(b["nonce"]); _ = try role(b, attach: true)
        case "hello":
            let b = try object(raw, required: ["role", "clientNonce", "serviceNonce", "features"], optional: ["moduleIdentifier", "resourceRevision"])
            _ = try uuid(b["clientNonce"]); _ = try uuid(b["serviceNonce"]); _ = try role(b, attach: false)
        case "approvalRequest":
            let b = try object(raw, required: ["id"]); _ = try uuid(b["id"])
        case "approval":
            let b = try object(raw, required: ["id", "state", "capabilities"]); _ = try uuid(b["id"])
            let state = try string(b["state"]); try require(["pending", "granted", "denied", "revoked"].contains(state))
            guard let capabilities = b["capabilities"]?.array else { throw ModuleProblem("Invalid shared application capabilities.") }
            try require(capabilities.count <= 16 && (state == "granted" || capabilities.isEmpty))
            var ids = Set<String>()
            for item in capabilities {
                let c = try object(item, required: ["id", "definition"]), id = try key(c["id"])
                try require(ids.insert(id).inserted)
                let bytes = try data(c["definition"], maximum: 8192)
                let action = try legacy(PluginRegisteredAction.self, bytes); try action.validate(); try require(action.id == id)
            }
        case "module":
            let b = try object(raw, required: ["plugin"])
            let bytes = try data(b["plugin"], maximum: PluginLines.maximumBytes + 1)
            try require(bytes.last == 10 && !bytes.dropLast().contains(10))
            var lines = PluginLines(); let decoded = try lines.append(bytes)
            try require(decoded.count == 1 && decoded[0].session == session)
        case "invoke":
            let b = try object(raw, required: ["run", "capability", "values"])
            _ = try uuid(b["run"]); _ = try key(b["capability"])
            try values(legacy([String: PluginValue].self, data(b["values"], maximum: 8192)))
        case "runInput", "runOutput":
            let b = try object(raw, required: ["run", "frame"]); _ = try uuid(b["run"])
            let frame = try legacy(PluginRunFrame.self, data(b["frame"], maximum: 16384))
            try require(frame.sequence < 200000); try values(frame.values)
        case "update":
            let b = try object(raw, required: ["run", "update"]); _ = try uuid(b["run"])
            let update = try legacy(PluginRunUpdate.self, data(b["update"], maximum: 32768))
            try update.validate(); try values(update.values)
            try require(update.phase == .succeeded || update.values.isEmpty)
        case "cancel":
            let b = try object(raw, required: ["run"]); _ = try uuid(b["run"])
        case "status":
            let b = try object(raw, required: ["code"], optional: ["run"])
            try require(PluginSharedStatusCode(rawValue: try string(b["code"])) != nil)
            if let run = b["run"] { _ = try uuid(run) }
        case "retired":
            let b = try object(raw, required: ["run", "outcome"]); _ = try uuid(b["run"])
            try require(PluginSharedRunOutcome(rawValue: try string(b["outcome"])) != nil)
        case "detach", "detached", "heartbeat": _ = try object(raw, required: [])
        default: throw ModuleProblem("Invalid shared application kind.")
        }
    }
}
