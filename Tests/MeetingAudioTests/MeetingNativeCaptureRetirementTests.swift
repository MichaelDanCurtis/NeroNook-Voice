import XCTest
import Foundation
import ModuleCore
@testable import VoiceAudio

// Actual MeetingCapture path with system/microphone both disabled: no audio
// engine, tap, GUI, model, permission or user/default store is opened.
final class MeetingNativeCaptureRetirementTests: XCTestCase {
    @MainActor func testCaptureIsSingleUseAndOwnNoInputStopReturns() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingCapture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        let writer = try MeetingAudioWriter(store: store, meeting: Meeting(title: "Authored", source: "none", microphone: false))
        let capture = MeetingCapture()
        try capture.start(microphone: nil, includeMicrophone: false, systemSource: "none", writer: writer, offset: 0, failure: { _ in XCTFail("Unexpected callback") })
        XCTAssertThrowsError(try capture.start(microphone: nil, includeMicrophone: false, systemSource: "none", writer: writer, offset: 0, failure: { _ in }))
        let returned = await capture.stopAndDrain()
        XCTAssertTrue(returned.microphoneStopReturned)
        XCTAssertFalse(returned.stoppedDuringStart)
        XCTAssertTrue(returned.systemStatuses.isEmpty)
        XCTAssertThrowsError(try capture.start(microphone: nil, includeMicrophone: false, systemSource: "none", writer: writer, offset: 0, failure: { _ in }))
        _ = try await writer.finish(state: "saved")
    }
    func testOriginalFastExitChildIsJoinedAfterLaunch() async throws {
        for command in ["/usr/bin/true", "/usr/bin/false"] {
            let child = Process(); child.executableURL = URL(fileURLWithPath: command)
            try child.run()
            try await SpeakerRuntime.waitForOriginalChild(child)
            XCTAssertFalse(child.isRunning)
            XCTAssertEqual(child.terminationStatus, command.hasSuffix("true") ? 0 : 1)
        }
    }

    func testOwnedEmptyEphemeralSessionWaitsForItsInvalidationCallback() async {
        let receipt = MeetingCleanupReceipt()
        let original = MeetingOwnedSession(configuration: .ephemeral, receipt: receipt)
        await original.invalidateAndWait()
        XCTAssertNil(receipt.issue)
    }



    func testCleanupReceiptKeepsOriginalCloseErrorWithoutTouchingForeignDescriptors() throws {
        enum AuthoredFailure: Error { case close }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingReceipt-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("authored".utf8).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let receipt = MeetingCleanupReceipt()
        receipt.close(handle, context: "original close") { _ in throw AuthoredFailure.close }
        let first = try XCTUnwrap(receipt.issue)
        receipt.record("later failure")
        XCTAssertEqual(receipt.issue, first)
        XCTAssertTrue(first.contains("original close"))
    }

    @MainActor func testOriginalChildAndEscalationTimerBothReturn() async throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["10"]
        try child.run()
        let timer = try XCTUnwrap(LocalModelProcess.stop(child))
        let waiter = Task.detached { child.waitUntilExit() }
        await waiter.value
        timer.cancel(); await timer.value
        XCTAssertFalse(child.isRunning)
    }

}
