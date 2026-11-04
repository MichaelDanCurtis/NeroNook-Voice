import Foundation
import Darwin
import CryptoKit
import NookPluginSDK
import NookLocalServiceKit

/// Trusted native composition, never Codable or read from a peer/environment.
/// The normal app selects only operational(); fixture composition must be an
/// explicitly scoped native source product, not a default fallback.
struct VoiceServicePolicy: Sendable {
    let native: LocalServicePolicy
    let serviceIdentifier: String
    let moduleIdentifier: String
    let fullModulePolicyKey: String
    let capabilityPolicyKeys: Set<String>
    let lifecycleRoot: URL
    let resourceRevision: String
    let buildIdentifier: String
    let permitsGlobalControls: Bool

    init(native: LocalServicePolicy, serviceIdentifier: String, moduleIdentifier: String,
         fullModulePolicyKey: String, capabilityPolicyKeys: Set<String>, lifecycleRoot: URL,
         resourceRevision: String, buildIdentifier: String, permitsGlobalControls: Bool) throws {
        guard resourceRevision.utf8.count == 64, resourceRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !fullModulePolicyKey.isEmpty, capabilityPolicyKeys.count <= 7,
              !capabilityPolicyKeys.contains(fullModulePolicyKey), !buildIdentifier.isEmpty,
              buildIdentifier.utf8.count <= 128 else { throw VoiceServiceProblem.unavailable }
        self.native = native; self.serviceIdentifier = serviceIdentifier; self.moduleIdentifier = moduleIdentifier
        self.fullModulePolicyKey = fullModulePolicyKey; self.capabilityPolicyKeys = capabilityPolicyKeys
        self.lifecycleRoot = lifecycleRoot; self.resourceRevision = resourceRevision
        self.buildIdentifier = buildIdentifier; self.permitsGlobalControls = permitsGlobalControls
    }
    /// This copies trusted composition data only. The new root is admitted by
    /// the retained native owner and creation capability, never by this URL.
    func replacingLifecycleRoot(_ root: URL) throws -> VoiceServicePolicy {
        try VoiceServicePolicy(native: native, serviceIdentifier: serviceIdentifier,
            moduleIdentifier: moduleIdentifier, fullModulePolicyKey: fullModulePolicyKey,
            capabilityPolicyKeys: capabilityPolicyKeys, lifecycleRoot: root,
            resourceRevision: resourceRevision, buildIdentifier: buildIdentifier,
            permitsGlobalControls: permitsGlobalControls)
    }
    static func operational(bundle: Bundle = .main) throws -> VoiceServicePolicy {
        let service = "cafe.nero.plugin.voice"
        guard bundle.bundleIdentifier == service,
              bundle.object(forInfoDictionaryKey: "NeroVoiceRuntimeKind") as? String == "shared-service-v1",
              let resources = bundle.resourceURL,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            throw VoiceServiceProblem.unavailable
        }
        func requirement(_ identifier: String) -> String {
            "anchor apple generic and certificate leaf[subject.OU] = \"2GFVXB3249\" and identifier \"\(identifier)\""
        }
        let native = try LocalServicePolicy(serviceIdentifier: service,
            trustedSelfRequirements: ["voice-service": requirement(service)],
            trustedPeerRequirements: ["nook-module-adapter": requirement("local.neronook.preview"),
                                      "ember-capability-client": requirement("cafe.nero.ember.desktop")])
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeroVoice/ServiceLifecycle", isDirectory: true)
        return try VoiceServicePolicy(native: native, serviceIdentifier: service, moduleIdentifier: service,
            fullModulePolicyKey: "nook-module-adapter", capabilityPolicyKeys: ["ember-capability-client"],
            lifecycleRoot: root, resourceRevision: viewsRevision(resources.appendingPathComponent("Views")),
            buildIdentifier: version + "." + build, permitsGlobalControls: true)
    }
    func permits(role: PluginSharedApplicationRole, peer: LocalServicePeer) -> Bool {
        switch role {
        case .moduleAdapter: return peer.policyKey == fullModulePolicyKey
        case .capabilityClient: return capabilityPolicyKeys.contains(peer.policyKey)
        }
    }
    static func viewsRevision(_ root: URL) throws -> String {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw VoiceServiceProblem.unavailable
        }
        // Bundle.resourceURL may use /tmp while Foundation's enumerator emits
        // /private/tmp. Keep the original leaf-link refusal above, then derive
        // both enumeration and byte-exact relative names from one physical root.
        guard root.isFileURL, let resolved = realpath(root.path, nil) else { throw VoiceServiceProblem.unavailable }
        defer { free(resolved) }
        let physicalRoot = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        guard let iterator = manager.enumerator(at: physicalRoot, includingPropertiesForKeys: Array(keys), options: []) else {
            throw VoiceServiceProblem.unavailable
        }
        var entries: [(String, Data)] = [], total = 0
        for case let path as URL in iterator {
            let values = try path.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw VoiceServiceProblem.unavailable }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0, size <= 2_097_152,
                  entries.count < 256, total <= 16_777_216 - size else { throw VoiceServiceProblem.unavailable }
            let prefix = Array((physicalRoot.path + "/").utf8), absolute = Array(path.path.utf8)
            guard absolute.starts(with: prefix) else { throw VoiceServiceProblem.unavailable }
            let relative = String(decoding: absolute.dropFirst(prefix.count), as: UTF8.self)
            guard !relative.isEmpty, relative.utf8.count <= 1024, !relative.utf8.contains(0) else { throw VoiceServiceProblem.unavailable }
            let bytes = try Data(contentsOf: path, options: [.mappedIfSafe])
            guard bytes.count == size else { throw VoiceServiceProblem.unavailable }
            total += size; entries.append((relative, Data(SHA256.hash(data: bytes))))
        }
        guard !entries.isEmpty else { throw VoiceServiceProblem.unavailable }
        entries.sort { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
        var digest = SHA256()
        for (path, hash) in entries {
            digest.update(data: Data(path.utf8)); digest.update(data: Data([0]))
            digest.update(data: hash); digest.update(data: Data([0]))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
