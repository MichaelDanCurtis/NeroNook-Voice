import AVFoundation
import Foundation
import XCTest
import ModuleCore
import VoiceAudio
import NookPluginSDK
@testable import ModuleApp

/// Tests construct the real private app service, never VoiceModel or app/main.
/// Every checkpoint throws before permission; no audio/model result is supplied.
final class ConversationPreparationTests: XCTestCase {
    @MainActor private final class Preferences: ConversationPreferences {
        let preloader = SpeechPreloader()
        var conversationPace: ConversationPace = .quick
        var interruptionSensitivity = 50
        var dictationASR: VoiceASRProvider = .apple
        var locale = "en-US"
        var microphone = ""
        var speechBackend: SpeechBackend = .apple
        var qwenOptions = QwenOptions()
        var voiceID = ""
        var speechDelivery: SpeechDelivery = .natural
        var selectedSpeechVoice: AVSpeechSynthesisVoice? { nil }
        var qwenSpeaker: QwenSpeaker = .ryan
    }
    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var entries = 0
        private(set) var returned = false
        func checkpoint() async throws {
            entries += 1
            await withCheckedContinuation { continuation in
                if released { continuation.resume() }
                else { self.continuation = continuation }
            }
            returned = true
            // ALWAYS throw, including after cancellation-ignoring suspension.
            throw CancellationError()
        }
        func release() {
            released = true
            let current = continuation; continuation = nil; current?.resume()
        }
    }
    @MainActor private final class Fixture {
        let preferences = Preferences()
        let gates: [Gate]
        let provider: ConversationProvider
        var messages: [PluginBusMessage] = []
        init(gates: [Gate]) {
            self.gates = gates
            var next = 0
            provider = ConversationProvider {
                // Running beyond the authored sequence is also cancellation,
                // never permission/readiness from a fallback.
                guard next < gates.count else { throw CancellationError() }
                let gate = gates[next]; next += 1
                try await gate.checkpoint()
                throw CancellationError()
            }
            provider.send = { [weak self] in self?.messages.append($0) }
        }
        func start(_ id: UUID = UUID(), available: Bool = true) throws {
            try provider.start(id, values: ["mode": .string("half")], preferences: preferences, available: available)
        }
    }
    @MainActor private func fixture(_ count: Int = 1) -> Fixture {
        let fixture = Fixture(gates: (0..<count).map { _ in Gate() })
        addTeardownBlock { @MainActor in
            // Retire callbacks first, release every authored hold, then join
            // the actual retained observer/original task even after failures.
            fixture.provider.changed = nil; fixture.provider.send = nil
            let original = fixture.provider.preparationCompletion()
            fixture.provider.stop("Test teardown")
            fixture.gates.forEach { $0.release() }
            await original?.value
            XCTAssertFalse(fixture.provider.preparationIsOwned)
        }
        return fixture
    }
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while true {
            guard ContinuousClock.now < end else { throw WaitFailure.expired }
            let ready = predicate()
            guard ContinuousClock.now < end else { throw WaitFailure.expired }
            if ready { return }
            await Task.yield()
        }
    }
    private enum WaitFailure: Error { case expired }

    @MainActor func testReentrantStopBeforeDispatchRetainsOriginalAndNeverEntersCheckpoint() async throws {
        let f = fixture(); let original = UUID()
        var retired = false; var refused = false
        f.provider.changed = {
            guard !retired else { return }; retired = true
            XCTAssertTrue(f.provider.preparationIsOwned)
            f.provider.stop("Stopped from preparing callback")
            do { try f.start() } catch { refused = true }
        }
        try f.start(original)
        XCTAssertTrue(retired); XCTAssertTrue(refused)
        XCTAssertFalse(f.provider.active); XCTAssertTrue(f.provider.busy)
        XCTAssertEqual(f.gates[0].entries, 0)
        let originalCompletion = f.provider.preparationCompletion()
        await originalCompletion?.value
        XCTAssertEqual(f.gates[0].entries, 0)
        XCTAssertFalse(f.provider.busy); XCTAssertFalse(f.provider.preparationIsOwned)
        XCTAssertEqual(f.provider.status, "Stopped from preparing callback")
        XCTAssertEqual(f.messages.count, 1)
        XCTAssertEqual(f.messages.first?.requestID, original)
        XCTAssertEqual(f.messages.first?.update?.phase, .cancelled)
    }

    @MainActor func testStopWhileHeldKeepsBusyAndRefusesNewStartUntilActualReturn() async throws {
        let f = fixture(); try f.start()
        try await wait { f.gates[0].entries == 1 }
        f.provider.stop("Owner stopped")
        XCTAssertFalse(f.provider.active); XCTAssertTrue(f.provider.preparationIsOwned)
        XCTAssertTrue(f.provider.busy); XCTAssertFalse(f.gates[0].returned)
        XCTAssertThrowsError(try f.start())
        XCTAssertEqual(f.gates[0].entries, 1)
        let originalCompletion = f.provider.preparationCompletion()
        f.gates[0].release()
        await originalCompletion?.value
        XCTAssertTrue(f.gates[0].returned)
        XCTAssertFalse(f.provider.busy); XCTAssertFalse(f.provider.preparationIsOwned)
        XCTAssertEqual(f.provider.status, "Owner stopped")
    }

    @MainActor func testRepeatedStopAndExactCancelRetainTheSameHeldPreparation() async throws {
        let f = fixture(); let original = UUID(); try f.start(original)
        try await wait { f.gates[0].entries == 1 }
        f.provider.cancel(original)
        f.provider.stop("Repeated stop"); f.provider.cancel(original)
        XCTAssertTrue(f.provider.preparationIsOwned); XCTAssertTrue(f.provider.busy)
        XCTAssertFalse(f.gates[0].returned); XCTAssertThrowsError(try f.start())
        XCTAssertEqual(f.messages.count, 1)
        XCTAssertEqual(f.messages.first?.requestID, original)
        let originalCompletion = f.provider.preparationCompletion()
        f.gates[0].release(); await originalCompletion?.value
        XCTAssertEqual(f.gates[0].entries, 1); XCTAssertFalse(f.provider.busy)
    }

    @MainActor func testPreparingCallbackCannotReplaceOriginalRequestAndWrongCancelDoesNothing() async throws {
        let f = fixture(); let original = UUID(); var checked = false; var refused = false
        f.provider.changed = {
            guard !checked else { return }; checked = true
            do { try f.start() } catch { refused = true }
        }
        try f.start(original)
        try await wait { f.gates[0].entries == 1 }
        XCTAssertTrue(refused); f.provider.cancel(UUID())
        XCTAssertTrue(f.provider.active); XCTAssertTrue(f.provider.preparationIsOwned)
        XCTAssertTrue(f.messages.isEmpty)
        f.provider.cancel(original)
        XCTAssertFalse(f.provider.active)
        XCTAssertEqual(f.messages.first?.requestID, original)
        let originalCompletion = f.provider.preparationCompletion()
        f.gates[0].release(); await originalCompletion?.value
    }

    @MainActor func testLateCheckpointCancellationCannotPublishReadyOrFailureAfterStop() async throws {
        let f = fixture(); var observed: [String] = []
        f.provider.changed = { observed.append(f.provider.status) }
        try f.start(); try await wait { f.gates[0].entries == 1 }
        f.provider.stop("Keep this terminal status")
        let messagesAtStop = f.messages.count
        let originalCompletion = f.provider.preparationCompletion()
        f.gates[0].release(); await originalCompletion?.value
        XCTAssertEqual(f.messages.count, messagesAtStop)
        XCTAssertEqual(f.messages.count, 1)
        XCTAssertEqual(f.messages.first?.update?.phase, .cancelled)
        XCTAssertFalse(f.messages.contains { $0.operation == .stream })
        XCTAssertEqual(f.provider.status, "Keep this terminal status")
        XCTAssertTrue(observed.dropFirst().allSatisfy { $0 == "Keep this terminal status" })
        XCTAssertFalse(f.provider.active); XCTAssertFalse(f.provider.busy)
    }

    @MainActor func testSettledObserverCanStartSuccessorWithoutClearingItsOwnership() async throws {
        let f = fixture(2); let first = UUID(); let second = UUID()
        try f.start(first); try await wait { f.gates[0].entries == 1 }
        f.provider.stop("First stopped")
        var successorStarted = false; var successorError: Error?
        f.provider.changed = {
            guard !f.provider.busy, !successorStarted else { return }
            successorStarted = true
            do { try f.start(second) } catch { successorError = error }
        }
        // Capture A synchronously BEFORE release can schedule its callback.
        let originalCompletion = f.provider.preparationCompletion()
        f.gates[0].release()
        await originalCompletion?.value
        try await wait { f.gates[1].entries == 1 }
        XCTAssertTrue(successorStarted); XCTAssertNil(successorError)
        XCTAssertTrue(f.provider.active); XCTAssertTrue(f.provider.preparationIsOwned)
        XCTAssertTrue(f.provider.busy); XCTAssertFalse(f.gates[1].returned)
        f.provider.cancel(first)
        XCTAssertTrue(f.provider.active); XCTAssertTrue(f.provider.preparationIsOwned)
        f.provider.cancel(second)
        XCTAssertFalse(f.provider.active); XCTAssertTrue(f.provider.busy)
        let successorCompletion = f.provider.preparationCompletion()
        f.gates[1].release(); await successorCompletion?.value
        XCTAssertFalse(f.provider.busy)
        XCTAssertEqual(f.messages.map(\.requestID), [first, second])
        XCTAssertTrue(f.messages.allSatisfy { $0.update?.phase == .cancelled })
    }

    @MainActor func testUnavailableAndInvalidSchemaRefuseWithoutOwningPreparation() async throws {
        let f = fixture(); var notifications = 0
        f.provider.changed = { notifications += 1 }
        XCTAssertThrowsError(try f.start(available: false))
        XCTAssertThrowsError(try f.provider.start(UUID(), values: ["mode": .string("invalid")], preferences: f.preferences, available: true))
        XCTAssertThrowsError(try f.provider.start(UUID(), values: [:], preferences: f.preferences, available: true))
        XCTAssertFalse(f.provider.active); XCTAssertFalse(f.provider.busy)
        XCTAssertFalse(f.provider.preparationIsOwned)
        XCTAssertEqual(notifications, 0); XCTAssertEqual(f.gates[0].entries, 0)
        XCTAssertTrue(f.messages.isEmpty)
        let absentCompletion = f.provider.preparationCompletion()
        await absentCompletion?.value
    }

    @MainActor func testCheckpointCancellationUsesActualFailurePathThenAllowsFreshPreparation() async throws {
        let f = fixture(2); let first = UUID(); let second = UUID()
        try f.start(first); try await wait { f.gates[0].entries == 1 }
        XCTAssertTrue(f.provider.active); XCTAssertTrue(f.provider.preparationIsOwned)
        let originalCompletion = f.provider.preparationCompletion()
        f.gates[0].release(); await originalCompletion?.value
        XCTAssertFalse(f.provider.active); XCTAssertFalse(f.provider.busy)
        XCTAssertEqual(f.messages.count, 1); XCTAssertEqual(f.messages.first?.requestID, first)
        XCTAssertEqual(f.messages.first?.update?.phase, .failed)
        try f.start(second); try await wait { f.gates[1].entries == 1 }
        XCTAssertTrue(f.provider.active); XCTAssertTrue(f.provider.busy)
        let successorCompletion = f.provider.preparationCompletion()
        f.provider.stop(); f.gates[1].release(); await successorCompletion?.value
        XCTAssertFalse(f.provider.busy)
        XCTAssertEqual(f.messages.last?.requestID, second)
        XCTAssertEqual(f.messages.last?.update?.phase, .cancelled)
    }
}
