import Foundation
import NookLocalServiceKit

/// This product is selected only by the explicit compiler condition in the
/// actual app entry. Bundle metadata supplies consistency checks and resource
/// bytes; it never chooses a role, a publisher requirement or enrollment mode.
enum VoiceNativeEntry074 {
    static let serviceIdentifier = "cafe.nero.voice.isolated074"
    static let moduleIdentifier = "cafe.nero.plugin.voice"
    static let connectorIdentifier = "cafe.nero.connector.voice.isolated074"
    static let hostIdentifier = "local.neronook.sharedvoice075"
    static let publisherTeam = "2GFVXB3249"
    static let selfPolicyKey = "voice-isolated-service074"
    static let fullModulePolicyKey = "nook-isolated-adapter074"
    static let parent = URL(fileURLWithPath: "/private/tmp/neronook-voice-pair074-501", isDirectory: true)

    /// Construction still uses the actual full Voice runtime and its existing
    /// owner/create/active/product/listener ordering. No native effect starts
    /// here on the app's MainActor; its retained startup task evaluates policy.
    @MainActor static func makeBootstrap(bundle: Bundle = .main) -> VoiceServiceBootstrap {
        VoiceServiceBootstrap(isolatedParent: parent) { try policy(bundle: bundle) }
    }

    static func policy(bundle: Bundle) throws -> VoiceServicePolicy {
        guard bundle.bundleIdentifier == serviceIdentifier,
              bundle.object(forInfoDictionaryKey: "NeroVoiceRuntimeKind") as? String == "shared-service-v1",
              let resources = bundle.resourceURL,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              (1...32).contains(version.utf8.count), (1...32).contains(build.utf8.count) else {
            throw VoiceServiceProblem.unavailable
        }
        // Neither the requirement nor the identity keys can be supplied by
        // Info.plist, environment variables, the module or an inbound message.
        func requirement(_ identifier: String) -> String {
            "anchor apple generic and certificate leaf[subject.OU] = \"\(publisherTeam)\" and identifier \"\(identifier)\""
        }
        let native = try LocalServicePolicy(serviceIdentifier: serviceIdentifier,
            trustedSelfRequirements: [selfPolicyKey: requirement(serviceIdentifier)],
            trustedPeerRequirements: [fullModulePolicyKey: requirement(hostIdentifier)])
        return try VoiceServicePolicy(native: native, serviceIdentifier: serviceIdentifier,
            moduleIdentifier: moduleIdentifier, fullModulePolicyKey: fullModulePolicyKey,
            capabilityPolicyKeys: [], lifecycleRoot: parent,
            resourceRevision: VoiceServicePolicy.viewsRevision(resources.appendingPathComponent("Views", isDirectory: true)),
            buildIdentifier: "native074." + version + "." + build, permitsGlobalControls: false)
    }
}
