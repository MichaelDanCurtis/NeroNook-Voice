import XCTest
import Foundation
import AVFoundation
import ModuleCore
@testable import VoiceAudio
@testable import ModuleApp

// No MeetingModel, user/default store, UI panel, device, audio or model is opened.
// Writer tests use an explicitly authored temporary store; one serializes tiny silent fixture buffers.
final class MeetingFileRetirementTests: XCTestCase {
    @MainActor func testReservedPanelCompletionWaitsForOriginalNativeCallbackAndDelivery() async {
        let panel = MeetingFilePanelCompletion(), delivery = MeetingFileCompletion()
        XCTAssertTrue(panel.begin())
        panel.seal(); panel.nativeStopReturned()
        var returned = false
        let callbackEntered = expectation(description: "Original panel delivery entered")
        let retirement = Task { @MainActor in await panel.waitForReturn(); returned = true }
        await Task.yield(); XCTAssertFalse(returned)
        panel.deliver { @MainActor in callbackEntered.fulfill(); await delivery.wait() }
        await fulfillment(of: [callbackEntered], timeout: 5)
        XCTAssertFalse(returned)
        delivery.finish(); await retirement.value
        XCTAssertTrue(returned)
    }

    @MainActor func testStopBeforePanelBeginNeverWaitsForUnregisteredCallback() async {
        let panel = MeetingFilePanelCompletion()
        panel.seal(); panel.nativeStopReturned()
        XCTAssertFalse(panel.begin())
        await panel.waitForReturn()
    }

    @MainActor func testModalCompletionDoesNotReturnWhenWaiterIsCancelled() async {
        let completion = MeetingFileCompletion()
        var returned = false
        let original = Task { @MainActor in await completion.wait(); returned = true }
        original.cancel()
        await Task.yield(); XCTAssertFalse(returned)
        completion.finish(); await original.value
        XCTAssertTrue(returned)
    }

    @MainActor func testActualWriterFailureCloseWaitsForItsStorageQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingFileWriter-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let queue = DispatchQueue(label: "meeting-authored-held-storage")
        let started = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        queue.async { started.signal(); unblock.wait() }
        let writer = try MeetingAudioWriter(store: store, meeting: Meeting(title: "Authored", source: "none", microphone: false),
                                            liveFeed: nil, speakerFeed: nil, storageQueue: queue)
        let entered = await Task.detached { started.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(entered)
        var returned = false
        let original = Task { @MainActor in _ = await writer.closeAfterFailure(); returned = true }
        await Task.yield(); XCTAssertFalse(returned)
        unblock.signal(); await original.value
        XCTAssertTrue(returned)
    }

    @MainActor func testFailedFinalizeClosesRemainingOriginalTrackFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingFileFailure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let meeting = Meeting(title: "Authored failure", source: "none", microphone: false)
        let writer = try MeetingAudioWriter(store: store, meeting: meeting)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<1600 { samples[index] = 0 }
        writer.append(buffer, track: "mic", start: 0)
        writer.append(buffer, track: "system", start: 0)
        await writer.synchronize()
        let folder = store.folder(meeting.id)
        let tracks = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "caf" }
        XCTAssertEqual(tracks.count, 2)
        let manifest = folder.appendingPathComponent("meeting.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        try Data("authored".utf8).write(to: manifest.appendingPathComponent("blocker"))
        do { _ = try await writer.finish(state: "saved"); XCTFail("The original manifest replacement should fail") }
        catch { /* The failed operation is intentionally retained. */ }
        let closed = await writer.closeAfterFailure()
        XCTAssertEqual(closed, 1, "The other open track must be released after the first save fails")
        let remaining = await writer.closeAfterFailure()
        XCTAssertEqual(remaining, 0)
        for track in tracks { XCTAssertTrue(FileManager.default.fileExists(atPath: track.path)) }
    }

    @MainActor func testActualCheckpointQueueFailureAndOtherOwnerReturn() async throws {
        let started = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        let checkpoints = MeetingTranscriptCheckpoints(persist: { _, _, _ in
            started.signal(); unblock.wait(); throw VoiceProblem.message("authored write failure")
        })
        let owner = MeetingOwnedTasks(), a = VoiceFoundationOwner(), b = VoiceFoundationOwner()
        let meeting = UUID()
        checkpoints.save(MeetingTranscript(locale: "en-US"), id: meeting, provider: .apple)
        let didStart = await Task.detached { started.wait(timeout: .now() + 5) == .success }.value
        XCTAssertTrue(didStart)
        var failureObserved = false
        let original = Task { @MainActor in
            do { try await checkpoints.flush() }
            catch { failureObserved = error.localizedDescription.contains("authored write failure") }
        }
        let unrelatedCompletion = MeetingFileCompletion()
        let unrelated = Task { @MainActor in await unrelatedCompletion.wait() }
        owner.retain(original, owner: a); owner.retain(unrelated, owner: b)
        let held = owner.close(a)
        XCTAssertEqual(held.count, 1); XCTAssertTrue(original.isCancelled); XCTAssertFalse(unrelated.isCancelled)
        var returned = false
        let retirement = Task { @MainActor in for task in held { await task.value }; returned = true }
        await Task.yield(); XCTAssertFalse(returned)
        unblock.signal(); await retirement.value
        XCTAssertTrue(returned); XCTAssertTrue(failureObserved); XCTAssertFalse(unrelated.isCancelled)
        unrelatedCompletion.finish(); await unrelated.value
    }
}
