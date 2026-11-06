import Foundation
import CryptoKit
import XCTest
import ModuleCore
@testable import ModuleApp

final class LiveFirstRefinement159Tests: XCTestCase {
    @MainActor private func exercise(_ provider: MeetingASRProvider) async throws {
        let f = try LiveRefinementFixture159(provider: provider); defer { try? f.cleanup() }
        XCTAssertNil(try f.store.transcript(f.meeting.id, provider: provider))
        let seed = try SavedMeetingTrackProcessor.prepareTranscription(store: f.store, meetingID: f.meeting.id, provider: provider, locale: "fr-FR", modelRevision: "refined-model", runtimeRevision: "refined-runtime")
        XCTAssertEqual(seed.utterances.first { $0.id == f.edited.id }, f.edited)
        XCTAssertEqual(seed.utterances.first { $0.id == f.speakerOnly.id }, f.speakerOnly)
        XCTAssertEqual(seed.utterances.first { $0.id == f.system.id }, f.system)
        XCTAssertFalse(seed.utterances.contains { $0.id == f.oldAutomatic.id })
        XCTAssertEqual(seed.names["mic-3"], "Mara"); XCTAssertEqual(seed.names["mic-2"], "Morgan")
        XCTAssertTrue(seed.completedTracks.isEmpty); XCTAssertTrue(seed.labelledTracks.isEmpty); XCTAssertNil(seed.speakerModelRevision)
        XCTAssertEqual(seed.locale, "fr-FR"); XCTAssertEqual(seed.modelRevision, "refined-model"); XCTAssertEqual(seed.runtimeRevision, "refined-runtime")
        let source = try XCTUnwrap(seed.liveRefinementSource)
        XCTAssertEqual(source.meetingID, f.meeting.id); XCTAssertEqual(source.provider, provider)
        XCTAssertEqual(source.sha256, SHA256.hash(data: f.originalLiveBytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(Set(source.includedRowIDs), Set([f.edited.id, f.speakerOnly.id, f.system.id]))
        XCTAssertEqual(source.locale, "en-US"); XCTAssertEqual(source.modelRevision, "live-model"); XCTAssertEqual(source.runtimeRevision, "live-runtime"); XCTAssertEqual(source.speakerModelRevision, "live-speaker-v1")
        var apple = 0, local = 0, published = 0
        let result = try await SavedMeetingTrackProcessor.run(transcript: seed, meetingID: f.meeting.id, track: "mic", provider: provider,
            modelRevision: "refined-model", runtimeRevision: "refined-runtime", assemble: {},
            apple: { emit in apple += 1; try emit(f.overlap); try emit(f.disjoint) },
            local: { local += 1; return [f.overlap, f.disjoint] }, checkpointDue: { true },
            save: { try f.store.saveTranscript($0, id: f.meeting.id, provider: provider) },
            publish: { _ in published += 1 }, requireCurrent: {})
        XCTAssertEqual(apple, provider == .apple ? 1 : 0); XCTAssertEqual(local, provider == .apple ? 0 : 1); XCTAssertGreaterThan(published, 0)
        let stored = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: provider))
        XCTAssertEqual(stored.utterances.first { $0.id == f.edited.id }, f.edited)
        XCTAssertEqual(stored.utterances.first { $0.id == f.speakerOnly.id }, f.speakerOnly)
        XCTAssertEqual(stored.utterances.first { $0.id == f.system.id }, f.system)
        XCTAssertEqual(stored.utterances.first { $0.id == f.disjoint.id }, f.disjoint)
        XCTAssertEqual(stored.transcriptionReview?.pending.first?.candidate, f.overlap)
        XCTAssertEqual(stored.modelRevision, "refined-model"); XCTAssertEqual(stored.runtimeRevision, "refined-runtime")
        XCTAssertEqual(stored.liveRefinementSource?.sha256, source.sha256)
        XCTAssertNil(stored.transcriptionReview?.origins[f.edited.id.uuidString])
        XCTAssertTrue(stored.completedTracks.contains("mic")); XCTAssertEqual(result.transcriptionRevision, stored.transcriptionRevision)
        try f.assertLiveUnchanged()
    }
    @MainActor func testFirstSelectionRetainsReviewedLiveIdentity() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        XCTAssertNil(try f.store.transcript(f.meeting.id, provider: .apple))
        let selected = try SavedMeetingTrackProcessor.prepareTranscription(store: f.store, meetingID: f.meeting.id, provider: .apple, locale: "en-US")
        XCTAssertEqual(selected.utterances.first { $0.id == f.edited.id }, f.edited)
        try f.assertLiveUnchanged()
    }
    @MainActor func testFirstRefinementRunsAppleAndRetainsReviewedLiveRows() async throws { try await exercise(.apple) }
    @MainActor func testFirstRefinementRunsMLXAndRetainsReviewedLiveRows() async throws { try await exercise(.nemotron) }

    @MainActor func testChangedLiveSourceBeforeFirstPublicationRefusesWithoutOverwriting() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let seed = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        var changed = f.live; changed.utterances[0].correction = "A newer live correction"
        try f.store.saveLiveTranscript(changed, id: f.meeting.id, provider: .apple)
        let path = f.store.folder(f.meeting.id).appendingPathComponent("live-" + MeetingASRProvider.apple.transcriptFile)
        let current = try Data(contentsOf: path)
        XCTAssertThrowsError(try f.store.saveTranscript(seed, id: f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: path), current)
        XCTAssertNil(try f.store.transcript(f.meeting.id, provider: .apple))
    }
    @MainActor func testTargetAppearingBeforeFirstPublicationIsNotOverwritten() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let seed = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        var competing = MeetingTranscript(locale: "en-US"); competing.utterances = [.init(start: 0, end: 1, track: "mic", text: "Competing refined")]
        _ = try f.store.saveTranscript(competing, id: f.meeting.id, provider: .apple)
        let path = f.store.folder(f.meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile)
        let current = try Data(contentsOf: path)
        XCTAssertThrowsError(try f.store.saveTranscript(seed, id: f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: path), current); try f.assertLiveUnchanged()
    }
    @MainActor func testCancellationBeforeFirstPublicationLeavesOnlyOriginalLive() async throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let seed = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        var assembled = 0, saved = 0, published = 0
        do {
            _ = try await SavedMeetingTrackProcessor.run(transcript: seed, meetingID: f.meeting.id, track: "mic", provider: .apple,
                assemble: { assembled += 1 }, apple: { _ in XCTFail("ASR callback after retirement") }, local: { [] }, checkpointDue: { true },
                save: { value in saved += 1; return try f.store.saveTranscript(value, id: f.meeting.id) }, publish: { _ in published += 1 }, requireCurrent: { throw CancellationError() })
            XCTFail("Retired operation returned success")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(assembled, 0); XCTAssertEqual(saved, 0); XCTAssertEqual(published, 0)
        XCTAssertNil(try f.store.transcript(f.meeting.id, provider: .apple)); try f.assertLiveUnchanged()
    }
    @MainActor func testCancellationAfterCheckpointRetainsRefinedProgressAndLiveOriginal() async throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let seed = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        var saved = 0
        do {
            _ = try await SavedMeetingTrackProcessor.run(transcript: seed, meetingID: f.meeting.id, track: "mic", provider: .apple,
                assemble: {}, apple: { emit in try emit(f.overlap); throw CancellationError() }, local: { [] }, checkpointDue: { true },
                save: { value in saved += 1; return try f.store.saveTranscript(value, id: f.meeting.id) }, publish: { _ in }, requireCurrent: {})
            XCTFail("Cancelled recognition returned success")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertGreaterThan(saved, 0)
        let partial = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        XCTAssertFalse(partial.completedTracks.contains("mic")); XCTAssertEqual(partial.utterances.first { $0.id == f.edited.id }, f.edited)
        XCTAssertEqual(partial.transcriptionReview?.pending.first?.candidate, f.overlap); try f.assertLiveUnchanged()
    }
    @MainActor func testLiveCreatedAfterInitiallyAbsentSnapshotRefusesFirstSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-live-absent-159-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        let seed = try store.prepareFirstRefinement(meeting.id, provider: .apple, locale: "en-US")
        var live = MeetingTranscript(locale: "en-US"); var line = MeetingUtterance(start: 1, end: 2, track: "mic", text: "Late live")
        line.correction = "Late manual"; line.reviewed = true; live.utterances = [line]
        try store.saveLiveTranscript(live, id: meeting.id, provider: .apple)
        let path = store.folder(meeting.id).appendingPathComponent("live-" + MeetingASRProvider.apple.transcriptFile), bytes = try Data(contentsOf: path)
        XCTAssertThrowsError(try store.saveTranscript(seed, id: meeting.id, provider: .apple))
        XCTAssertNil(try store.transcript(meeting.id, provider: .apple)); XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    @MainActor func testUnreviewedLiveThenNewCorrectionBeforeFirstSaveRefuses() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        var live = f.live
        for index in live.utterances.indices { live.utterances[index].reviewed = false; live.utterances[index].correction = nil }
        try f.store.saveLiveTranscript(live, id: f.meeting.id, provider: .apple)
        let seed = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        live.utterances[0].correction = "Edited after preparation"; live.utterances[0].reviewed = true
        try f.store.saveLiveTranscript(live, id: f.meeting.id, provider: .apple)
        let path = f.store.folder(f.meeting.id).appendingPathComponent("live-" + MeetingASRProvider.apple.transcriptFile), bytes = try Data(contentsOf: path)
        XCTAssertThrowsError(try f.store.saveTranscript(seed, id: f.meeting.id, provider: .apple))
        XCTAssertNil(try f.store.transcript(f.meeting.id, provider: .apple)); XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    @MainActor func testLaterLiveEditAfterCheckpointDoesNotQuarantineRefinedResume() async throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let seed = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        do {
            _ = try await SavedMeetingTrackProcessor.run(transcript: seed, meetingID: f.meeting.id, track: "mic", provider: .apple,
                assemble: {}, apple: { emit in try emit(f.overlap); throw CancellationError() }, local: { [] }, checkpointDue: { true },
                save: { try f.store.saveTranscript($0, id: f.meeting.id) }, publish: { _ in }, requireCurrent: {})
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let partial = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        XCTAssertEqual(partial.utterances.first { $0.id == f.edited.id }, f.edited)
        var live = f.live; live.utterances[0].correction = "Changed after refined checkpoint"
        try f.store.saveLiveTranscript(live, id: f.meeting.id, provider: .apple)
        let path = f.store.folder(f.meeting.id).appendingPathComponent("live-" + MeetingASRProvider.apple.transcriptFile), bytes = try Data(contentsOf: path)
        let reloaded = try SavedMeetingTrackProcessor.prepareTranscription(store: f.store, meetingID: f.meeting.id, provider: .apple, locale: "en-US")
        XCTAssertEqual(reloaded.liveRefinementSource?.sha256, partial.liveRefinementSource?.sha256)
        let next = MeetingUtterance(start: 22, end: 23, track: "mic", text: "New resumed speech")
        let finished = try await SavedMeetingTrackProcessor.run(transcript: reloaded, meetingID: f.meeting.id, track: "mic", provider: .apple,
            assemble: {}, apple: { emit in try emit(next) }, local: { [] }, checkpointDue: { true },
            save: { try f.store.saveTranscript($0, id: f.meeting.id) }, publish: { _ in }, requireCurrent: {})
        XCTAssertTrue(finished.completedTracks.contains("mic")); XCTAssertEqual(finished.utterances.first { $0.id == f.edited.id }, f.edited)
        XCTAssertNotNil(finished.transcriptionReview?.pending.first { $0.id == f.overlap.id }); XCTAssertEqual(try Data(contentsOf: path), bytes)
    }

    @MainActor func testForeignProviderLiveIsNeverImported() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let seed = try f.store.prepareFirstRefinement(f.meeting.id, provider: .nemotron, locale: "en-US")
        XCTAssertTrue(seed.utterances.isEmpty); XCTAssertTrue(seed.names.isEmpty)
        XCTAssertEqual(seed.providerID, MeetingASRProvider.nemotron.rawValue); try f.assertLiveUnchanged()
        let foreign = f.store.folder(f.meeting.id).appendingPathComponent("live-" + MeetingASRProvider.nemotron.transcriptFile)
        try f.originalLiveBytes.write(to: foreign, options: .atomic)
        XCTAssertThrowsError(try f.store.prepareFirstRefinement(f.meeting.id, provider: .nemotron, locale: "en-US"))
        XCTAssertEqual(try Data(contentsOf: foreign), f.originalLiveBytes); XCTAssertNil(try f.store.transcript(f.meeting.id, provider: .nemotron))
        try f.assertLiveUnchanged()
    }
    @MainActor func testMalformedExistingRefinedNeverFallsBackToLive() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let path = f.store.folder(f.meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile), bad = Data("{malformed".utf8)
        try bad.write(to: path, options: .atomic)
        XCTAssertThrowsError(try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US"))
        XCTAssertThrowsError(try f.store.transcript(f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: path), bad); try f.assertLiveUnchanged()
    }

    @MainActor func testV2TargetAppearingBeforeFirstPublicationIsNotOverwritten() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let first = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        var second = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        let origin = MeetingTranscriptionOrigin(meetingID: f.meeting.id, provider: .apple, track: "mic", baseDigest: MeetingNotebook.digest(second))
        try second.beginContinuation(track: "mic", origin: origin); try second.receiveContinuation([f.overlap], origin: origin)
        _ = try f.store.saveTranscript(second, id: f.meeting.id, provider: .apple)
        let path = f.store.folder(f.meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile), bytes = try Data(contentsOf: path)
        XCTAssertThrowsError(try f.store.saveTranscript(first, id: f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: path), bytes); try f.assertLiveUnchanged()
    }

    @MainActor func testMeetingFolderReplacementBeforeFirstPublicationRefuses() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let seed = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        let originalFolder = f.store.folder(f.meeting.id), retained = f.root.appendingPathComponent("retained-original-folder")
        try FileManager.default.moveItem(at: originalFolder, to: retained)
        try f.store.save(f.meeting)
        XCTAssertThrowsError(try f.store.saveTranscript(seed, id: f.meeting.id, provider: .apple))
        XCTAssertNil(try f.store.transcript(f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("live-" + MeetingASRProvider.apple.transcriptFile)), f.originalLiveBytes)
    }

    @MainActor func testRefinementNoticeFitsBoundedComparisonFrame() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let seed = try SavedMeetingTrackProcessor.prepareTranscription(store: f.store, meetingID: f.meeting.id, provider: .apple, locale: "en-US")
        let source = try XCTUnwrap(seed.liveRefinementSource)
        var state = MeetingTranscriptionReviewViewState()
        state.count = 4096; state.protectedRows = 39999; state.meeting = f.meeting.id.uuidString
        state.provider = "nemotron"; state.revision = UUID().uuidString; state.candidate = UUID().uuidString; state.digest = String(repeating: "a", count: 64)
        state.attempt = UUID().uuidString; state.track = "system"; state.status = "May overlap reviewed words. " + source.notice
        state.modelRevision = String(repeating: "x", count: 120); state.runtimeRevision = String(repeating: "y", count: 120)
        state.candidateText = String(repeating: "\u{0000}", count: 1024); state.protectedText = String(repeating: "\u{0000}", count: 1024)
        let frame = MeetingTranscriptionViewFrame.state(state)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(frame).count, 32_768)
        XCTAssertNil(frame["ask"]); XCTAssertNil(frame["notebook"])
    }

    @MainActor func testSnapshotDescriptorCannotBeStrippedOrReplaced() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let original = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        let source = try XCTUnwrap(original.liveRefinementSource)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        fields["locale"] = "fr-FR"
        let replacement = try JSONDecoder().decode(MeetingLiveRefinementSource.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(replacement.meetingID, source.meetingID); XCTAssertEqual(replacement.provider, source.provider)
        XCTAssertEqual(replacement.includedRowIDs, source.includedRowIDs); XCTAssertNotEqual(replacement, source)
        var stripped = original; stripped.liveRefinementSource = nil
        XCTAssertThrowsError(try f.store.saveTranscript(stripped, id: f.meeting.id, provider: .apple))
        var escaped = original; escaped.liveRefinementSource = nil; escaped.transcriptionReview = nil
        XCTAssertThrowsError(try f.store.saveTranscript(escaped, id: f.meeting.id, provider: .apple))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.folder(f.meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile).path))
        var replaced = original; replaced.liveRefinementSource = replacement
        XCTAssertThrowsError(try f.store.saveTranscript(replaced, id: f.meeting.id, provider: .apple))
        XCTAssertNil(try f.store.transcript(f.meeting.id, provider: .apple))
        let stored = try f.store.saveTranscript(original, id: f.meeting.id, provider: .apple)
        let path = f.store.folder(f.meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        let bytes = try Data(contentsOf: path)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 3)
        var laterStripped = stored; laterStripped.liveRefinementSource = nil
        XCTAssertThrowsError(try f.store.saveTranscript(laterStripped, id: f.meeting.id, provider: .apple))
        var laterEscaped = stored; laterEscaped.liveRefinementSource = nil; laterEscaped.transcriptionReview = nil
        XCTAssertThrowsError(try f.store.saveTranscript(laterEscaped, id: f.meeting.id, provider: .apple))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.folder(f.meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile).path))
        var laterReplaced = stored; laterReplaced.liveRefinementSource = replacement
        XCTAssertThrowsError(try f.store.saveTranscript(laterReplaced, id: f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertEqual(try f.store.transcript(f.meeting.id, provider: .apple)?.liveRefinementSource, stored.liveRefinementSource)
        try f.assertLiveUnchanged()
    }

    @MainActor func testCatchUpWindowAcceptsSelectedSnapshotWithoutMutatingDurableProvenance() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let seed = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        _ = try f.store.saveTranscript(seed, id: f.meeting.id, provider: .apple)
        let saved = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        let source = try XCTUnwrap(saved.liveRefinementSource)
        let window = try MeetingCatchUpWindow(meetingID: f.meeting.id, transcript: saved, through: 12, seconds: 30)
        XCTAssertEqual(Set(window.transcript.utterances.map(\.id)), Set([f.edited.id, f.speakerOnly.id]))
        try window.transcript.validate()
        let path = f.store.folder(f.meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        let bytes = try Data(contentsOf: path)
        XCTAssertThrowsError(try f.store.saveTranscript(window.transcript, id: f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertEqual(try f.store.transcript(f.meeting.id, provider: .apple)?.liveRefinementSource, source)
        XCTAssertEqual(Set(source.includedRowIDs), Set([f.edited.id, f.speakerOnly.id, f.system.id]))
        try f.assertLiveUnchanged()
    }

    @MainActor func testMislabeledVersionTwoSnapshotRefusesWithoutFallback() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let seed = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        _ = try f.store.saveTranscript(seed, id: f.meeting.id, provider: .apple)
        let path = f.store.folder(f.meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 3)
        envelope["version"] = 2
        let mismatched = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        try mismatched.write(to: path, options: .atomic)
        XCTAssertThrowsError(try f.store.transcript(f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: path), mismatched); try f.assertLiveUnchanged()
    }

    @MainActor func testNormalPresentationKeepsRefinedWhenLaterLiveIsMalformed() throws {
        let f = try LiveRefinementFixture159(provider: .apple); defer { try? f.cleanup() }
        let seed = try f.store.prepareFirstRefinement(f.meeting.id, provider: .apple, locale: "en-US")
        _ = try f.store.saveTranscript(seed, id: f.meeting.id, provider: .apple)
        let folder = f.store.folder(f.meeting.id)
        let liveURL = folder.appendingPathComponent("live-" + MeetingASRProvider.apple.transcriptFile)
        let refinedURL = folder.appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        let refinedBytes = try Data(contentsOf: refinedURL), badLive = Data("{broken live".utf8)
        try badLive.write(to: liveURL, options: .atomic)
        let view = try SavedMeetingTrackProcessor.loadPresentation(store: f.store, meetingID: f.meeting.id, provider: .apple)
        XCTAssertTrue(view.hasRefined); XCTAssertTrue(view.hasLive); XCTAssertFalse(view.showingLive)
        XCTAssertEqual(view.transcript?.utterances.first { $0.id == f.edited.id }, f.edited)
        XCTAssertEqual(view.transcript?.liveRefinementSource?.sha256, seed.liveRefinementSource?.sha256)
        XCTAssertThrowsError(try SavedMeetingTrackProcessor.loadPresentation(store: f.store, meetingID: f.meeting.id, provider: .apple, preferLive: true))
        XCTAssertEqual(try Data(contentsOf: liveURL), badLive); XCTAssertEqual(try Data(contentsOf: refinedURL), refinedBytes)
        try f.originalLiveBytes.write(to: liveURL, options: .atomic)
        let badRefined = Data("{broken refined".utf8); try badRefined.write(to: refinedURL, options: .atomic)
        XCTAssertThrowsError(try SavedMeetingTrackProcessor.loadPresentation(store: f.store, meetingID: f.meeting.id, provider: .apple))
        XCTAssertThrowsError(try SavedMeetingTrackProcessor.loadPresentation(store: f.store, meetingID: f.meeting.id, provider: .apple, preferLive: true))
        XCTAssertEqual(try Data(contentsOf: refinedURL), badRefined); try f.assertLiveUnchanged()
    }

}
