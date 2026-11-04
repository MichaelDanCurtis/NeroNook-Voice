import XCTest
import AppKit
import SwiftUI
import Security
import Foundation
import NookLocalServiceKit
@testable import ModuleApp

/// Only windows created here are ordered/closed. No app activation/global
/// window enumeration, synthetic isVisible, default profile or product exists.
@MainActor final class EnrollmentOwnedTestWindow {
    let anchor = VoiceEnrollmentWindowAnchor()
    let window: NSWindow
    init(bootstrap: VoiceServiceBootstrap? = nil) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 160),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Authored enrollment anchor fixture"
        if let bootstrap {
            window.contentView = NSHostingView(rootView: VoiceNormalSetupView(bootstrap: bootstrap, anchor: anchor))
        } else {
            window.contentView = VoiceEnrollmentAnchorView(anchor: anchor)
        }
        window.orderFront(nil) // Never makeKey/activate an unrelated application.
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func close() { window.close() }
}

@MainActor private final class EnrollmentSheetProbe {
    var parent: NSWindow?
    var starts = 0, ends = 0, forbiddenMaterializations = 0
    var registered = false
    var callback: VoiceNativeEnrollmentPrompt.SheetReply?
    var duringBegin: (() -> Void)?
    var duringEnd: (() -> Void)?
    func prompt(keyWindow: @escaping @MainActor () -> NSWindow?) -> VoiceNativeEnrollmentPrompt {
        VoiceNativeEnrollmentPrompt(keyWindow: keyWindow, beginSheet: { [self] _, parent, reply in
            starts += 1; self.parent = parent; callback = reply
            duringBegin?() // May cancel in the real registration gap.
            registered = true
        }, endSheet: { [self] _, _ in ends += 1; duringEnd?() },
           canEndSheet: { [self] _, parent in registered && self.parent === parent })
    }
    func reply(_ response: NSApplication.ModalResponse) {
        let original = callback; callback = nil; registered = false; original?(response)
    }
}

@MainActor private final class EnrollmentWindowFixture {
    let base: URL, policy: VoiceServicePolicy, bootstrap: VoiceServiceBootstrap
    let owned: EnrollmentOwnedTestWindow, probe: EnrollmentSheetProbe
    let prompt: VoiceNativeEnrollmentPrompt
    var returned = false
    private var observation: Task<Void, Never>?
    init(base: URL, policy: VoiceServicePolicy, bootstrap: VoiceServiceBootstrap,
         owned: EnrollmentOwnedTestWindow, probe: EnrollmentSheetProbe, prompt: VoiceNativeEnrollmentPrompt) {
        self.base=base;self.policy=policy;self.bootstrap=bootstrap;self.owned=owned;self.probe=probe;self.prompt=prompt
    }
    func request() {
        // Same actual static action used by the production SwiftUI Button.
        VoiceNormalSetupView.requestSetup(bootstrap: bootstrap, anchor: owned.anchor)
        if let original=bootstrap.enrollmentCompletion {
            observation=Task { [self] in await original.value;returned=true }
        } else { returned=true }
    }
    func waitForPresentationOrReturn() async throws {
        let deadline=ContinuousClock.now + .seconds(5)
        while probe.starts == 0 && !returned {
            guard ContinuousClock.now < deadline else { throw NSError(domain:"fixture-original-or-presentation-timeout",code:1) }
            await Task.yield()
        }
    }
    func waitForReturn() async throws {
        let deadline=ContinuousClock.now + .seconds(5)
        while !returned {
            guard ContinuousClock.now < deadline else { throw NSError(domain:"fixture-original-return-timeout",code:1) }
            await Task.yield()
        }
    }
    func finish() async {
        // Release the captured callback on every assertion/throw path before
        // joining the original. No fresh prompt can replace this one.
        probe.reply(.cancel)
        await bootstrap.enrollmentCompletion?.value
        await observation?.value
        if !bootstrap.retirementRequested {
            let stopped=await bootstrap.shutdown();XCTAssertTrue(stopped)
        }
        XCTAssertNil(bootstrap.runtime);XCTAssertNil(bootstrap.legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath:policy.lifecycleRoot.path))
        XCTAssertEqual(probe.forbiddenMaterializations,0)
        probe.duringBegin=nil;probe.duringEnd=nil;probe.parent=nil
        owned.close()
        if FileManager.default.fileExists(atPath:policy.lifecycleRoot.path) {
            XCTFail("Unexpected authored lifecycle preserved for diagnosis at \(base.path)")
        } else {
            do { try FileManager.default.removeItem(at:base) } catch { XCTFail("Fixture cleanup: \(error)") }
        }
    }
}

