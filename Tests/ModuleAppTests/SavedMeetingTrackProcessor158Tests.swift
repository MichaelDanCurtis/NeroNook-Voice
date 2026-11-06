import Foundation
import XCTest
import ModuleCore
import NookPluginSDK
@testable import ModuleApp

final class SavedMeetingTrackProcessor158Tests: XCTestCase {
    @MainActor private func exercise(_ provider: MeetingASRProvider) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-track-158-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var protected = MeetingUtterance(start: 4, end: 8, track: "mic", text: "Original speech")
        protected.correction = "We agreed the draft"; protected.speaker = "mic-3"; protected.reviewed = true
        let other = MeetingUtterance(start: 9, end: 10, track: "system", text: "Other track")
        let overlap = MeetingUtterance(start: 2, end: 9, track: "mic", text: "Start tail; alternative words; end tail 🌿")
        let disjoint = MeetingUtterance(start: 12, end: 13, track: "mic", text: "Disjoint new speech")
        var initial = MeetingTranscript(locale: "en-US", provider: provider); initial.utterances = [protected, other]; initial.names["mic-3"] = "Mara"
        try store.saveTranscript(initial, id: meeting.id, provider: provider)
        let old = try Data(contentsOf: store.folder(meeting.id).appendingPathComponent(provider.transcriptFile))
        let original = try XCTUnwrap(store.transcript(meeting.id, provider: provider))
        var assembled = 0, appleCalls = 0, localCalls = 0, saves = 0
        var published: [MeetingTranscript] = []
        let result = try await SavedMeetingTrackProcessor.run(transcript: original, meetingID: meeting.id, track: "mic", provider: provider,
            modelRevision: "authored-model", runtimeRevision: "authored-runtime",
            assemble: { assembled += 1 }, apple: { emit in appleCalls += 1; try emit(overlap); try emit(disjoint) },
            local: { localCalls += 1; return [overlap, disjoint] }, checkpointDue: { true },
            save: { value in saves += 1; return try store.saveTranscript(value, id: meeting.id, provider: provider) },
            publish: { published.append($0) }, requireCurrent: {})
        XCTAssertEqual(assembled, 1); XCTAssertEqual(appleCalls, provider == .apple ? 1 : 0); XCTAssertEqual(localCalls, provider == .apple ? 0 : 1)
        XCTAssertGreaterThan(saves, 0); XCTAssertFalse(published.isEmpty)
        let reloaded = try XCTUnwrap(store.transcript(meeting.id, provider: provider))
        XCTAssertEqual(reloaded.utterances.first { $0.id == protected.id }, protected)
        XCTAssertEqual(reloaded.utterances.first { $0.id == other.id }, other)
        XCTAssertEqual(reloaded.utterances.first { $0.id == disjoint.id }, disjoint)
        XCTAssertEqual(reloaded.transcriptionReview?.pending.first?.candidate, overlap)
        XCTAssertEqual(reloaded.pendingTranscriptionCount, 1); XCTAssertTrue(reloaded.completedTracks.contains("mic"))
        XCTAssertEqual(result.transcriptionRevision, reloaded.transcriptionRevision)
        XCTAssertEqual(try Data(contentsOf: store.folder(meeting.id).appendingPathComponent(provider.transcriptFile)), old)
    }
    @MainActor func testAppleStreamingUsesActualCoordinatorAndPreservesManualSpeech() async throws { try await exercise(.apple) }
    @MainActor func testMLXCompletionUsesActualCoordinatorAndPreservesManualSpeech() async throws { try await exercise(.nemotron) }
    @MainActor func testFailedFirstCheckpointDoesNotPublishUnsavedReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-track-failure-158-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var old = MeetingTranscript(locale: "en-US"); var protected = MeetingUtterance(start: 1, end: 4, track: "mic", text: "Old")
        protected.correction = "Manual"; protected.reviewed = true; old.utterances = [protected]
        try store.saveTranscript(old, id: meeting.id); let original = try XCTUnwrap(store.transcript(meeting.id))
        let bytes = try Data(contentsOf: store.folder(meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile))
        var published = 0, attemptedSaves = 0
        do {
            _ = try await SavedMeetingTrackProcessor.run(transcript: original, meetingID: meeting.id, track: "mic", provider: .apple,
                assemble: {}, apple: { emit in try emit(.init(start: 1, end: 4, track: "mic", text: "Alternative")) },
                local: { XCTFail("Unexpected local branch"); return [] }, checkpointDue: { true },
                save: { _ in attemptedSaves += 1; throw VoiceProblem.message("Authored checkpoint failure") },
                publish: { _ in published += 1 }, requireCurrent: {})
            XCTFail("Failed checkpoint was reported as success")
        } catch { XCTAssertEqual(error.localizedDescription, "Authored checkpoint failure") }
        XCTAssertEqual(attemptedSaves, 1); XCTAssertEqual(published, 0); XCTAssertFalse(store.hasTranscriptV2(meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: store.folder(meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile)), bytes)
        XCTAssertEqual(try store.transcript(meeting.id)?.utterances.first, protected)
    }

    @MainActor func testPartialCheckpointSurvivesCancellationAndRetryUsesNewAttempt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-track-cancel-158-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var old = MeetingTranscript(locale: "en-US"); var protected = MeetingUtterance(start: 2, end: 6, track: "mic", text: "Original")
        protected.correction = "Manual"; protected.reviewed = true; old.utterances = [protected]
        try store.saveTranscript(old, id: meeting.id); let original = try XCTUnwrap(store.transcript(meeting.id))
        let first = MeetingUtterance(start: 1, end: 7, track: "mic", text: "Earlier full alternative")
        let second = MeetingUtterance(start: 1, end: 7, track: "mic", text: "Retried full alternative")
        var committed = 0
        do {
            _ = try await SavedMeetingTrackProcessor.run(transcript: original, meetingID: meeting.id, track: "mic", provider: .apple,
                assemble: {}, apple: { emit in try emit(first); throw CancellationError() }, local: { [] }, checkpointDue: { true },
                save: { value in committed += 1; return try store.saveTranscript(value, id: meeting.id) }, publish: { _ in }, requireCurrent: {})
            XCTFail("Cancelled recognition returned success")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertGreaterThan(committed, 0)
        let partial = try XCTUnwrap(store.transcript(meeting.id)); XCTAssertFalse(partial.completedTracks.contains("mic"))
        let firstOrigin = try XCTUnwrap(partial.transcriptionReview?.pending.first { $0.candidate.id == first.id }?.origin.attemptID)
        XCTAssertEqual(partial.utterances.first { $0.id == protected.id }, protected)
        let retried = try await SavedMeetingTrackProcessor.run(transcript: partial, meetingID: meeting.id, track: "mic", provider: .apple,
            assemble: {}, apple: { emit in try emit(second) }, local: { [] }, checkpointDue: { true },
            save: { try store.saveTranscript($0, id: meeting.id) }, publish: { _ in }, requireCurrent: {})
        let secondOrigin = try XCTUnwrap(retried.transcriptionReview?.pending.first { $0.candidate.id == second.id }?.origin.attemptID)
        XCTAssertNotEqual(firstOrigin, secondOrigin)
        XCTAssertNotNil(retried.transcriptionReview?.pending.first { $0.candidate.id == first.id })
        XCTAssertEqual(retried.utterances.first { $0.id == protected.id }, protected)
        XCTAssertTrue(retried.completedTracks.contains("mic"))
    }

    @MainActor func testScalarPagingPreservesLongGraphemeAndEntireTail() throws {
        let text = "START" + "e" + String(repeating: "\u{301}", count: 3000) + "🌿END"
        var offset = 0, rebuilt = "", pages = 0, completed = false
        for _ in 0..<10 {
            let (page, next, more) = MeetingModel.transcriptionPage(text, offset: offset)
            XCTAssertLessThanOrEqual(page.utf8.count, 2048)
            XCTAssertGreaterThan(next, offset)
            guard next > offset else { XCTFail("Paging did not advance"); return }
            rebuilt += page; pages += 1; offset = next
            if !more { completed = true; break }
            XCTAssertLessThan(pages, 10)
        }
        guard completed else { XCTFail("Paging exceeded the finite page limit"); return }
        XCTAssertGreaterThan(pages, 1); XCTAssertEqual(Array(rebuilt.utf8), Array(text.utf8))
        XCTAssertEqual(offset, text.unicodeScalars.count)
    }

    @MainActor func testCompletedTrackKeepsOriginalSkipWithoutRecognitionOrSave() async throws {
        var initial = MeetingTranscript(locale: "en-US"); initial.completedTracks = ["mic"]
        let line = MeetingUtterance(start: 1, end: 2, track: "mic", text: "Existing"); initial.utterances = [line]
        var assembled = 0, recognized = 0, saved = 0
        let value = try await SavedMeetingTrackProcessor.run(transcript: initial, meetingID: UUID(), track: "mic", provider: .apple,
            assemble: { assembled += 1 }, apple: { _ in recognized += 1 }, local: { recognized += 1; return [] }, checkpointDue: { true },
            save: { row in saved += 1; return row }, publish: { _ in XCTFail("Completed track published") }, requireCurrent: {})
        XCTAssertEqual(assembled, 1); XCTAssertEqual(recognized, 0); XCTAssertEqual(saved, 0)
        XCTAssertEqual(value.utterances, [line]); XCTAssertEqual(value.completedTracks, ["mic"])
    }

    func testReviewFrameBoundsWorstEscapedPagesWithoutUnrelatedState() throws {
        var review = MeetingTranscriptionReviewViewState()
        review.count = 4096; review.protectedRows = 39999; review.meeting = UUID().uuidString
        review.provider = "nemotron"; review.revision = UUID().uuidString; review.candidate = UUID().uuidString
        review.digest = String(repeating: "a", count: 64); review.attempt = UUID().uuidString; review.track = "system"
        review.candidateText = String(repeating: "\u{0000}", count: 1024)
        review.protectedText = String(repeating: "\u{0000}", count: 1024)
        let frame = MeetingTranscriptionViewFrame.state(review)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(frame).count, 32_768)
        XCTAssertNil(frame["notebook"]); XCTAssertNil(frame["ask"]); XCTAssertNil(frame["bookmarks"])
        XCTAssertEqual(frame["transcript"]?.display, "[]")
    }

    @MainActor func testCancelFromProgressCallbackPreventsLaterSaveAndPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-track-progress-cancel-158-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var transcript = MeetingTranscript(locale: "en-US"); var manual = MeetingUtterance(start: 1, end: 4, track: "mic", text: "Original")
        manual.reviewed = true; manual.correction = "Manual correction"; transcript.utterances = [manual]
        try store.saveTranscript(transcript, id: meeting.id); let original = try XCTUnwrap(store.transcript(meeting.id))
        let v1 = store.folder(meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile), before = try Data(contentsOf: v1)
        var saves = 0, publications = 0, callbacks = 0
        var task: Task<MeetingTranscript, Error>?
        task = Task { @MainActor in
            try await SavedMeetingTrackProcessor.run(transcript: original, meetingID: meeting.id, track: "mic", provider: .apple,
                assemble: {}, apple: { emit in try emit(.init(start: 1, end: 4, track: "mic", text: "Alternative")) },
                local: { [] }, checkpointDue: { true }, save: { value in saves += 1; return try store.saveTranscript(value, id: meeting.id) },
                publish: { _ in publications += 1 }, requireCurrent: {}, didReceive: { _ in callbacks += 1; task?.cancel() })
        }
        let originalTask = try XCTUnwrap(task)
        defer { task = nil }
        do { _ = try await originalTask.value; XCTFail("Cancelled original returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(callbacks, 1); XCTAssertEqual(saves, 0); XCTAssertEqual(publications, 0)
        XCTAssertEqual(try Data(contentsOf: v1), before); XCTAssertFalse(store.hasTranscriptV2(meeting.id, provider: .apple))
    }

    @MainActor func testCancelDuringActualCheckpointSuppressesLaterPublicationAndCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-track-save-cancel-158-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var transcript = MeetingTranscript(locale: "en-US"); var manual = MeetingUtterance(start: 1, end: 4, track: "mic", text: "Original")
        manual.reviewed = true; manual.correction = "Manual correction"; transcript.utterances = [manual]
        try store.saveTranscript(transcript, id: meeting.id); let original = try XCTUnwrap(store.transcript(meeting.id))
        var saves = 0, publications = 0; var task: Task<MeetingTranscript, Error>?
        task = Task { @MainActor in
            try await SavedMeetingTrackProcessor.run(transcript: original, meetingID: meeting.id, track: "mic", provider: .apple,
                assemble: {}, apple: { emit in try emit(.init(start: 1, end: 4, track: "mic", text: "Alternative")) },
                local: { [] }, checkpointDue: { true }, save: { value in
                    saves += 1; let saved = try store.saveTranscript(value, id: meeting.id); task?.cancel(); return saved
                }, publish: { _ in publications += 1 }, requireCurrent: {})
        }
        let originalTask = try XCTUnwrap(task); defer { task = nil }
        do { _ = try await originalTask.value; XCTFail("Cancelled original returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(saves, 1); XCTAssertEqual(publications, 0)
        let durable = try XCTUnwrap(store.transcript(meeting.id)); XCTAssertEqual(durable.utterances.first { $0.id == manual.id }, manual)
        XCTAssertEqual(durable.pendingTranscriptionCount, 1); XCTAssertFalse(durable.completedTracks.contains("mic"))
    }

    @MainActor func testOwnershipLostInCheckpointCallbackCannotSaveOrPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-track-owner-158-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var original = MeetingTranscript(locale: "en-US"); var manual = MeetingUtterance(start: 1, end: 4, track: "mic", text: "Original")
        manual.reviewed = true; original.utterances = [manual]; try store.saveTranscript(original, id: meeting.id)
        let loaded = try XCTUnwrap(store.transcript(meeting.id)), file = store.folder(meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile)
        let before = try Data(contentsOf: file); var current = true, saves = 0, publications = 0
        do {
            _ = try await SavedMeetingTrackProcessor.run(transcript: loaded, meetingID: meeting.id, track: "mic", provider: .apple,
                assemble: {}, apple: { emit in try emit(.init(start: 1, end: 4, track: "mic", text: "Alternative")) },
                local: { [] }, checkpointDue: { current = false; return true },
                save: { value in saves += 1; return try store.saveTranscript(value, id: meeting.id) },
                publish: { _ in publications += 1 }, requireCurrent: { if !current { throw CancellationError() } })
            XCTFail("Retired owner returned success")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(saves, 0); XCTAssertEqual(publications, 0)
        XCTAssertEqual(try Data(contentsOf: file), before); XCTAssertFalse(store.hasTranscriptV2(meeting.id, provider: .apple))
    }

    @MainActor func testCancelFromPublicationStopsNextRecognitionCallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-track-publish-cancel-158-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var transcript = MeetingTranscript(locale: "en-US"); var manual = MeetingUtterance(start: 1, end: 4, track: "mic", text: "Original")
        manual.reviewed = true; manual.correction = "Manual correction"; transcript.utterances = [manual]
        try store.saveTranscript(transcript, id: meeting.id); let original = try XCTUnwrap(store.transcript(meeting.id))
        let first = MeetingUtterance(start: 1, end: 4, track: "mic", text: "First alternative")
        let second = MeetingUtterance(start: 1, end: 4, track: "mic", text: "Later alternative")
        var saves = 0, publications = 0; var task: Task<MeetingTranscript, Error>?
        task = Task { @MainActor in
            try await SavedMeetingTrackProcessor.run(transcript: original, meetingID: meeting.id, track: "mic", provider: .apple,
                assemble: {}, apple: { emit in try emit(first); try emit(second) }, local: { [] }, checkpointDue: { true },
                save: { value in saves += 1; return try store.saveTranscript(value, id: meeting.id) },
                publish: { _ in publications += 1; task?.cancel() }, requireCurrent: {})
        }
        let originalTask = try XCTUnwrap(task); defer { task = nil }
        do { _ = try await originalTask.value; XCTFail("Cancelled original returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(saves, 1); XCTAssertEqual(publications, 1)
        let durable = try XCTUnwrap(store.transcript(meeting.id)); XCTAssertEqual(durable.utterances.first { $0.id == manual.id }, manual)
        XCTAssertNotNil(durable.transcriptionReview?.pending.first { $0.id == first.id })
        XCTAssertNil(durable.transcriptionReview?.pending.first { $0.id == second.id }); XCTAssertFalse(durable.completedTracks.contains("mic"))
    }

    @MainActor func testMLXBatchOwnerRetirementRefusesSaveAfterPartialProcessing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-track-mlx-owner-158-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var transcript = MeetingTranscript(locale: "en-US", provider: .nemotron)
        var manual = MeetingUtterance(start: 1, end: 4, track: "mic", text: "Original")
        manual.reviewed = true; transcript.utterances = [manual]; try store.saveTranscript(transcript, id: meeting.id, provider: .nemotron)
        let original = try XCTUnwrap(store.transcript(meeting.id, provider: .nemotron))
        let v1 = store.folder(meeting.id).appendingPathComponent(MeetingASRProvider.nemotron.transcriptFile), before = try Data(contentsOf: v1)
        let rows = (0..<33).map { _ in MeetingUtterance(start: 1, end: 4, track: "mic", text: "Authored overlap") }
        var checks = 0, saves = 0, publications = 0
        do {
            _ = try await SavedMeetingTrackProcessor.run(transcript: original, meetingID: meeting.id, track: "mic", provider: .nemotron,
                assemble: {}, apple: { _ in XCTFail("Unexpected Apple branch") }, local: { rows }, checkpointDue: { true },
                save: { value in saves += 1; return try store.saveTranscript(value, id: meeting.id, provider: .nemotron) },
                publish: { _ in publications += 1 }, requireCurrent: { checks += 1; if checks == 5 { throw CancellationError() } })
            XCTFail("Retired MLX owner returned success")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(checks, 5); XCTAssertEqual(saves, 0); XCTAssertEqual(publications, 0)
        XCTAssertEqual(try Data(contentsOf: v1), before); XCTAssertFalse(store.hasTranscriptV2(meeting.id, provider: .nemotron))
    }

}
