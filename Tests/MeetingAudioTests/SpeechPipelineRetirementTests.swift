import XCTest
import Foundation
@testable import VoiceAudio

/// Actual Pipeline start/cancellation custody only. Every checkpoint throws
/// before Apple assets, device selection or AVAudioEngine construction.
@MainActor final class SpeechPipelineRetirementTests: XCTestCase {
    private final class Hold {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        var waiting: Bool { continuation != nil }
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            let old = continuation; continuation = nil
            old?.resume()
        }
    }
    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "SpeechPipelineRetirementTests", code: 1) }
            await Task.yield()
        }
    }
    private func expectCancellation(_ original: Task<Void, Error>) async {
        do { try await original.value; XCTFail("Stopped preparation returned ready") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testStopBeforeDispatchNeverEntersPreResourceCheckpoint() async throws {
        var entered = false, partials = 0, failures = 0
        let pipeline = SpeechPipeline(startCheckpoint: { entered = true; throw CancellationError() })
        let original = Task {
            try await pipeline.start(microphone: nil, locale: "en-US", partial: { _ in partials += 1 }, failure: { _ in failures += 1 })
        }
        defer { original.cancel(); pipeline.cancel() }
        pipeline.cancel()
        let retirement = try XCTUnwrap(pipeline.retirementCompletion())
        await expectCancellation(original)
        await retirement.value
        XCTAssertFalse(entered); XCTAssertFalse(pipeline.startIsOwned)
        XCTAssertEqual(partials, 0); XCTAssertEqual(failures, 0)
        await pipeline.cancelAndWait()
    }

    func testHeldStopRetainsOriginalReturnAndBlocksSharedSuccessorUntilItReturns() async throws {
        let hold = Hold()
        var nextEntered = false, partials = 0, failures = 0
        let first = SpeechPipeline(startCheckpoint: { await hold.wait(); throw CancellationError() })
        let next = SpeechPipeline(startCheckpoint: { nextEntered = true; throw CancellationError() })
        let original = Task {
            try await first.start(microphone: nil, locale: "en-US", partial: { _ in partials += 1 }, failure: { _ in failures += 1 })
        }
        defer { hold.open(); original.cancel(); first.cancel(); next.cancel() }
        try await until { hold.waiting }
        first.cancel(); first.cancel()
        let retirement = try XCTUnwrap(first.retirementCompletion())
        let shared = try XCTUnwrap(VoiceRecognitionRetirement.pending())
        XCTAssertTrue(first.startIsOwned)
        let successor = Task {
            try await next.start(microphone: nil, locale: "en-US", partial: { _ in partials += 1 }, failure: { _ in failures += 1 })
        }
        defer { successor.cancel() }
        try await until { next.startIsOwned }
        XCTAssertFalse(nextEntered, "Successor crossed the original retirement barrier")
        hold.open()
        await expectCancellation(original)
        await retirement.value; await shared.value
        await expectCancellation(successor)
        await next.cancelAndWait()
        XCTAssertTrue(nextEntered); XCTAssertFalse(first.startIsOwned); XCTAssertFalse(next.startIsOwned)
        XCTAssertEqual(partials, 0); XCTAssertEqual(failures, 0)
    }

    func testOverlappingStartRefusesWithoutReplacingOriginalPreparation() async throws {
        let hold = Hold()
        var entries = 0, partials = 0, failures = 0
        let pipeline = SpeechPipeline(startCheckpoint: { entries += 1; await hold.wait(); throw CancellationError() })
        let original = Task {
            try await pipeline.start(microphone: nil, locale: "en-US", partial: { _ in partials += 1 }, failure: { _ in failures += 1 })
        }
        defer { hold.open(); original.cancel(); pipeline.cancel() }
        try await until { hold.waiting }
        do {
            try await pipeline.start(microphone: nil, locale: "en-US", partial: { _ in partials += 1 }, failure: { _ in failures += 1 })
            XCTFail("Overlapping preparation replaced its original")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(pipeline.startIsOwned); XCTAssertEqual(entries, 1)
        pipeline.cancel(); hold.open()
        await expectCancellation(original); await pipeline.cancelAndWait()
        XCTAssertFalse(pipeline.startIsOwned)
        XCTAssertEqual(partials, 0); XCTAssertEqual(failures, 0)
    }

    func testCancelledStartTaskRetiresOnOriginalReturnWithoutASeparateStop() async throws {
        let hold = Hold()
        var partials = 0, failures = 0
        let pipeline = SpeechPipeline(startCheckpoint: { await hold.wait(); throw CancellationError() })
        let original = Task {
            try await pipeline.start(microphone: nil, locale: "en-US", partial: { _ in partials += 1 }, failure: { _ in failures += 1 })
        }
        defer { hold.open(); original.cancel(); pipeline.cancel() }
        try await until { hold.waiting }
        original.cancel()
        XCTAssertTrue(pipeline.startIsOwned, "Task cancellation fabricated original method return")
        hold.open()
        await expectCancellation(original)
        let retirement = try XCTUnwrap(pipeline.retirementCompletion())
        await retirement.value
        XCTAssertFalse(pipeline.startIsOwned)
        XCTAssertEqual(partials, 0); XCTAssertEqual(failures, 0)
    }

    func testReentrantStopOwnsRetirementBeforeCheckpointReturns() async throws {
        weak var target: SpeechPipeline?
        var published = false, partials = 0, failures = 0
        let pipeline = SpeechPipeline(startCheckpoint: {
            guard let target else { throw CancellationError() }
            target.cancel()
            published = target.startIsOwned && target.retirementCompletion() != nil && VoiceRecognitionRetirement.pending() != nil
            throw CancellationError()
        })
        target = pipeline
        defer { pipeline.cancel() }
        let original = Task {
            try await pipeline.start(microphone: nil, locale: "en-US", partial: { _ in partials += 1 }, failure: { _ in failures += 1 })
        }
        defer { original.cancel() }
        await expectCancellation(original); await pipeline.cancelAndWait()
        XCTAssertTrue(published); XCTAssertFalse(pipeline.startIsOwned)
        XCTAssertEqual(partials, 0); XCTAssertEqual(failures, 0)
    }

    func testFinishWithoutCaptureRetainsItsOriginalFailureReturnUntilRetirement() async throws {
        // This path never starts or prepares Apple Speech or an audio engine.
        let pipeline = SpeechPipeline(startCheckpoint: { throw CancellationError() })
        defer { pipeline.cancel() }
        do { _ = try await pipeline.finish(); XCTFail("A never-started pipeline fabricated captured audio") }
        catch { XCTAssertFalse(error is CancellationError, "Expected the original no-captured-audio refusal") }
        let retirement = try XCTUnwrap(pipeline.retirementCompletion())
        XCTAssertFalse(pipeline.finishIsOwned)
        await retirement.value
        await pipeline.cancelAndWait()
        XCTAssertFalse(pipeline.startIsOwned); XCTAssertFalse(pipeline.finishIsOwned)
    }

    func testSharedTailRetainsBothOriginalsAndOldCompletionCannotClearItsSuccessor() async throws {
        // Drain only the captured previous fixture tail, never a mutable future
        // tail that could contain one of the holds created by this test.
        let prior = VoiceRecognitionRetirement.pending(); await prior?.value
        let first = Hold(), second = Hold()
        let firstWork = Task { await first.wait() }, secondWork = Task { await second.wait() }
        defer { first.open(); second.open() }
        VoiceRecognitionRetirement.retain(firstWork)
        let original = try XCTUnwrap(VoiceRecognitionRetirement.pending())
        VoiceRecognitionRetirement.retain(secondWork)
        let successor = try XCTUnwrap(VoiceRecognitionRetirement.pending())
        try await until { first.waiting && second.waiting }
        first.open(); await original.value
        XCTAssertNotNil(VoiceRecognitionRetirement.pending(), "Old completion cleared its still-held successor")
        second.open(); await successor.value
        XCTAssertNil(VoiceRecognitionRetirement.pending())
    }
}
