import XCTest
import Foundation
@testable import ModuleApp

/// These are authored bundle/resource fixtures, not native identities. No test
/// starts the bootstrap, acquires an owner, opens the service parent or creates
/// a Voice product against any profile, model, audio device or account.
final class VoiceNativeEntry074Tests:XCTestCase {
    private struct Fixture {
        let root:URL
        let views:URL
        let bundle:Bundle
        init(identifier:String? = VoiceNativeEntry074.serviceIdentifier,
             kind:String? = "shared-service-v1",version:String = "0.22.6",build:String = "74",
             extra:[String:Any] = [:])throws{
            let temporary=URL(fileURLWithPath:try VoiceProductConfiguration.physicalPath(FileManager.default.temporaryDirectory),isDirectory:true)
            root=temporary.appendingPathComponent("VoiceNative074-"+UUID().uuidString+".app",isDirectory:true)
            views=root.appendingPathComponent("Contents/Resources/Views",isDirectory:true)
            try FileManager.default.createDirectory(at:views,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            var info=extra
            info["CFBundleIdentifier"]=identifier
            info["NeroVoiceRuntimeKind"]=kind
            info["CFBundlePackageType"]="APPL"
            info["CFBundleExecutable"]="ModuleApp"
            info["CFBundleShortVersionString"]=version
            info["CFBundleVersion"]=build
            try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:root.appendingPathComponent("Contents/Info.plist"))
            try Data("<html>Authored café 🌿</html>".utf8).write(to:views.appendingPathComponent("index.html"))
            guard let actual=Bundle(url:root)else{throw CocoaError(.fileReadCorruptFile)}
            bundle=actual
        }
        func remove(){try? FileManager.default.removeItem(at:root)}
    }
    func testActualPolicySeparatesServiceFromFullModuleAndKeepsEffectsClosed()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let policy=try VoiceNativeEntry074.policy(bundle:fixture.bundle)
        XCTAssertEqual(policy.serviceIdentifier,"cafe.nero.voice.isolated074")
        XCTAssertEqual(policy.moduleIdentifier,"cafe.nero.plugin.voice")
        XCTAssertNotEqual(policy.serviceIdentifier,policy.moduleIdentifier)
        XCTAssertEqual(policy.fullModulePolicyKey,"nook-isolated-adapter074")
        XCTAssertTrue(policy.capabilityPolicyKeys.isEmpty)
        XCTAssertFalse(policy.permitsGlobalControls)
        XCTAssertEqual(policy.lifecycleRoot.path,"/private/tmp/neronook-voice-pair074-501")
        XCTAssertEqual(policy.buildIdentifier,"native074.0.22.6.74")
    }
    func testNormalAndForeignBundleIdentifiersRefuseInsteadOfSelectingLegacy()throws{
        for identifier in ["cafe.nero.plugin.voice","foreign.voice"]{
            let fixture=try Fixture(identifier:identifier);defer{fixture.remove()}
            XCTAssertThrowsError(try VoiceNativeEntry074.policy(bundle:fixture.bundle))
        }
    }
    func testMissingBundleIdentifierRefuses()throws{
        let fixture=try Fixture(identifier:nil);defer{fixture.remove()}
        XCTAssertThrowsError(try VoiceNativeEntry074.policy(bundle:fixture.bundle))
    }
    func testMissingAndForeignRuntimeKindRefuse()throws{
        let kinds:[String?]=[nil,"legacy","unknown"]
        for kind in kinds{
            let fixture=try Fixture(kind:kind);defer{fixture.remove()}
            XCTAssertThrowsError(try VoiceNativeEntry074.policy(bundle:fixture.bundle))
        }
    }
    func testPolicyUsesActualCurrentViewsDigest()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let policy=try VoiceNativeEntry074.policy(bundle:fixture.bundle)
        XCTAssertEqual(policy.resourceRevision,try VoiceServicePolicy.viewsRevision(fixture.views))
        XCTAssertEqual(policy.resourceRevision.utf8.count,64)
    }
    func testChangedActualViewsChangePolicyRevisionWithoutChangingPrincipal()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let first=try VoiceNativeEntry074.policy(bundle:fixture.bundle)
        try Data("<html>Second authored resource</html>".utf8).write(to:fixture.views.appendingPathComponent("index.html"))
        let second=try VoiceNativeEntry074.policy(bundle:fixture.bundle)
        XCTAssertNotEqual(first.resourceRevision,second.resourceRevision)
        XCTAssertEqual(first.serviceIdentifier,second.serviceIdentifier)
        XCTAssertEqual(first.fullModulePolicyKey,second.fullModulePolicyKey)
        XCTAssertFalse(second.permitsGlobalControls)
    }
    func testMissingAndLinkedViewsRefuseWithoutFallback()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        try FileManager.default.removeItem(at:fixture.views)
        XCTAssertThrowsError(try VoiceNativeEntry074.policy(bundle:fixture.bundle))
        let authored=fixture.root.appendingPathComponent("AuthoredTarget",isDirectory:true)
        try FileManager.default.createDirectory(at:authored,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let bytes=Data("unchanged authored target".utf8),file=authored.appendingPathComponent("index.html")
        try bytes.write(to:file)
        try FileManager.default.createSymbolicLink(at:fixture.views,withDestinationURL:authored)
        XCTAssertThrowsError(try VoiceNativeEntry074.policy(bundle:fixture.bundle))
        XCTAssertEqual(try Data(contentsOf:file),bytes)
    }
    func testMetadataCannotExpandFixedNativeComposition()throws{
        let fixture=try Fixture(extra:[
            "NeroVoicePermitsGlobalControls":true,
            "NeroVoiceCapabilityPolicyKeys":["foreign-client"],
            "NeroVoiceServiceIdentifier":"foreign.service",
            "NeroVoicePublisherRequirement":"anchor trusted",
            "NeroVoiceEnrollmentMode":"existing",
            "NeroVoiceParent":"/authored-but-unselected"
        ]);defer{fixture.remove()}
        let policy=try VoiceNativeEntry074.policy(bundle:fixture.bundle)
        XCTAssertFalse(policy.permitsGlobalControls)
        XCTAssertTrue(policy.capabilityPolicyKeys.isEmpty)
        XCTAssertEqual(policy.serviceIdentifier,VoiceNativeEntry074.serviceIdentifier)
        XCTAssertEqual(policy.lifecycleRoot,VoiceNativeEntry074.parent)
        XCTAssertEqual(policy.fullModulePolicyKey,VoiceNativeEntry074.fullModulePolicyKey)
    }
    func testArtifactMetadataBoundsRefuseOversizedBinding()throws{
        let version=try Fixture(version:String(repeating:"v",count:33));defer{version.remove()}
        XCTAssertThrowsError(try VoiceNativeEntry074.policy(bundle:version.bundle))
        let build=try Fixture(build:String(repeating:"b",count:33));defer{build.remove()}
        XCTAssertThrowsError(try VoiceNativeEntry074.policy(bundle:build.bundle))
    }
    func testSeparateIsolatedTemplatePreservesEntireNormalSurface()throws{
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let normalURL=source.appendingPathComponent("Resources/SharedNookPlugin.template.json")
        let isolatedURL=source.appendingPathComponent("Resources/SharedNookPlugin.isolated074.template.json")
        let normal=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:normalURL)) as? [String:Any])
        var isolated=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:isolatedURL)) as? [String:Any])
        XCTAssertEqual(isolated["id"] as? String,VoiceNativeEntry074.moduleIdentifier)
        var descriptor=try XCTUnwrap(isolated["sharedApplication"] as? [String:Any])
        XCTAssertEqual(descriptor["serviceIdentifier"] as? String,VoiceNativeEntry074.serviceIdentifier)
        XCTAssertEqual(descriptor["connectorBundleIdentifier"] as? String,VoiceNativeEntry074.connectorIdentifier)
        let normalDescriptor=try XCTUnwrap(normal["sharedApplication"] as? [String:Any])
        descriptor["serviceIdentifier"]=normalDescriptor["serviceIdentifier"]
        descriptor["connectorBundleIdentifier"]=normalDescriptor["connectorBundleIdentifier"]
        isolated["sharedApplication"]=descriptor
        isolated["summary"]=normal["summary"]
        XCTAssertEqual(try JSONSerialization.data(withJSONObject:isolated,options:[.sortedKeys]),try JSONSerialization.data(withJSONObject:normal,options:[.sortedKeys]))
    }
}
