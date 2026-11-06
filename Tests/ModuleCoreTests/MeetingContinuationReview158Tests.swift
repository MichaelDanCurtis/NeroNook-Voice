import Foundation
import XCTest
@testable import ModuleCore

final class MeetingContinuationReview158Tests: XCTestCase {
    private func origin(_ f: MeetingContinuationFixture158, transcript: MeetingTranscript) -> MeetingTranscriptionOrigin {
        .init(meetingID: f.meeting.id, provider: f.provider, track: "mic", baseDigest: MeetingNotebook.digest(transcript),
              modelRevision: "authored-model", runtimeRevision: "authored-runtime")
    }
    private func resumed(_ f: MeetingContinuationFixture158) throws -> MeetingTranscript {
        var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: f.provider))
        let source = origin(f, transcript: value)
        try value.beginContinuation(track: "mic", origin: source)
        try value.receiveContinuation([f.wideAlternative, f.disjointAlternative], origin: source)
        try value.finishContinuation(track: "mic")
        return try f.store.saveTranscript(value, id: f.meeting.id, provider: f.provider)
    }
    func testReviewedRowAndOtherTrackSurviveWithFullOverlapAndDisjointSpeech() throws {
        for provider in [MeetingASRProvider.apple, .nemotron] {
            let f = try MeetingContinuationFixture158(provider: provider); defer { try? f.cleanup() }
            let saved = try resumed(f)
            let reloaded = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: provider))
            XCTAssertEqual(reloaded.utterances.first { $0.id == f.protected.id }, f.protected)
            XCTAssertEqual(reloaded.utterances.first { $0.id == f.otherTrack.id }, f.otherTrack)
            XCTAssertEqual(reloaded.utterances.first { $0.id == f.disjointAlternative.id }, f.disjointAlternative)
            XCTAssertEqual(reloaded.names["mic-3"], "Mara")
            XCTAssertTrue(reloaded.completedTracks.contains("mic")); XCTAssertTrue(reloaded.hasPendingTranscription)
            let pending = try XCTUnwrap(reloaded.transcriptionReview?.pending.first)
            XCTAssertEqual(pending.candidate, f.wideAlternative)
            XCTAssertEqual(pending.origin.provider, provider); XCTAssertEqual(pending.origin.meetingID, f.meeting.id)
            XCTAssertEqual(pending.origin.modelRevision, "authored-model"); XCTAssertEqual(pending.origin.runtimeRevision, "authored-runtime")
            XCTAssertNil(reloaded.transcriptionReview?.origins[f.protected.id.uuidString], "Old manual speech must not be attributed to the new recognition attempt")
            XCTAssertEqual(reloaded.transcriptionReview?.origins[f.disjointAlternative.id.uuidString]?.attemptID, pending.origin.attemptID)
            XCTAssertEqual(reloaded.transcriptionReview?.origins[f.wideAlternative.id.uuidString]?.attemptID, pending.origin.attemptID)
            XCTAssertEqual(reloaded.pendingTranscriptionCount, 1)
            XCTAssertEqual(saved.transcriptionRevision, reloaded.transcriptionRevision)
            try f.assertCitation(reloaded); try f.assertOriginalV1Unchanged()
        }
    }
    func testExplicitChoicesKeepManualRowAndRequireCurrentDigest() throws {
        for choice in [MeetingTranscriptionChoice.keepCorrection, .keepBoth] {
            let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
            var value = try resumed(f); let candidate = try XCTUnwrap(value.transcriptionReview?.pending.first)
            let digest = MeetingNotebook.digest(value)
            XCTAssertThrowsError(try value.resolveAlternative(candidate.id, expectedDigest: String(repeating: "0", count: 64), choice: choice))
            let resolved = try value.resolveAlternative(candidate.id, expectedDigest: digest, choice: choice)
            value = try f.store.saveTranscript(resolved, id: f.meeting.id, provider: .apple)
            XCTAssertEqual(value.utterances.first { $0.id == f.protected.id }, f.protected)
            XCTAssertEqual(value.pendingTranscriptionCount, 0)
            if choice == .keepBoth {
                let kept = try XCTUnwrap(value.utterances.first { $0.id == f.wideAlternative.id })
                XCTAssertEqual(kept.text, f.wideAlternative.text); XCTAssertEqual(kept.start, f.wideAlternative.start); XCTAssertEqual(kept.end, f.wideAlternative.end); XCTAssertEqual(kept.words, f.wideAlternative.words)
                XCTAssertNil(kept.speaker); XCTAssertTrue(kept.reviewed)
            } else { XCTAssertFalse(value.utterances.contains { $0.id == f.wideAlternative.id }) }
            XCTAssertThrowsError(try value.resolveAlternative(candidate.id, expectedDigest: digest, choice: choice))
            try f.assertCitation(value); try f.assertOriginalV1Unchanged()
        }
    }
    func testV1BlindOldWriterCannotEraseV2AndDivergenceIsRefused() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var cachedOld = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        let value = try resumed(f); XCTAssertTrue(f.store.hasTranscriptV2(f.meeting.id, provider: .apple))
        let v2 = f.store.folder(f.meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        let before = try Data(contentsOf: v2)
        // Mechanical original old saveTranscript body: validate and atomically
        // overwrite ONLY its original v1 file, with the value cached pre-migration.
        cachedOld.utterances[0].correction = "Legacy writer changed this"
        try f.originalBlindSave(cachedOld)
        XCTAssertEqual(try Data(contentsOf: v2), before)
        XCTAssertThrowsError(try f.store.transcript(f.meeting.id, provider: .apple))
        XCTAssertThrowsError(try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: v2), before)
    }
    func testPresentMalformedV2DoesNotFallbackToIntactV1() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        let v2 = f.store.folder(f.meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        let bytes = Data("{malformed".utf8); try bytes.write(to: v2, options: .atomic)
        XCTAssertThrowsError(try f.store.transcript(f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: v2), bytes); try f.assertOriginalV1Unchanged()
    }
    func testStaleV1SnapshotCannotMigrateOverChangedV1() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var stale = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        let source = origin(f, transcript: stale); try stale.beginContinuation(track: "mic", origin: source)
        try stale.receiveContinuation([f.wideAlternative], origin: source)
        var legacy = f.initial; legacy.utterances[0].correction = "Changed before migration"
        try f.originalBlindSave(legacy)
        let raw = try Data(contentsOf: f.store.folder(f.meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile))
        XCTAssertThrowsError(try f.store.saveTranscript(stale, id: f.meeting.id, provider: .apple))
        XCTAssertFalse(f.store.hasTranscriptV2(f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: f.store.folder(f.meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile)), raw)
    }
    func testPendingLimitRefusesWholeBatchWithoutMutation() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        let source = origin(f, transcript: value); try value.beginContinuation(track: "mic", origin: source)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(value)
        let overflow = (0..<4097).map { _ in MeetingUtterance(start: 4, end: 8, track: "mic", text: "Overlapping authored row") }
        XCTAssertThrowsError(try value.receiveContinuation(overflow, origin: source))
        XCTAssertEqual(try encoder.encode(value), before); try f.assertOriginalV1Unchanged()
    }
    func testWrongTrackRowIsRefusedWithoutMutation() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        let source = origin(f, transcript: value); try value.beginContinuation(track: "mic", origin: source)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let before = try encoder.encode(value)
        XCTAssertThrowsError(try value.receiveContinuation([f.otherTrack], origin: source))
        XCTAssertEqual(try encoder.encode(value), before); try f.assertOriginalV1Unchanged()
    }

    func testUnresolvedAlternativeIsLabeledAndNotReportedAsFullQuestionCoverage() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        var notebook = MeetingNotebook(meetingID: f.meeting.id); notebook.summary = "Earlier generated summary"; notebook.sourceDigest = MeetingNotebook.digest(value)
        let source = origin(f, transcript: value); try value.beginContinuation(track: "mic", origin: source)
        try value.receiveContinuation([f.wideAlternative], origin: source); try value.finishContinuation(track: "mic")
        value = try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple)
        XCTAssertFalse(notebook.isCurrent(for: value))
        let text = MeetingReadContract.text(f.meeting, notebook: notebook, transcript: value, personal: false)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("review")); XCTAssertTrue(text.contains(f.wideAlternative.text))
        XCTAssertThrowsError(try MeetingQuestionSnapshot.prepare(meetingID: f.meeting.id, transcript: value, provider: .apple, live: false, question: "What was agreed?"))
        XCTAssertThrowsError(try MeetingChatEvidence.current(meeting: f.meeting, transcript: value, provider: .apple, live: false, question: "What was agreed?", context: []))
        try f.assertCitation(value)
    }

    func testOldVisibleChoiceCannotResolveAfterAnotherCorrection() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try resumed(f)
        let pending = try XCTUnwrap(value.transcriptionReview?.pending.first)
        let oldDigest = MeetingNotebook.digest(value)
        let index = try XCTUnwrap(value.utterances.firstIndex { $0.id == f.protected.id })
        value.utterances[index].correction = "A newer manual correction"
        value = try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple)
        XCTAssertThrowsError(try value.resolveAlternative(pending.id, expectedDigest: oldDigest, choice: .keepBoth))
        let read = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        XCTAssertEqual(read.pendingTranscriptionCount, 1)
        XCTAssertEqual(read.utterances.first { $0.id == f.protected.id }?.correction, "A newer manual correction")
    }

    func testSpeakerOnlyReviewedPassageIsProtected() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        value.utterances[0].correction = nil; value.utterances[0].reviewed = true
        value = try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple)
        let old = value.utterances[0], source = origin(f, transcript: value)
        try value.beginContinuation(track: "mic", origin: source)
        try value.receiveContinuation([f.wideAlternative], origin: source)
        value = try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple)
        XCTAssertEqual(value.utterances.first { $0.id == old.id }, old)
        XCTAssertEqual(value.transcriptionReview?.pending.first?.candidate, f.wideAlternative)
    }

    func testCorrectionOnlyAndMultipleProtectedRowsNeverInferAlignment() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        value.utterances[0].reviewed = false // A correction alone is protected.
        var second = MeetingUtterance(start: 8.5, end: 9, track: "mic", text: "Second protected")
        second.reviewed = true; second.speaker = "mic-2"; value.utterances.append(second); value.names["mic-2"] = "Morgan"
        value = try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple)
        let first = value.utterances[0], source = origin(f, transcript: value)
        try value.beginContinuation(track: "mic", origin: source)
        try value.receiveContinuation([f.wideAlternative], origin: source)
        value = try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple)
        let pending = try XCTUnwrap(value.transcriptionReview?.pending.first)
        XCTAssertEqual(pending.candidate, f.wideAlternative)
        XCTAssertEqual(Set(value.protectedPassages(for: pending).map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(value.utterances.first { $0.id == first.id }, first)
        XCTAssertEqual(value.utterances.first { $0.id == second.id }, second)
    }

    func testForeignOriginCannotBeSavedUnderAnotherMeetingOrProvider() throws {
        for wrongMeeting in [true, false] {
            let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
            var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
            let source = MeetingTranscriptionOrigin(meetingID: wrongMeeting ? UUID() : f.meeting.id,
                provider: wrongMeeting ? .apple : .nemotron, track: "mic", baseDigest: MeetingNotebook.digest(value))
            do {
                try value.beginContinuation(track: "mic", origin: source)
                try value.receiveContinuation([f.wideAlternative], origin: source)
                XCTAssertThrowsError(try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple))
            } catch { /* A stricter early validation is also a refusal. */ }
            XCTAssertFalse(f.store.hasTranscriptV2(f.meeting.id, provider: .apple))
            try f.assertOriginalV1Unchanged()
        }
    }

    func testStaleV2WriterCannotReplaceNewerReview() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        let stale = try resumed(f); var newer = stale
        let index = try XCTUnwrap(newer.utterances.firstIndex { $0.id == f.protected.id })
        newer.utterances[index].correction = "Newer correction"
        newer = try f.store.saveTranscript(newer, id: f.meeting.id, provider: .apple)
        let v2 = f.store.folder(f.meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        let bytes = try Data(contentsOf: v2)
        XCTAssertThrowsError(try f.store.saveTranscript(stale, id: f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: v2), bytes)
        let reloaded = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        XCTAssertEqual(reloaded.transcriptionRevision, newer.transcriptionRevision)
        XCTAssertEqual(reloaded.utterances.first { $0.id == f.protected.id }?.correction, "Newer correction")
        XCTAssertEqual(reloaded.pendingTranscriptionCount, 1)
    }

    func testLinkedV2IsNotTreatedAsAbsentOrFollowed() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        let v1 = f.store.folder(f.meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile)
        let v2 = f.store.folder(f.meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        try FileManager.default.createSymbolicLink(at: v2, withDestinationURL: v1)
        XCTAssertThrowsError(try f.store.transcript(f.meeting.id, provider: .apple))
        try f.assertOriginalV1Unchanged()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: v2.path), v1.path)
    }

    func testMissingV2AfterCapturedBindingCannotRecreateOrFallbackOnSave() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        let captured = try resumed(f)
        let v2 = f.store.folder(f.meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        let backup = try Data(contentsOf: v2); try FileManager.default.removeItem(at: v2)
        XCTAssertThrowsError(try f.store.saveTranscript(captured, id: f.meeting.id, provider: .apple))
        XCTAssertFalse(FileManager.default.fileExists(atPath: v2.path)); try f.assertOriginalV1Unchanged()
        // This authored copy is retained in test memory, not interpreted as a
        // successful recovery or as authorization to replace the missing file.
        XCTAssertFalse(backup.isEmpty)
    }

    func testFreshChoiceStillResolvesAfterProtectedPassageWasEdited() throws {
        for choice in [MeetingTranscriptionChoice.keepCorrection, .keepBoth] {
            let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
            var value = try resumed(f); let pending = try XCTUnwrap(value.transcriptionReview?.pending.first)
            let oldDigest = MeetingNotebook.digest(value)
            let index = try XCTUnwrap(value.utterances.firstIndex { $0.id == f.protected.id })
            value.utterances[index].correction = "Updated manual correction"
            value = try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple)
            XCTAssertThrowsError(try value.resolveAlternative(pending.id, expectedDigest: oldDigest, choice: choice))
            let fresh = try value.resolveAlternative(pending.id, expectedDigest: MeetingNotebook.digest(value), choice: choice)
            let saved = try f.store.saveTranscript(fresh, id: f.meeting.id, provider: .apple)
            XCTAssertEqual(saved.utterances.first { $0.id == f.protected.id }?.correction, "Updated manual correction")
            XCTAssertEqual(saved.pendingTranscriptionCount, 0)
            XCTAssertEqual(saved.utterances.contains { $0.id == f.wideAlternative.id }, choice == .keepBoth)
        }
    }

    func testPreparedEmptyTranscriptCannotOverwriteLaterLegacyCreation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-empty-anchor-158-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var prepared = try store.prepareNewTranscript(meeting.id, provider: .apple, locale: "en-US")
        let origin = MeetingTranscriptionOrigin(meetingID: meeting.id, provider: .apple, track: "mic", baseDigest: MeetingNotebook.digest(prepared))
        try prepared.beginContinuation(track: "mic", origin: origin)
        try prepared.receiveContinuation([.init(start: 0, end: 1, track: "mic", text: "Prepared speech")], origin: origin)
        var legacy = MeetingTranscript(locale: "en-US"); legacy.utterances = [.init(start: 0, end: 1, track: "mic", text: "Later old writer")]
        // Mechanical old writer body after the absence token was minted.
        _ = try store.load(meeting.id); try legacy.validate(); let bytes = try JSONEncoder().encode(legacy)
        guard bytes.count <= 32_000_000 else { throw VoiceProblem.message("Transcript exceeds its limit") }
        let v1 = store.folder(meeting.id).appendingPathComponent(MeetingASRProvider.apple.transcriptFile)
        try bytes.write(to: v1, options: .atomic)
        XCTAssertThrowsError(try store.saveTranscript(prepared, id: meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: v1), bytes); XCTAssertFalse(store.hasTranscriptV2(meeting.id, provider: .apple))
    }
    func testV2WriterCannotStripReviewMetadata() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try resumed(f); value.transcriptionReview = nil
        let v2 = f.store.folder(f.meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        let bytes = try Data(contentsOf: v2)
        XCTAssertThrowsError(try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple))
        XCTAssertEqual(try Data(contentsOf: v2), bytes)
        let read = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple)); XCTAssertEqual(read.pendingTranscriptionCount, 1)
    }

    func testPreparedEmptyTranscriptCanSaveFirstRealRecognition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-first-recognition-158-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root)
        var meeting = Meeting(title: "Authored", source: "none", microphone: true); meeting.state = "saved"; try store.save(meeting)
        var prepared = try store.prepareNewTranscript(meeting.id, provider: .apple, locale: "en-US")
        let origin = MeetingTranscriptionOrigin(meetingID: meeting.id, provider: .apple, track: "mic", baseDigest: MeetingNotebook.digest(prepared))
        let line = MeetingUtterance(start: 0, end: 1, track: "mic", text: "First actual recognition")
        try prepared.beginContinuation(track: "mic", origin: origin); try prepared.receiveContinuation([line], origin: origin); try prepared.finishContinuation(track: "mic")
        let saved = try store.saveTranscript(prepared, id: meeting.id, provider: .apple)
        XCTAssertEqual(saved.utterances, [line]); XCTAssertEqual(try store.transcript(meeting.id)?.utterances, [line])
    }

    func testKeepBothRoundTripLabelsRecognitionVersionWithoutChangingOldCitation() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        let current = try resumed(f), item = try XCTUnwrap(current.transcriptionReview?.pending.first)
        let decided = try current.resolveAlternative(item.id, expectedDigest: MeetingNotebook.digest(current), choice: .keepBoth)
        _ = try f.store.saveTranscript(decided, id: f.meeting.id, provider: .apple)
        let read = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        XCTAssertEqual(read.pendingTranscriptionCount, 0); try f.assertCitation(read)
        XCTAssertTrue(read.isKeptRecognitionAlternative(f.wideAlternative.id))
        XCTAssertFalse(read.isKeptRecognitionAlternative(f.protected.id))
        let text = MeetingReadContract.text(f.meeting, notebook: nil, transcript: read, personal: false)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("recognition version")); XCTAssertTrue(text.contains(f.wideAlternative.text))
        let question = try MeetingQuestionSnapshot.prepare(meetingID: f.meeting.id, transcript: read, provider: .apple, live: false, question: "What were the competing words?")
        let newSource = try XCTUnwrap(question.sources.first { $0.utteranceID == f.wideAlternative.id })
        XCTAssertTrue(newSource.evidence.label.localizedCaseInsensitiveContains("recognition version"))
        XCTAssertEqual(try f.citation.resolve(meetingID: f.meeting.id, transcript: read).id, f.protected.id)
        var relabeled = read
        relabeled.transcriptionReview?.keptAlternativeIDs = []
        relabeled.transcriptionReview?.keptProtectedFingerprints = [:]
        XCTAssertThrowsError(try question.resolve(newSource.evidence.id, meetingID: f.meeting.id, transcript: relabeled))
        XCTAssertEqual(try f.citation.resolve(meetingID: f.meeting.id, transcript: relabeled).id, f.protected.id)
    }

    func testExistingProtectedOriginIsPreservedAcrossNewAttempt() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        let originalOrigin = MeetingTranscriptionOrigin(meetingID: f.meeting.id, provider: .apple, track: "mic", baseDigest: MeetingNotebook.digest(value), modelRevision: "older-authored-model")
        value.transcriptionReview = .init(origins: [f.protected.id.uuidString: originalOrigin])
        value = try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple)
        let newer = origin(f, transcript: value); try value.beginContinuation(track: "mic", origin: newer)
        try value.receiveContinuation([f.wideAlternative], origin: newer)
        value = try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple)
        let reload = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        XCTAssertEqual(reload.transcriptionReview?.origins[f.protected.id.uuidString], originalOrigin)
        XCTAssertEqual(reload.transcriptionReview?.origins[f.wideAlternative.id.uuidString], newer)
        XCTAssertEqual(reload.utterances.first { $0.id == f.protected.id }, f.protected)
    }

    func testOtherPendingChoiceRemainsResolvableAfterKeepBoth() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        let source = origin(f, transcript: value)
        let second = MeetingUtterance(start: 3, end: 7, track: "mic", text: "Another full alternative")
        try value.beginContinuation(track: "mic", origin: source)
        try value.receiveContinuation([f.wideAlternative, second], origin: source)
        value = try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple)
        let staleDigest = MeetingNotebook.digest(value)
        value = try f.store.saveTranscript(value.resolveAlternative(f.wideAlternative.id, expectedDigest: staleDigest, choice: .keepBoth), id: f.meeting.id, provider: .apple)
        XCTAssertThrowsError(try value.resolveAlternative(second.id, expectedDigest: staleDigest, choice: .keepCorrection))
        value = try f.store.saveTranscript(value.resolveAlternative(second.id, expectedDigest: MeetingNotebook.digest(value), choice: .keepCorrection), id: f.meeting.id, provider: .apple)
        XCTAssertEqual(value.pendingTranscriptionCount, 0)
        XCTAssertEqual(value.utterances.first { $0.id == f.protected.id }, f.protected)
        XCTAssertNotNil(value.utterances.first { $0.id == f.wideAlternative.id })
        XCTAssertNil(value.utterances.first { $0.id == second.id })
    }

    func testKeptAlternativeDoesNotInventSecondDeterministicCommitment() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        let source = origin(f, transcript: value)
        let alternative = MeetingUtterance(start: 3, end: 7, track: "mic", text: "I will send the invoice by Friday.")
        try value.beginContinuation(track: "mic", origin: source); try value.receiveContinuation([alternative], origin: source)
        value = try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple)
        value = try f.store.saveTranscript(value.resolveAlternative(alternative.id, expectedDigest: MeetingNotebook.digest(value), choice: .keepBoth), id: f.meeting.id, provider: .apple)
        XCTAssertTrue(value.isKeptRecognitionAlternative(alternative.id))
        XCTAssertTrue(try MeetingActionReconciler.proposals(value).isEmpty)
        XCTAssertEqual(value.utterances.first { $0.id == f.protected.id }, f.protected)
    }

    func testOriginalDecoderStillReadsV1AndRejectsV2Envelope() throws {
        struct OriginalTranscript: Decodable {
            let utterances: [MeetingUtterance]
            let names: [String: String]
            let completedTracks: [String]
            let labelledTracks: [String]
            let locale: String
            let providerID: String?
            let modelRevision: String?
            let runtimeRevision: String?
            let speakerModelRevision: String?
        }
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        let legacy = try JSONDecoder().decode(OriginalTranscript.self, from: f.originalV1)
        XCTAssertEqual(legacy.utterances.first { $0.id == f.protected.id }, f.protected)
        _ = try resumed(f)
        let v2 = f.store.folder(f.meeting.id).appendingPathComponent("review-v2-" + MeetingASRProvider.apple.transcriptFile)
        XCTAssertThrowsError(try JSONDecoder().decode(OriginalTranscript.self, from: Data(contentsOf: v2)))
        try f.assertOriginalV1Unchanged()
    }

    func testEncodedReviewSizeLimitPreservesOriginalOnRefusal() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        let source = origin(f, transcript: value); try value.beginContinuation(track: "mic", origin: source)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; let before = try encoder.encode(value)
        // Below 4096 pending and 40000 total, but text alone exceeds 32 MB.
        let big = String(repeating: "x", count: 16_000)
        let rows = (0..<2001).map { _ in MeetingUtterance(start: 4, end: 8, track: "mic", text: big) }
        do {
            try value.receiveContinuation(rows, origin: source)
            XCTAssertThrowsError(try f.store.saveTranscript(value, id: f.meeting.id, provider: .apple))
        } catch {
            XCTAssertEqual(try encoder.encode(value), before, "Rejected batch must leave its input intact")
        }
        XCTAssertFalse(f.store.hasTranscriptV2(f.meeting.id, provider: .apple)); try f.assertOriginalV1Unchanged()
    }

    func testCombinedFortyThousandRowLimitRejectsAdditionalPassage() throws {
        let f = try MeetingContinuationFixture158(provider: .apple); defer { try? f.cleanup() }
        var value = try XCTUnwrap(f.store.transcript(f.meeting.id, provider: .apple))
        value.utterances = [f.protected] + (0..<39_999).map { _ in MeetingUtterance(start: 0, end: 1, track: "system", text: "s") }
        try value.validate()
        let source = origin(f, transcript: value); try value.beginContinuation(track: "mic", origin: source)
        XCTAssertEqual(value.utterances.count, 40_000)
        XCTAssertThrowsError(try value.receiveContinuation([f.wideAlternative], origin: source))
        XCTAssertEqual(value.utterances.count, 40_000); XCTAssertEqual(value.utterances.first, f.protected)
        XCTAssertEqual(value.pendingTranscriptionCount, 0); try f.assertOriginalV1Unchanged()
    }

}
