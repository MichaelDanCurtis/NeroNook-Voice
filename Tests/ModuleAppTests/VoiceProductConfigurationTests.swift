import XCTest
import Foundation
import Darwin
import ModuleCore
import VoiceAudio
import NookPluginSDK
@testable import ModuleApp

/// Real product construction and genuine isolated stores. No production
/// profile, GUI, permission, native speech/capture, account or model is used.
@MainActor final class VoiceProductConfigurationTests:XCTestCase {
    private struct Fixture:Sendable {
        let parent:URL
        let device:dev_t
        let inode:ino_t
        init()throws{
            parent=URL(fileURLWithPath:try VoiceProductConfiguration.physicalPath(FileManager.default.temporaryDirectory),isDirectory:true).appendingPathComponent("VoiceProduct058-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            var info=stat();guard lstat(parent.path,&info)==0 else{throw CocoaError(.fileReadUnknown)}
            device=info.st_dev;inode=info.st_ino
        }
        func validate()throws{
            var info=stat()
            guard lstat(parent.path,&info)==0,info.st_dev==device,info.st_ino==inode,info.st_mode & S_IFMT == S_IFDIR else{throw CocoaError(.fileReadUnknown)}
        }
        @MainActor func configuration()throws->VoiceProductConfiguration{
            try .isolated(root:parent.appendingPathComponent("Product",isDirectory:true),revalidate:{try self.validate()})
        }
        func remove(){try? FileManager.default.removeItem(at:parent)}
    }
    func testFullActualPluginUsesIsolatedRealStores()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let configuration=try fixture.configuration()
        let plugin=VoicePlugin(sharedService:true,configuration:configuration)
        XCTAssertTrue(plugin.configuration === configuration)
        XCTAssertTrue(plugin.model.configuration === configuration)
        XCTAssertTrue(plugin.meetings.configuration === configuration)
        XCTAssertTrue(plugin.conversation.configuration === configuration)
        let store=try XCTUnwrap(plugin.meetings.store)
        let meeting=Meeting(title:"Authored sample",source:"",microphone:false)
        try store.save(meeting)
        plugin.meetings.refresh()
        XCTAssertEqual(plugin.meetings.library.map(\.id),[meeting.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath:configuration.meetingsRoot.appendingPathComponent(meeting.id.uuidString).path))
    }
    func testActualFullConstructionDoesNotInstallAmbientObserversOrSpeechOutput()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let plugin=VoicePlugin(sharedService:true,configuration:try fixture.configuration())
        XCTAssertFalse(plugin.hasAmbientProductObservers)
        XCTAssertFalse(plugin.model.hasAmbientProductObservers)
        XCTAssertFalse(plugin.meetings.hasAmbientProductObservers)
        XCTAssertFalse(plugin.conversation.hasAmbientProductObservers)
        XCTAssertFalse(plugin.model.nativeSpeechOutputIsConstructed)
        XCTAssertTrue(plugin.model.microphones.isEmpty)
        XCTAssertTrue(plugin.meetings.sources.isEmpty)
        XCTAssertTrue(plugin.model.speechVoices.isEmpty)
        XCTAssertNil(plugin.model.selectedSpeechVoice)
    }
    func testActualVoiceAndMeetingCustomSurfacesRemainPresent()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let plugin=VoicePlugin(sharedService:true,configuration:try fixture.configuration())
        let voice=plugin.model.voiceDefinition
        XCTAssertEqual(voice.entry,"dictate/index.html")
        XCTAssertEqual(Set(voice.events.map(\.id)),Set(["personal","shortcut","captions","speech","provider","microphone","command","edit"]))
        let meetings=plugin.meetings.definition
        XCTAssertEqual(meetings.entry,"meetings/index.html")
        XCTAssertFalse(meetings.events.isEmpty)
        try voice.validate();try meetings.validate()
        XCTAssertFalse(plugin.model.nativeSpeechOutputIsConstructed)
    }
    func testRealPersonalizationSaveAndReloadUsesIsolatedStore()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let configuration=try fixture.configuration()
        let model=VoiceModel(configuration:configuration)
        var value=DictationPersonalization()
        value.snippets=[.init(name:"My note",text:"Authored local snippet")]
        try model.savePersonalization(value)
        let actual=try DictationPersonalizationStore(root:configuration.dictationRoot)
        XCTAssertEqual(try actual.configuration(),value)
        XCTAssertEqual(model.personalization,value)
    }
    func testRootLocalPreferencesPersistWithoutTouchingAuthoredLegacySentinel()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let sentinel=fixture.parent.appendingPathComponent("legacy-sentinel")
        try Data("unchanged".utf8).write(to:sentinel)
        let configuration=try fixture.configuration()
        let model=VoiceModel(configuration:configuration)
        model.microphone="authored-device-choice"
        model.dictionary="café 🌿"
        let readback=try VoiceProductPreferences(root:try XCTUnwrap(configuration.root),revalidate:{try fixture.validate()})
        XCTAssertEqual(readback.string(forKey:"microphone"),"authored-device-choice")
        XCTAssertEqual(readback.string(forKey:"dictionary"),"café 🌿")
        XCTAssertEqual(try Data(contentsOf:sentinel),Data("unchanged".utf8))
    }
    func testIndependentProductInstancesHaveSeparatePreferences()throws{
        let a=try Fixture(),b=try Fixture();defer{a.remove();b.remove()}
        let first=try a.configuration(),second=try b.configuration()
        first.preferences.set("A",forKey:"locale")
        second.preferences.set("B",forKey:"locale")
        XCTAssertEqual(first.preferences.string(forKey:"locale"),"A")
        XCTAssertEqual(second.preferences.string(forKey:"locale"),"B")
        XCTAssertNotEqual(first.meetingsRoot,second.meetingsRoot)
    }
    func testAllEffectCategoriesRemainClosed()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let configuration=try fixture.configuration()
        for effect in VoiceProductConfiguration.Effect.allCases{
            XCTAssertFalse(configuration.allows(effect))
            XCTAssertThrowsError(try configuration.require(effect))
        }
        XCTAssertEqual(configuration.denied.count,VoiceProductConfiguration.Effect.allCases.count)
    }
    func testDirectDictationAndPreparationCannotStartEffects()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let model=VoiceModel(configuration:try fixture.configuration())
        model.record();model.prepareConversation();model.prepareAssets();model.prepareLocalModel();model.prepareQwen()
        XCTAssertFalse(model.session.recording)
        XCTAssertFalse(model.preparingAssets)
        XCTAssertFalse(model.preloader.busy)
        XCTAssertFalse(model.nativeSpeechOutputIsConstructed)
        XCTAssertFalse(model.selectedModelReady)
        XCTAssertFalse(model.qwenReady)
    }
    func testSpeechAndReactionRefuseBeforeConstructingOutput()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let model=VoiceModel(configuration:try fixture.configuration())
        XCTAssertThrowsError(try model.renderSpeech("Authored speech"))
        XCTAssertThrowsError(try model.speakShared("Authored reaction"))
        model.previewSpeech();model.stopSpeaking();model.releaseSpeakingModel()
        XCTAssertFalse(model.nativeSpeechOutputIsConstructed)
        XCTAssertFalse(model.speaking)
    }
    func testTalkRefusesBeforePermissionAndCheckpoint()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let configuration=try fixture.configuration(),model=VoiceModel(configuration:configuration)
        var entered=false
        let provider=ConversationProvider(preparationCheckpoint:{entered=true},configuration:configuration)
        XCTAssertThrowsError(try provider.start(UUID(),values:["mode":.string("full")],preferences:model,available:true))
        XCTAssertFalse(entered)
        XCTAssertFalse(provider.active)
        XCTAssertFalse(provider.preparationIsOwned)
    }
    func testAXHotkeyAndDeviceControlsCannotRegisterOrDiscover()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let model=VoiceModel(configuration:try fixture.configuration())
        model.requestInsertionPermission();model.beginSelectionRewrite();model.configureHotkey();model.refreshDevices();model.refreshStyleApps()
        model.chooseShortcut(.optionCommand)
        XCTAssertEqual(model.shortcut,.optionCommand)
        XCTAssertFalse(model.accessibilityAllowed)
        XCTAssertFalse(model.rewrite.active)
        XCTAssertTrue(model.microphones.isEmpty)
        XCTAssertGreaterThan(model.configuration.denied[.globalControls] ?? 0,0)
    }
    func testMeetingCaptureDiarizationAndPreparationRefuseBeforeAdmission()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let model=MeetingModel(configuration:try fixture.configuration())
        model.start(title:"Authored meeting",mic:true,source:"",live:true)
        model.process("prepare");model.process("prepareASR");model.process("speakers")
        model.startCallDetection();model.play();model.startLiveFixture()
        XCTAssertFalse(model.active)
        XCTAssertFalse(model.processing)
        XCTAssertFalse(model.playing)
        XCTAssertTrue(model.library.isEmpty)
        XCTAssertFalse(model.speakersReady)
        XCTAssertFalse(model.selectedASRReady)
    }
    func testCalendarAndQuestionCannotInvokeExternalProviders()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let model=MeetingModel(configuration:try fixture.configuration())
        var invoked=0
        model.invokeCalendar={_,_,_ in invoked += 1}
        model.invokeQuestion={_,_,_ in invoked += 1}
        model.listCalendar(day:"today",provider:"");model.verifyCalendar(open:true);model.sendQuestion()
        XCTAssertEqual(invoked,0)
        XCTAssertFalse(model.askingQuestion)
        XCTAssertFalse(model.calendarBusy)
        XCTAssertGreaterThan(model.configuration.denied[.provider] ?? 0,0)
    }
    func testNativeWindowsAndImportPickersAreDeniedWithoutChangingSurface()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let plugin=VoicePlugin(sharedService:true,configuration:try fixture.configuration())
        plugin.showWindow();plugin.showQwenWindow();plugin.showMicrophoneWindow()
        plugin.model.importQwenReference();plugin.meetings.chooseRecordingImport()
        XCTAssertNil(plugin.model.referencePicker)
        XCTAssertFalse(plugin.meetings.choosingImport)
        XCTAssertEqual(plugin.model.voiceDefinition.entry,"dictate/index.html")
        XCTAssertEqual(plugin.meetings.definition.entry,"meetings/index.html")
    }
    func testExistingProductDirectoryIsNeverSilentlyReused()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        _=try fixture.configuration()
        XCTAssertThrowsError(try fixture.configuration())
    }
    func testSamePathProductReplacementRefusesDataAdmissionAndPreferences()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let configuration=try fixture.configuration(),model=VoiceModel(configuration:configuration)
        let root=try XCTUnwrap(configuration.root)
        try FileManager.default.moveItem(at:root,to:fixture.parent.appendingPathComponent("oldProduct"))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        XCTAssertThrowsError(try configuration.validateData())
        model.dictionary="must not be written"
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("preferences.plist").path))
        XCTAssertThrowsError(try configuration.validateData())
        XCTAssertNil(configuration.preferences.string(forKey:"dictionary"))
        XCTAssertNotNil(configuration.preferences.issue)
    }
    func testSamePathMeetingChildReplacementRefusesStoreRefresh()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let configuration=try fixture.configuration(),model=MeetingModel(configuration:configuration)
        let root=configuration.meetingsRoot
        try FileManager.default.moveItem(at:root,to:root.deletingLastPathComponent().appendingPathComponent("oldMeetings"))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        XCTAssertFalse(model.permitMeetingWork())
        model.refresh()
        XCTAssertTrue(model.library.isEmpty)
    }
    func testGenesisRevalidationFailurePrecedesAnyProductCreation()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let product=fixture.parent.appendingPathComponent("Product")
        XCTAssertThrowsError(try VoiceProductConfiguration.isolated(root:product,revalidate:{throw CocoaError(.fileReadUnknown)}))
        XCTAssertFalse(FileManager.default.fileExists(atPath:product.path))
    }
    func testProductSymlinkRefusesWithoutFollowingTarget()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let target=fixture.parent.appendingPathComponent("authoredTarget")
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try FileManager.default.createSymbolicLink(at:fixture.parent.appendingPathComponent("Product"),withDestinationURL:target)
        XCTAssertThrowsError(try fixture.configuration())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:target.path),[])
    }
    func testLegacyConfigurationDefaultsRemainPermissiveWithoutConstructingProduct()throws{
        let configuration=VoiceProductConfiguration.legacy
        XCTAssertFalse(configuration.isolated)
        XCTAssertNil(configuration.root)
        for effect in VoiceProductConfiguration.Effect.allCases{XCTAssertTrue(configuration.allows(effect))}
        // Do not instantiate the legacy product or read its preferences/store.
    }
    func testDeliveredAppearanceChecksSessionAndRevisionWithoutReplacingRealSurfaces()throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let configuration=try fixture.configuration()
        let plugin=VoicePlugin(sharedService:true,configuration:configuration)
        let voice=plugin.model.voiceDefinition,meetings=plugin.meetings.definition
        let appearance=configuration.appearance,session=UUID()
        appearance.beginSession(pluginID:plugin.id,session:session)
        let initial=PluginAppearanceDelivery(revision:10,shared:.init(revision:10,mode:.dark,scheme:.dark,reduceMotion:true))
        try initial.validate()
        appearance.receive(.init(type:"appearance",pluginID:plugin.id,session:session,appearance:initial))
        XCTAssertEqual(appearance.context(.light).scheme,.dark)
        XCTAssertTrue(appearance.context(.light).reduceMotion)
        let newer=PluginAppearanceDelivery(revision:11,shared:.init(revision:11,mode:.light,scheme:.light))
        appearance.receive(.init(type:"appearance",pluginID:plugin.id,session:UUID(),appearance:newer))
        XCTAssertEqual(appearance.delivery,initial)
        appearance.receive(.init(type:"appearance",pluginID:"foreign.module",session:session,appearance:newer))
        XCTAssertEqual(appearance.delivery,initial)
        let stale=PluginAppearanceDelivery(revision:9,shared:.init(revision:9,mode:.light,scheme:.light))
        appearance.receive(.init(type:"appearance",pluginID:plugin.id,session:session,appearance:stale))
        XCTAssertEqual(appearance.delivery,initial)
        appearance.receive(.init(type:"appearance",pluginID:plugin.id,session:session,appearance:newer))
        XCTAssertEqual(appearance.delivery,newer)
        XCTAssertEqual(appearance.context(.dark).scheme,.light)
        XCTAssertEqual(plugin.model.voiceDefinition.events,voice.events)
        XCTAssertEqual(plugin.meetings.definition.events,meetings.events)
        XCTAssertFalse(plugin.hasAmbientProductObservers)
        XCTAssertFalse(plugin.model.nativeSpeechOutputIsConstructed)
    }

}
