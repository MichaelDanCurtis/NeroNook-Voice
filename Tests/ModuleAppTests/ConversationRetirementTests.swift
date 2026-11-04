import XCTest
@testable import ModuleApp

/// Actual provider custody only; no preference store, permission, engine or model.
@MainActor final class ConversationRetirementTests: XCTestCase {
    private final class Hold {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private func started(_ hold: Hold) async {
        while hold.continuation == nil { await Task.yield() }
    }
    func testStoppedProviderStaysBusyUntilOriginalSpeechRetirementReturns() async {
        let hold = Hold(), provider = ConversationProvider()
        provider.retainSpeechRetirement(Task { await hold.wait() })
        let original = provider.speechRetirementCompletion()
        await started(hold)
        XCTAssertFalse(provider.active); XCTAssertTrue(provider.busy)
        provider.stop(); provider.stop()
        XCTAssertTrue(provider.busy)
        hold.release(); await original?.value
        XCTAssertFalse(provider.busy)
    }
    func testCompletionNotificationCannotClearNewRetirement() async {
        let a = Hold(), b = Hold(), provider = ConversationProvider()
        provider.changed = {
            provider.changed = nil
            provider.retainSpeechRetirement(Task { await b.wait() })
        }
        provider.retainSpeechRetirement(Task { await a.wait() })
        let original = provider.speechRetirementCompletion()
        await started(a); a.release(); await original?.value
        await started(b); XCTAssertTrue(provider.busy)
        let replacement = provider.speechRetirementCompletion()
        b.release(); await replacement?.value
        XCTAssertFalse(provider.busy)
    }
    func testOutputAndRecognizerBothRetireBeforeProviderBecomesAvailable() async {
        let output = Hold(), recognition = Hold(), provider = ConversationProvider()
        provider.retainSpeechRetirement(Task { await output.wait() })
        let outputOnly = provider.speechRetirementCompletion()
        provider.retainSpeechRetirement(Task { await recognition.wait() })
        let both = provider.speechRetirementCompletion()
        await started(output); await started(recognition)
        output.release(); await outputOnly?.value
        XCTAssertTrue(provider.busy)
        provider.stop(); XCTAssertTrue(provider.busy)
        recognition.release(); await both?.value
        XCTAssertFalse(provider.busy)
    }
}
