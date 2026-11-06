import XCTest
import Foundation
import Darwin
import NookPluginSDK
@testable import VoiceEditing
@testable import ModuleApp

private actor Appearance106Gate {
    private var opened=false
    private(set) var entered=false
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    func hold()async{entered=true;if opened{return};await withCheckedContinuation{waiters.append($0)}}
    func release(){opened=true;let originals=waiters;waiters.removeAll();for original in originals{original.resume()}}
}
private actor Appearance106Flag {
    private(set) var value=false
    func set(){value=true}
}

/// Actual product/store/return helpers with authored isolated roots only. These
/// tests never show NSWindow/NSPanel, access a default profile or run speech.
@MainActor final class VoiceAppearanceCustodyTests:XCTestCase {
    private struct Fixture:Sendable {
        let parent:URL
        let device:dev_t
        let inode:ino_t
        init()throws{
            parent=URL(fileURLWithPath:try VoiceProductConfiguration.physicalPath(FileManager.default.temporaryDirectory),isDirectory:true).appendingPathComponent("VoiceAppearance106-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            var info=stat();guard lstat(parent.path,&info)==0 else{throw CocoaError(.fileReadUnknown)}
            device=info.st_dev;inode=info.st_ino
        }
        func validate()throws{
            var info=stat();guard lstat(parent.path,&info)==0,info.st_dev==device,info.st_ino==inode,info.st_mode & S_IFMT == S_IFDIR else{throw CocoaError(.fileReadUnknown)}
        }
        func remove(){try? FileManager.default.removeItem(at:parent)}
        @MainActor func configuration()throws->VoiceProductConfiguration{
            try .isolated(root:parent.appendingPathComponent("Product",isDirectory:true),revalidate:{try self.validate()})
        }
    }
    private func message(_ revision:UInt64,session:UUID)->PluginMessage{
        .init(type:"appearance",pluginID:"test.voice",session:session,appearance:.init(revision:revision,shared:.init(revision:revision)))
    }
    private func waitFor(_ condition:@escaping ()async->Bool)async{
        for _ in 0..<10_000{if await condition(){return};await Task.yield()}
        XCTFail("Original operation did not enter")
    }
    func testPlaceholderMaterializesOneActualInertStoreAndRefusesReplacement()async throws{
        let owner=VoiceProductAppearance()
        XCTAssertFalse(owner.materialized)
        let original=owner.store
        XCTAssertTrue(owner.materialized);XCTAssertTrue(owner.store === original)
        XCTAssertThrowsError(try owner.prepareSharedService(observation:.system))
        XCTAssertTrue(owner.store === original)
        let result=await owner.sealForRetirement().value
        XCTAssertTrue(result)
    }
    func testPreparedHostStoreIsNeverReplacedOrPromoted()async throws{
        let owner=VoiceProductAppearance()
        try owner.prepareSharedService(observation:.hostDelivered)
        let original=owner.store
        try owner.prepareSharedService(observation:.hostDelivered)
        XCTAssertTrue(owner.store === original)
        XCTAssertThrowsError(try owner.prepareSharedService(observation:.system))
        let result=await owner.sealForRetirement().value;XCTAssertTrue(result)
    }
    func testUnusedRetiredOwnerCanOnlyMaterializeASealedInertStore()async{
        let owner=VoiceProductAppearance()
        let first=owner.sealForRetirement()
        XCTAssertFalse(owner.isPresentationAllowed);XCTAssertFalse(owner.materialized)
        let firstResult=await first.value;XCTAssertTrue(firstResult)
        let late=owner.store
        XCTAssertTrue(late.isRetiring);XCTAssertTrue(owner.store === late)
        XCTAssertThrowsError(try owner.prepareSharedService(observation:.system))
        XCTAssertFalse(late.update(.init(revision:1,shared:.init(revision:1))))
        let second=await owner.sealForRetirement().value;XCTAssertTrue(second)
    }
    func testActualSDKGuardsAndExactSessionEndPreserveReplacement()async{
        let owner=VoiceProductAppearance(),old=UUID(),replacement=UUID()
        owner.beginSession(pluginID:"test.voice",session:old)
        XCTAssertTrue(owner.receive(message(1,session:old)))
        owner.beginSession(pluginID:"test.voice",session:replacement)
        XCTAssertTrue(owner.receive(message(2,session:replacement)))
        XCTAssertFalse(owner.receive(message(3,session:old)))
        XCTAssertFalse(owner.receive(message(1,session:replacement)))
        var wrongAPI=message(3,session:replacement);wrongAPI.apiVersion=2
        XCTAssertFalse(owner.receive(wrongAPI))
        XCTAssertFalse(owner.endSession(pluginID:"test.voice",session:old))
        XCTAssertEqual(owner.store.delivery?.revision,2)
        XCTAssertTrue(owner.endSession(pluginID:"test.voice",session:replacement))
        XCTAssertNil(owner.store.delivery);XCTAssertFalse(owner.store.isRetiring)
        let retired=await owner.sealForRetirement().value;XCTAssertTrue(retired)
    }
    func testDeliveredFlagsAndDisplayContextUseActualSDKResolver()async{
        let owner=VoiceProductAppearance(),session=UUID()
        owner.beginSession(pluginID:"test.voice",session:session)
        var shared=PluginAppearanceContext(revision:4,reduceTransparency:true,reduceMotion:true)
        shared.increasedContrast=true
        var display=shared;display.surfaceID="authored-display";display.screenNumber=7
        var input=message(4,session:session);input.appearance = .init(revision:4,shared:shared,displays:[display])
        XCTAssertTrue(owner.receive(input))
        let actual=owner.store.context(screenNumber:7,fallback:.dark)
        XCTAssertEqual(actual.surfaceID,"authored-display");XCTAssertTrue(actual.reduceTransparency)
        XCTAssertTrue(actual.reduceMotion);XCTAssertTrue(actual.increasedContrast)
        let retired=await owner.sealForRetirement().value;XCTAssertTrue(retired)
    }
    func testFullActualPluginInjectsOneStoreAndPreservesRealSurfaces()async throws{
        let fixture=try Fixture();defer{fixture.remove()}
        let config=try fixture.configuration();try config.appearance.prepareSharedService(observation:.hostDelivered)
        let plugin=VoicePlugin(sharedService:true,configuration:config),original=config.appearance.store
        XCTAssertTrue(plugin.presentationAppearanceStore === original)
        XCTAssertTrue(plugin.model.presentationAppearanceStore === original)
        XCTAssertTrue(plugin.meetings.callPanel.presentationAppearanceStore === original)
        XCTAssertFalse(plugin.hasAmbientProductObservers);XCTAssertFalse(plugin.model.hasAmbientProductObservers)
        XCTAssertFalse(plugin.meetings.hasAmbientProductObservers);XCTAssertFalse(plugin.model.nativeSpeechOutputIsConstructed)
        let voice=plugin.model.voiceDefinition,meeting=plugin.meetings.definition
        XCTAssertEqual(voice.entry,"dictate/index.html");XCTAssertEqual(meeting.entry,"meetings/index.html")
        try voice.validate();try meeting.validate()
        let first=plugin.sealPresentationForRetirement(),second=plugin.sealPresentationForRetirement()
        XCTAssertFalse(config.appearance.isPresentationAllowed);XCTAssertTrue(original.isRetiring)
        let a=await first.value,b=await second.value
        XCTAssertTrue(a);XCTAssertTrue(b);XCTAssertFalse(plugin.model.nativeSpeechOutputIsConstructed)
    }
    func testOriginalReturnHandoffCannotBeReplacedAndCancelledWaiterStillJoins()async{
        let returns=VoicePresentationReturns(),gate=Appearance106Gate(),done=Appearance106Flag()
        let waiter=Task {let value=await returns.result();await done.set();return value}
        waiter.cancel()
        let original=Task {await gate.hold();return false}
        returns.install(original)
        returns.install(Task {true})
        await waitFor{await gate.entered}
        let before=await done.value;XCTAssertFalse(before)
        await gate.release()
        let result=await waiter.value;XCTAssertFalse(result)
        let again=await returns.result();XCTAssertFalse(again)
    }
    func testSelectionPresentationRetirementWaitsEnteredOriginalAndRefusesLateCallback()async throws{
        let admission=SelectionPresentationAdmission(),done=Appearance106Flag()
        let token=try XCTUnwrap(admission.begin())
        XCTAssertTrue(admission.current(token));XCTAssertTrue(admission.enterCallback())
        admission.seal()
        let waiter=Task {await admission.retirement();await done.set()};waiter.cancel()
        XCTAssertNil(admission.begin());XCTAssertFalse(admission.enterCallback())
        admission.finish()
        for _ in 0..<10{await Task.yield()}
        let before=await done.value;XCTAssertFalse(before)
        admission.finish();await waiter.value
        let after=await done.value;XCTAssertTrue(after)
    }
    func testSelectionOldGenerationCannotBecomeReplacementOrRestoreAfterSeal()throws{
        let admission=SelectionPresentationAdmission()
        let old=try XCTUnwrap(admission.begin());admission.invalidate()
        let replacement=try XCTUnwrap(admission.begin())
        XCTAssertFalse(admission.current(old));XCTAssertTrue(admission.current(replacement))
        admission.finish();XCTAssertTrue(admission.current(replacement))
        admission.seal();XCTAssertFalse(admission.current(replacement));XCTAssertFalse(admission.enterCallback())
        admission.finish()
    }
    func testRetiringOneAppearanceOwnerDoesNotRetireIndependentOwner()async{
        let a=VoiceProductAppearance(),b=VoiceProductAppearance(),session=UUID()
        b.beginSession(pluginID:"test.voice",session:session)
        let result=await a.sealForRetirement().value;XCTAssertTrue(result)
        XCTAssertTrue(b.isPresentationAllowed);XCTAssertFalse(b.store.isRetiring)
        XCTAssertTrue(b.receive(message(1,session:session)))
        let second=await b.sealForRetirement().value;XCTAssertTrue(second)
    }
}


extension VoiceAppearanceCustodyTests {
    func testSelectionNativeTeardownReturnFenceKeepsReceiptPending()async{
        let admission=SelectionPresentationAdmission(),done=Appearance106Flag()
        // Same production method called before actual delegate/content/close.
        admission.holdTeardownReturn()
        XCTAssertTrue(admission.closed);XCTAssertFalse(admission.enterCallback())
        let receipt=Task {await admission.retirement();await done.set()}
        receipt.cancel()
        for _ in 0..<10{await Task.yield()}
        let before=await done.value;XCTAssertFalse(before)
        admission.finish() // Actual synchronous native-close frame returns.
        await receipt.value
        let after=await done.value;XCTAssertTrue(after)
    }
    func testStoreConstructionReceiptWaitsExactOriginalStoreHandoff()async{
        let construction=VoiceAppearanceConstruction(),done=Appearance106Flag()
        let receipt=Task {let result=await construction.retirement();await done.set();return result}
        receipt.cancel()
        for _ in 0..<10{await Task.yield()}
        let before=await done.value;XCTAssertFalse(before)
        let original=PluginAppearanceStore(observation:.hostDelivered)
        construction.finish(original)
        let result=await receipt.value;XCTAssertTrue(result);XCTAssertTrue(original.isRetiring)
    }
    func testActualStoreConstructorReentrantStopCannotPublishLiveStore()async{
        var owner:VoiceProductAppearance!
        var receipt:Task<Bool,Never>?
        var returned:PluginAppearanceStore?
        var reentrant:PluginAppearanceStore?
        owner=VoiceProductAppearance(makeStore:{mode in
            XCTAssertTrue(mode == .system)
            receipt=owner.sealForRetirement()
            XCTAssertFalse(owner.isPresentationAllowed)
            reentrant=owner.store
            XCTAssertTrue(reentrant?.isRetiring == true)
            let actual=PluginAppearanceStore(observation:.hostDelivered)
            returned=actual;return actual
        })
        XCTAssertThrowsError(try owner.prepareSharedService(observation:.system))
        XCTAssertFalse(owner.materialized)
        XCTAssertTrue(owner.store === reentrant)
        XCTAssertFalse(owner.store === returned)
        XCTAssertTrue(returned?.isRetiring == true)
        let result=await receipt?.value;XCTAssertEqual(result,true)
        let again=await owner.sealForRetirement().value;XCTAssertTrue(again)
    }
    func testActualConstructorReentrantGetterIsSealedAndCannotReplaceOriginal()async throws{
        var owner:VoiceProductAppearance!
        var reentrant:PluginAppearanceStore?
        var original:PluginAppearanceStore?
        owner=VoiceProductAppearance(makeStore:{_ in
            reentrant=owner.store
            XCTAssertTrue(reentrant?.isRetiring == true)
            XCTAssertFalse(owner.materialized)
            let actual=PluginAppearanceStore(observation:.hostDelivered)
            original=actual;return actual
        })
        try owner.prepareSharedService(observation:.system)
        XCTAssertTrue(owner.store === original)
        XCTAssertFalse(owner.store === reentrant)
        XCTAssertFalse(owner.store.isRetiring)
        let result=await owner.sealForRetirement().value;XCTAssertTrue(result)
        XCTAssertTrue(original?.isRetiring == true)
    }
}


extension VoiceAppearanceCustodyTests {
    func testReusedSelectionSurfaceRefusesRetainedOldActions()throws{
        let admission=SelectionPresentationAdmission(),surface=NSObject(),foreign=NSObject()
        let old=try XCTUnwrap(admission.begin());admission.bind(surface,token:old)
        var accepted=0
        let oldAction={if admission.permits(surface,token:old){accepted += 1}}
        oldAction();XCTAssertEqual(accepted,1)
        admission.invalidate()
        let next=try XCTUnwrap(admission.begin());admission.bind(surface,token:next)
        oldAction();XCTAssertEqual(accepted,1)
        XCTAssertFalse(admission.permits(foreign,token:next));XCTAssertTrue(admission.permits(surface,token:next))
        admission.finish();admission.finish();admission.seal()
        XCTAssertFalse(admission.permits(surface,token:next))
    }
    func testReusedOverlaySurfaceRequiresCapturedTokenAndOriginalObject(){
        let bindings=DictationOverlayBindings(),surface=NSObject(),foreign=NSObject(),old=UUID(),next=UUID()
        bindings.bind(surface,token:old)
        var accepted=0
        let oldAction={if bindings.permits(surface,token:old){accepted += 1}}
        oldAction();XCTAssertEqual(accepted,1)
        bindings.invalidate();bindings.bind(surface,token:next)
        oldAction();XCTAssertEqual(accepted,1)
        XCTAssertFalse(bindings.permits(foreign,token:next));XCTAssertTrue(bindings.permits(surface,token:next))
        bindings.invalidate();XCTAssertFalse(bindings.permits(surface,token:next))
    }
}


import ModuleCore
import SwiftUI

@MainActor private final class Appearance115Editor:SelectionEditor {
    private(set) var calls=0
    func capture()throws->SelectionCapture{calls += 1;throw SelectionProblem.unavailable}
    func replace(_ capture:SelectionCapture,with text:String)async throws->DictationEdit{calls += 1;throw SelectionProblem.unavailable}
    func undo(_ capture:SelectionCapture,edit:DictationEdit)async throws{calls += 1;throw SelectionProblem.unavailable}
    func forget(){calls += 1}
    func restoreFocus(){calls += 1}
}

extension VoiceAppearanceCustodyTests {
    func testActualRewriteBindingsRejectOldPresentationAndSealedOwner()throws{
        let editor=Appearance115Editor()
        // The dedicated editor below remains untouched: binding edits never
        // capture/replace/undo/focus. No model work or editor effect is started.
        let actual=SelectionRewrite(editor:editor){_,_ in "unused"}
        actual.result="initial"
        let admission=SelectionPresentationAdmission(),surface=NSObject()
        let old=try XCTUnwrap(admission.begin());admission.bind(surface,token:old)
        let oldView=SelectionRewriteView(model:actual,perform:{work in
            guard admission.permits(surface,token:old),admission.enterCallback()else{return}
            defer{admission.finish()};work()
        })
        let oldText=oldView.resultBinding,oldOperation=oldView.operationBinding
        oldText.wrappedValue="current original";oldOperation.wrappedValue = .clarify
        XCTAssertEqual(actual.result,"current original");XCTAssertEqual(actual.operation,.clarify)
        admission.invalidate()
        let next=try XCTUnwrap(admission.begin());admission.bind(surface,token:next)
        actual.result="replacement";actual.operation = .formal
        oldText.wrappedValue="stale text";oldOperation.wrappedValue = .friendly
        XCTAssertEqual(actual.result,"replacement");XCTAssertEqual(actual.operation,.formal)
        // Getters deliberately remain current model reads.
        XCTAssertEqual(oldText.wrappedValue,"replacement");XCTAssertEqual(oldOperation.wrappedValue,.formal)
        let currentView=SelectionRewriteView(model:actual,perform:{work in
            guard admission.permits(surface,token:next),admission.enterCallback()else{return}
            defer{admission.finish()};work()
        })
        let currentText=currentView.resultBinding,currentOperation=currentView.operationBinding
        currentText.wrappedValue="current replacement";currentOperation.wrappedValue = .rephrase
        XCTAssertEqual(actual.result,"current replacement");XCTAssertEqual(actual.operation,.rephrase)
        admission.seal()
        currentText.wrappedValue="after Stop";currentOperation.wrappedValue = .improve
        XCTAssertEqual(actual.result,"current replacement");XCTAssertEqual(actual.operation,.rephrase)
        admission.finish();admission.finish()
        XCTAssertEqual(editor.calls,0)
    }
    func testDefaultActualRewriteBindingSettersRemainImmediate(){
        let editor=Appearance115Editor()
        let actual=SelectionRewrite(editor:editor){_,_ in "unused"}
        let view=SelectionRewriteView(model:actual)
        let text=view.resultBinding,operation=view.operationBinding
        text.wrappedValue="ordinary standalone preview";operation.wrappedValue = .friendly
        XCTAssertEqual(actual.result,"ordinary standalone preview");XCTAssertEqual(actual.operation,.friendly)
        XCTAssertEqual(text.wrappedValue,actual.result);XCTAssertEqual(operation.wrappedValue,actual.operation)
        XCTAssertEqual(editor.calls,0)
    }
}