final class VoiceEnrollmentWindowAnchorTests: XCTestCase {
    @MainActor private func withFixture(keyWindow: @escaping @MainActor () -> NSWindow? = { nil },
        _ body: @MainActor (EnrollmentWindowFixture) async throws -> Void) async throws {
        // Same real native-self principal as the prior enrollment fixtures;
        // only this test's fresh temp root may be inspected, never enrolled.
        var code:SecCode?,staticCode:SecStaticCode?,requirement:SecRequirement?,text:CFString?
        XCTAssertEqual(SecCodeCopySelf(SecCSFlags(),&code),errSecSuccess)
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code),SecCSFlags(),&staticCode),errSecSuccess)
        XCTAssertEqual(SecCodeCopyDesignatedRequirement(try XCTUnwrap(staticCode),SecCSFlags(),&requirement),errSecSuccess)
        XCTAssertEqual(SecRequirementCopyString(try XCTUnwrap(requirement),SecCSFlags(),&text),errSecSuccess)
        let service="test.nero.window.s"+UUID().uuidString.lowercased().replacingOccurrences(of:"-",with:"")
        let native=try LocalServicePolicy(serviceIdentifier:service,
            trustedSelfRequirements:["window-test":try XCTUnwrap(text) as String],
            trustedPeerRequirements:["window-test":try XCTUnwrap(text) as String])
        let base=URL(fileURLWithPath:"/private/tmp/nero-window-enrollment-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let policy=try VoiceServicePolicy(native:native,serviceIdentifier:service,moduleIdentifier:service,
            fullModulePolicyKey:"window-test",capabilityPolicyKeys:[],
            lifecycleRoot:base.appendingPathComponent("NeroVoice/ServiceLifecycle",isDirectory:true),
            resourceRevision:String(repeating:"0",count:64),buildIdentifier:"window-authored",permitsGlobalControls:true)
        let probe=EnrollmentSheetProbe(),prompt=probe.prompt(keyWindow:keyWindow)
        let bootstrap=VoiceServiceBootstrap(normalPolicy:policy,prompt:{prompt},beforeMaterialization:{ [probe] _ in
            // Test-environment fuse on the actual product construction boundary,
            // not a fake eligibility path. A late-accept regression still fails
            // the real no-history assertion, and cannot construct VoicePlugin.
            probe.forbiddenMaterializations += 1
            XCTFail("Forbidden product materialization in an authored window fixture")
            withUnsafeCurrentTask { $0?.cancel() }
        })
        await bootstrap.startupCompletion?.value
        let owned=EnrollmentOwnedTestWindow(bootstrap:bootstrap)
        let fixture=EnrollmentWindowFixture(base:base,policy:policy,bootstrap:bootstrap,owned:owned,probe:probe,prompt:prompt)
        do {
            XCTAssertTrue(bootstrap.canEnroll)
            let deadline=ContinuousClock.now + .seconds(5)
            while owned.anchor.capture() == nil {
                guard ContinuousClock.now < deadline else { throw NSError(domain:"real-owned-view-window-not-attached-visible",code:1) }
                owned.window.contentView?.layoutSubtreeIfNeeded();await Task.yield()
            }
            try await body(fixture)
            await fixture.finish()
        } catch {
            await fixture.finish();throw error
        }
    }

    @MainActor func testOwnedSetupViewPresentsOnCapturedParentWhenNoWindowIsKey() async throws {
        try await withFixture { f in
            XCTAssertTrue(f.owned.window.isVisible)
            f.request();try await f.waitForPresentationOrReturn()
            // Sole intended old-behavior failure: getter=nil cancels without
            // calling the genuine prompt's sheet presenter. Not proof of144.
            XCTAssertEqual(f.probe.starts,1,"A view-owned parent must not require NSApp.keyWindow")
            if f.probe.starts == 1 { XCTAssertTrue(f.probe.parent === f.owned.window) }
            f.probe.reply(.cancel);try await f.waitForReturn()
            XCTAssertNil(f.bootstrap.runtime);XCTAssertNil(f.bootstrap.legacy)
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.policy.lifecycleRoot.path))
        }
    }
    @MainActor func testMissingDetachedAndClosedParentsCannotBecomeUserConsent() async throws {
        try await withFixture { f in
            f.bootstrap.requestNormalEnrollment(from:nil)
            XCTAssertNil(f.bootstrap.enrollmentCompletion)
            let old=try XCTUnwrap(f.owned.anchor.capture())
            f.owned.window.contentView=nil
            XCTAssertFalse(old.isCurrent);XCTAssertNil(f.owned.anchor.capture())
            f.bootstrap.requestNormalEnrollment(from:old)
            XCTAssertNil(f.bootstrap.enrollmentCompletion);XCTAssertEqual(f.probe.starts,0)
            f.owned.close();f.request();try await f.waitForPresentationOrReturn()
            XCTAssertEqual(f.probe.starts,0);XCTAssertFalse(f.bootstrap.status.contains("Setup cancelled"))
        }
    }
    @MainActor func testReplacementAndUnrelatedKeyWindowNeverRetargetCapturedParent() async throws {
        let unrelated=EnrollmentOwnedTestWindow();defer{unrelated.close()}
        try await withFixture(keyWindow:{unrelated.window}) { f in
            let old=try XCTUnwrap(f.owned.anchor.capture())
            // Valid selection ignores even a genuine other owned window.
            f.request();try await f.waitForPresentationOrReturn()
            XCTAssertEqual(f.probe.starts,1);XCTAssertTrue(f.probe.parent === f.owned.window)
            f.probe.reply(.cancel);try await f.waitForReturn()
            // Replacing the real representable view invalidates its prior token.
            f.owned.window.contentView=VoiceEnrollmentAnchorView(anchor:f.owned.anchor)
            XCTAssertFalse(old.isCurrent)
            f.bootstrap.requestNormalEnrollment(from:old)
            XCTAssertEqual(f.probe.starts,1)
        }
    }
    @MainActor func testDetachDuringPresentationCancelsExactSheetAndRejectsLateAccept() async throws {
        try await withFixture { f in
            f.request();try await f.waitForPresentationOrReturn()
            guard f.probe.starts == 1 else { return XCTFail("No presentation; original may have returned, not hung") }
            f.owned.window.contentView=nil
            XCTAssertEqual(f.probe.ends,1);XCTAssertFalse(f.returned)
            f.probe.reply(.alertFirstButtonReturn);try await f.waitForReturn()
            XCTAssertNil(f.bootstrap.runtime);XCTAssertFalse(FileManager.default.fileExists(atPath:f.policy.lifecycleRoot.path))
        }
    }
    @MainActor func testDoubleClickUsesOneCapturedOriginalPrompt() async throws {
        try await withFixture { f in
            f.request();f.request();try await f.waitForPresentationOrReturn()
            XCTAssertEqual(f.probe.starts,1)
            f.probe.reply(.cancel);try await f.waitForReturn()
            XCTAssertTrue(f.bootstrap.canEnroll)
        }
    }
    @MainActor func testQuitWaitsOriginalCallbackAndRejectsLateAccept() async throws {
        try await withFixture { f in
            f.request();try await f.waitForPresentationOrReturn()
            guard f.probe.starts == 1 else { return XCTFail("No presentation; original may have returned, not hung") }
            var quitReturned=false
            let quit=Task { let clean=await f.bootstrap.shutdown();quitReturned=true;return clean }
            let deadline=ContinuousClock.now + .seconds(5)
            while f.probe.ends == 0 && !quitReturned {
                guard ContinuousClock.now < deadline else {
                    f.probe.reply(.cancel);_ = await quit.value
                    return XCTFail("Quit never requested original sheet cancellation")
                }
                await Task.yield()
            }
            XCTAssertEqual(f.probe.ends,1);XCTAssertFalse(quitReturned)
            f.probe.reply(.alertFirstButtonReturn)
            let clean=await quit.value;XCTAssertTrue(clean)
            try await f.waitForReturn();XCTAssertFalse(f.bootstrap.canEnroll)
        }
    }
    @MainActor func testCancelDuringSheetRegistrationDoesNotConsumePrematureEndRequest() async throws {
        try await withFixture { f in
            f.probe.duringBegin={f.prompt.cancel()}
            f.request();try await f.waitForPresentationOrReturn()
            guard f.probe.starts == 1 else { return XCTFail("No presentation; original may have returned, not hung") }
            XCTAssertEqual(f.probe.ends,1,"Cancellation before native registration must end only after it exists")
            f.probe.reply(.alertFirstButtonReturn);try await f.waitForReturn()
            XCTAssertFalse(FileManager.default.fileExists(atPath:f.policy.lifecycleRoot.path))
        }
    }
    @MainActor func testCloseAfterNativeCallbackBeforeBootstrapHandoffCannotCreateHistory() async throws {
        try await withFixture { f in
            f.request();try await f.waitForPresentationOrReturn()
            guard f.probe.starts == 1 else { return XCTFail("No presentation; original may have returned, not hung") }
            // Actual callback enters and returns before the async original can
            // resume; closing this owned parent invalidates its captured token.
            f.probe.reply(.alertFirstButtonReturn);f.owned.close()
            try await f.waitForReturn()
            XCTAssertNil(f.bootstrap.runtime);XCTAssertFalse(FileManager.default.fileExists(atPath:f.policy.lifecycleRoot.path))
        }
    }
}
