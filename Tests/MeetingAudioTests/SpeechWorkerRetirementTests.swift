import XCTest
@testable import VoiceAudio

@MainActor final class SpeechWorkerRetirementTests: XCTestCase {
    private final class Hold {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func release() { continuation?.resume(); continuation = nil }
    }
    private func started(_ hold: Hold) async {
        while hold.continuation == nil { await Task.yield() }
    }
    func testRetainsOriginalUntilItsActualReturn() async {
        let hold = Hold(), retirement = SpeechWorkerRetirement()
        let work = Task { await hold.wait() }
        retirement.retain(work)
        let original = retirement.completion()
        await started(hold)
        XCTAssertTrue(retirement.busy)
        hold.release(); await original?.value
        XCTAssertFalse(retirement.busy)
    }
    func testBothOriginalCompletionsMustReturn() async {
        let a = Hold(), b = Hold(), retirement = SpeechWorkerRetirement()
        retirement.retain(Task { await a.wait() })
        retirement.retain(Task { await b.wait() })
        let original = retirement.completion()
        await started(a); await started(b)
        b.release()
        await Task.yield()
        XCTAssertTrue(retirement.busy)
        a.release(); await original?.value
        XCTAssertFalse(retirement.busy)
    }
    func testCompletionCallbackCannotClearItsReplacement() async {
        let a = Hold(), b = Hold(), retirement = SpeechWorkerRetirement()
        retirement.changed = {
            retirement.changed = nil
            retirement.retain(Task { await b.wait() })
        }
        retirement.retain(Task { await a.wait() })
        let original = retirement.completion()
        await started(a); a.release(); await original?.value
        await started(b)
        XCTAssertTrue(retirement.busy)
        let replacement = retirement.completion()
        b.release(); await replacement?.value
        XCTAssertFalse(retirement.busy)
    }
    func testNilCaptureCannotErasePendingOwnership() async {
        let hold = Hold(), retirement = SpeechWorkerRetirement()
        retirement.retain(Task { await hold.wait() })
        let original = retirement.completion()
        retirement.retain(nil)
        await started(hold); XCTAssertTrue(retirement.busy)
        hold.release(); await original?.value
        XCTAssertFalse(retirement.busy)
    }
}
