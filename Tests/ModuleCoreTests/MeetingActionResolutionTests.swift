import XCTest
@testable import ModuleCore

final class MeetingActionResolutionTests: XCTestCase {
    private func transcript() -> MeetingTranscript {
        var value = MeetingTranscript(locale: "en-US")
        value.names = ["mic-0": "Lena", "system-0": "Omar"]
        for (index, text) in ["I will prepare the launch checklist by Monday.",
                              "I will take over the launch checklist from Lena and finish it Wednesday instead.",
                              "Cancel the launch checklist. We no longer need it."].enumerated() {
            var turn = MeetingUtterance(start: Double(index * 10), end: Double(index * 10 + 8),
                                        track: index == 1 ? "system" : "mic", text: text)
            turn.speaker = index == 1 ? "system-0" : "mic-0"; value.utterances.append(turn)
        }
        return value
    }
    private var reassigned: MeetingActionProposal {
        .init(task: "prepare the launch checklist", taskSource: 0, owner: "I", ownerSource: 1,
              deadline: "Wednesday", deadlineSource: 1, sources: [0, 1])
    }
    private func resolve(_ input: [MeetingActionProposal], _ transcript: MeetingTranscript? = nil) throws -> [MeetingActionResolution] {
        try MeetingActionResolution.resolve(input, transcript: transcript ?? self.transcript(), allowedSources: [0, 1, 2])
    }
    private func notebook(_ resolutions: [MeetingActionResolution], transcript: MeetingTranscript) -> MeetingNotebook {
        var value = MeetingNotebook(meetingID: UUID()); value.actionResolutions = resolutions
        value.sourceDigest = MeetingNotebook.digest(transcript)
        value.evidence = resolutions.filter { $0.status == .active }.map { $0.evidence[0] }
        value.actions = (value.evidence ?? []).map { String(format: "[%02d:%02d] ", Int($0.start)/60, Int($0.start)%60) + $0.fact }.joined(separator: "\n")
        return value
    }
    func testReassignmentUsesQuotedCurrentOwnerAndDeadlineWithBothSources() throws {
        let source = transcript(), item = try XCTUnwrap(resolve([reassigned], source).first)
        XCTAssertEqual(item.owner, "Omar"); XCTAssertEqual(item.deadline, "Wednesday")
        XCTAssertEqual(item.evidence.map(\.utteranceID), Array(source.utterances.prefix(2)).map(\.id))
        XCTAssertTrue(item.fact.contains("Omar")); XCTAssertFalse(item.fact.contains("Monday"))
        for link in item.evidence { XCTAssertNoThrow(try link.resolve(in: source, digest: MeetingNotebook.digest(source))) }
    }
    func testCancelledTaskIsAbsentFromActiveListButRetainsNavigableChanges() throws {
        var proposal = reassigned; proposal.status = "cancelled"; proposal.sources = [0, 1, 2]
        let source = transcript(), value = notebook(try resolve([proposal], source), transcript: source)
        try value.validate(); XCTAssertTrue(value.actions.isEmpty)
        XCTAssertTrue(value.taskChanges.contains("Cancelled")); XCTAssertEqual(value.actionCards.first?.status, "cancelled")
        XCTAssertEqual(value.actionResolutions?.first?.evidence.count, 3)
        XCTAssertTrue(value.markdown(title: "Authored", includeThoughts: false).contains("Task changes"))
    }
    func testUnknownSpeakerAndPronounsNeverBecomeNamedOwners() throws {
        var source = transcript(); source.names["system-0"] = "Room speaker 2"
        XCTAssertNil(try resolve([reassigned], source).first?.owner)
        source.names = [:]; XCTAssertNil(try resolve([reassigned], source).first?.owner)
        var proposal = reassigned; proposal.owner = "We"; proposal.ownerSource = 2
        proposal.sources = [0, 1, 2]; XCTAssertNil(try resolve([proposal]).first?.owner)
    }
    func testAbsentDeadlineStaysAbsentRatherThanBorrowingAnotherTaskDate() throws {
        var proposal = reassigned; proposal.deadline = ""; proposal.deadlineSource = -1
        let result = try XCTUnwrap(resolve([proposal]).first)
        XCTAssertNil(result.deadline); XCTAssertTrue(result.fact.contains("No deadline stated"))
    }
    func testUncertainProposalIsNotAnActiveCommitment() throws {
        var proposal = reassigned; proposal.status = "uncertain"
        let source = transcript(), value = notebook(try resolve([proposal], source), transcript: source)
        try value.validate(); XCTAssertTrue(value.actions.isEmpty); XCTAssertTrue(value.taskChanges.contains("Needs review"))
    }
    func testInventedFieldsUnknownSourceAndUnsupportedStateRefuse() throws {
        var inputs: [MeetingActionProposal] = []
        var p = reassigned; p.task = "send the invoice"; inputs.append(p)
        p = reassigned; p.owner = "Invented Person"; inputs.append(p)
        p = reassigned; p.deadline = "2027-03-01"; inputs.append(p)
        p = reassigned; p.ownerSource = -1; inputs.append(p)
        p = reassigned; p.taskSource = 999; inputs.append(p)
        p = reassigned; p.sources = [0, 1, 999]; inputs.append(p)
        p = reassigned; p.sources = [0, 0, 1]; inputs.append(p)
        p = reassigned; p.sources = [0]; inputs.append(p)
        p = reassigned; p.status = "completed-by-tool"; inputs.append(p)
        for input in inputs { XCTAssertThrowsError(try resolve([input])) }
        XCTAssertThrowsError(try MeetingActionResolution.resolve([reassigned], transcript: transcript(), allowedSources: [0]))
        XCTAssertThrowsError(try resolve([reassigned, reassigned]))
        XCTAssertThrowsError(try resolve(Array(repeating: reassigned, count: 13)))
    }
    func testCorrectionAndRenamingInvalidateEveryActionSource() throws {
        let original = transcript(), item = try XCTUnwrap(resolve([reassigned], original).first)
        var changed = original; changed.utterances[1].correction = "Nobody took over."
        for evidence in item.evidence { XCTAssertThrowsError(try evidence.resolve(in: changed, digest: MeetingNotebook.digest(original))) }
        changed = original; changed.names["system-0"] = "Different name"
        XCTAssertThrowsError(try item.evidence[0].resolve(in: changed, digest: MeetingNotebook.digest(original)))
        XCTAssertThrowsError(try resolve([reassigned], { var corrected = original; corrected.utterances[1].correction = "No deadline."; return corrected }()))
    }
    func testSavedRoundTripAndManualEditRetainOrClearAllActionMetadata() throws {
        let source = transcript(); var value = notebook(try resolve([reassigned], source), transcript: source)
        try value.validate()
        let decoded = try JSONDecoder().decode(MeetingNotebook.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded, value); XCTAssertEqual(decoded.actionCards.first?.sources.count, 2)
        value.edit(thoughts: "Personal note", summary: "", decisions: "", actions: value.actions, reviewed: false)
        XCTAssertNotNil(value.actionResolutions)
        value.edit(thoughts: value.thoughts, summary: "", decisions: "", actions: "My manual action", reviewed: true)
        XCTAssertNil(value.actionResolutions); XCTAssertTrue(value.evidence?.isEmpty == true); try value.validate()
    }
    func testOldNotebookWithoutResolutionMetadataStillDecodes() throws {
        let value = MeetingNotebook(meetingID: UUID())
        let decoded = try JSONDecoder().decode(MeetingNotebook.self, from: JSONEncoder().encode(value))
        XCTAssertNil(decoded.actionResolutions); try decoded.validate()
    }

    private func correctedCommitment(track: String, cluster: Int, name: String) -> MeetingTranscript {
        var value = MeetingTranscript(locale: "en-US")
        let speaker = "\(track)-\(cluster)"
        value.names[speaker] = name
        var line = MeetingUtterance(start: 12, end: 19, track: track, text: "We should discuss the launch checklist.")
        line.correction = "I will prepare the launch checklist by Friday."
        line.speaker = speaker; line.reviewed = true; value.utterances = [line]
        return value
    }
    private func reconciled(_ source: MeetingTranscript) throws -> [MeetingActionResolution] {
        try MeetingActionResolution.resolve(MeetingActionReconciler.proposals(source), transcript: source,
                                           allowedSources: Set(source.utterances.indices))
    }
    func testCorrectedMicrophonePlaceholdersRemainUnassignedThroughSavedCards() throws {
        for cluster in 0..<8 {
            let source = correctedCommitment(track: "mic", cluster: cluster, name: "mic speaker \(cluster)")
            let resolutions = try reconciled(source), item = try XCTUnwrap(resolutions.first)
            XCTAssertEqual(resolutions.count, 1); XCTAssertEqual(item.status, .active)
            XCTAssertEqual(item.task, "prepare the launch checklist"); XCTAssertNil(item.owner)
            XCTAssertEqual(item.deadline, "Friday")
            XCTAssertEqual(source.utterances[0].text, "We should discuss the launch checklist.")
            XCTAssertEqual(item.evidence[0].quote, source.utterances[0].correction)
            XCTAssertEqual(item.evidence[0].utteranceID, source.utterances[0].id)
            let saved = notebook(resolutions, transcript: source); try saved.validate()
            let reopened = try JSONDecoder().decode(MeetingNotebook.self, from: JSONEncoder().encode(saved))
            try reopened.validate(); XCTAssertEqual(reopened, saved)
            let card = try XCTUnwrap(reopened.actionCards.first)
            XCTAssertNil(card.owner); XCTAssertEqual(card.deadline, "Friday"); XCTAssertEqual(card.status, "active")
            XCTAssertTrue(reopened.actions.contains("Unassigned: prepare the launch checklist"))
            XCTAssertFalse(reopened.actions.contains("mic speaker"))
            XCTAssertEqual(card.sources.first?.quote, source.utterances[0].correction)
            XCTAssertEqual(try item.evidence[0].resolve(in: source, digest: reopened.sourceDigest).id, source.utterances[0].id)
        }
    }
    func testSystemPlaceholderTakeoverKeepsDeadlineAndBothSourcesWithoutInventingOwner() throws {
        for cluster in 0..<8 {
            var source = transcript(); source.utterances = Array(source.utterances.prefix(2))
            source.names.removeValue(forKey: "system-0")
            let speaker = "system-\(cluster)"; source.names[speaker] = "system speaker \(cluster)"
            source.utterances[1].speaker = speaker
            let resolutions = try reconciled(source), item = try XCTUnwrap(resolutions.first)
            XCTAssertEqual(resolutions.count, 1); XCTAssertEqual(item.status, .active)
            XCTAssertEqual(item.task, "prepare the launch checklist"); XCTAssertNil(item.owner)
            XCTAssertEqual(item.deadline, "Wednesday"); XCTAssertFalse(item.fact.contains("Monday"))
            XCTAssertEqual(item.evidence.map(\.utteranceID), source.utterances.map(\.id))
            let saved = notebook(resolutions, transcript: source); try saved.validate()
            let reopened = try JSONDecoder().decode(MeetingNotebook.self, from: JSONEncoder().encode(saved))
            try reopened.validate(); XCTAssertNil(reopened.actionCards.first?.owner)
            XCTAssertEqual(reopened.actionCards.first?.deadline, "Wednesday")
            XCTAssertEqual(reopened.actionCards.first?.sources.count, 2)
            for link in item.evidence { XCTAssertNoThrow(try link.resolve(in: source, digest: reopened.sourceDigest)) }
        }
    }
    func testExplicitRenameReplacesPlaceholderOnlyAfterRegenerationAndRetiresOldLinks() throws {
        let source = correctedCommitment(track: "system", cluster: 0, name: "system speaker 0")
        let before = try reconciled(source), oldItem = try XCTUnwrap(before.first)
        XCTAssertNil(oldItem.owner)
        let oldNotebook = notebook(before, transcript: source); try oldNotebook.validate()
        var renamed = source; renamed.names["system-0"] = "Alice"
        XCTAssertFalse(oldNotebook.isCurrent(for: renamed))
        for link in oldItem.evidence { XCTAssertThrowsError(try link.resolve(in: renamed, digest: oldNotebook.sourceDigest)) }
        let after = try reconciled(renamed), current = try XCTUnwrap(after.first)
        XCTAssertEqual(current.owner, "Alice"); XCTAssertEqual(current.task, oldItem.task)
        XCTAssertEqual(current.deadline, "Friday"); XCTAssertEqual(current.status, .active)
        XCTAssertEqual(current.evidence.map(\.utteranceID), oldItem.evidence.map(\.utteranceID))
        let saved = notebook(after, transcript: renamed); try saved.validate()
        XCTAssertTrue(saved.isCurrent(for: renamed)); XCTAssertEqual(saved.actionCards.first?.owner, "Alice")
        XCTAssertTrue(saved.actions.contains("Alice: prepare the launch checklist"))
        for link in current.evidence { XCTAssertNoThrow(try link.resolve(in: renamed, digest: saved.sourceDigest)) }
    }
    func testLegitimateMicAndSystemNamesRemainExplicitOwnersInCorrectedPipeline() throws {
        for name in ["Mic Jones", "System Lee", "Mic Speaker Jones"] {
            var source = correctedCommitment(track: "mic", cluster: 0, name: name)
            source.utterances[0].correction = "\(name) will prepare the launch checklist by Friday."
            let resolutions = try reconciled(source), item = try XCTUnwrap(resolutions.first)
            XCTAssertEqual(resolutions.count, 1); XCTAssertEqual(item.owner, name)
            XCTAssertEqual(item.task, "prepare the launch checklist"); XCTAssertEqual(item.deadline, "Friday")
            XCTAssertEqual(item.status, .active); XCTAssertEqual(item.evidence[0].quote, source.utterances[0].correction)
            let saved = notebook(resolutions, transcript: source); try saved.validate()
            let reopened = try JSONDecoder().decode(MeetingNotebook.self, from: JSONEncoder().encode(saved))
            try reopened.validate(); XCTAssertEqual(reopened.actionCards.first?.owner, name)
            XCTAssertEqual(reopened.actionCards.first?.deadline, "Friday")
            XCTAssertEqual(try item.evidence[0].resolve(in: source, digest: reopened.sourceDigest).id, source.utterances[0].id)
        }
    }

    func testDecodedHistoricalPlaceholderNotesSanitizePresentationWithoutChangingStoredEvidence() throws {
        for (track, cluster) in [("mic", 0), ("mic", 7), ("system", 0), ("system", 7)] {
            let alias = "\(track) speaker \(cluster)"
            let source = correctedCommitment(track: track, cluster: cluster, name: alias)
            let rawFact = "\(alias): prepare the launch checklist · Due Friday"
            let evidence = try MeetingNoteEvidence(section: .actions, fact: rawFact, source: source.utterances[0])
            // A valid historical structured payload, independently of the fixed
            // resolver: old saved fields must remain readable and byte-stable.
            let oldItem = MeetingActionResolution(id: evidence.id, task: "prepare the launch checklist",
                owner: alias, deadline: "Friday", status: .active, evidence: [evidence])
            let historical = notebook([oldItem], transcript: source); try historical.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let stored = try encoder.encode(historical)
            let reopened = try JSONDecoder().decode(MeetingNotebook.self, from: stored)
            try reopened.validate(); XCTAssertEqual(reopened, historical)
            let card = try XCTUnwrap(reopened.actionCards.first)
            XCTAssertNil(card.owner); XCTAssertEqual(card.task, "prepare the launch checklist")
            XCTAssertEqual(card.deadline, "Friday"); XCTAssertEqual(card.status, "active")
            XCTAssertEqual(card.sources.first?.id, evidence.id.uuidString)
            XCTAssertEqual(card.sources.first?.quote, source.utterances[0].correction)
            XCTAssertTrue(reopened.markdown(title: "Authored", includeThoughts: false).contains("Unassigned: prepare the launch checklist · Due Friday"))
            XCTAssertFalse(reopened.markdown(title: "Authored", includeThoughts: false).contains(alias))
            XCTAssertTrue(reopened.searchableText.contains("Unassigned: prepare the launch checklist"))
            XCTAssertFalse(reopened.searchableText.contains(alias))
            XCTAssertEqual(reopened.actions, historical.actions) // Raw editable/audit field retained.
            XCTAssertEqual(reopened.actionResolutions?.first?.owner, alias)
            XCTAssertEqual(reopened.actionResolutions?.first?.fact, rawFact)
            XCTAssertEqual(reopened.actionResolutions?.first?.evidence, [evidence])
            XCTAssertEqual(reopened.evidence, [evidence]); XCTAssertEqual(reopened.sourceDigest, historical.sourceDigest)
            XCTAssertEqual(try evidence.resolve(in: source, digest: reopened.sourceDigest).id, source.utterances[0].id)
            XCTAssertEqual(try encoder.encode(reopened), stored)
        }
    }
    func testManualAndRealNamedNotesRemainExactThroughPresentation() throws {
        var manual = MeetingNotebook(meetingID: UUID())
        manual.actions = "Ask mic speaker 0 about the recording."
        manual.thoughts = "Personal authored text"; manual.reviewed = true
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let manualBytes = try encoder.encode(manual)
        let reopenedManual = try JSONDecoder().decode(MeetingNotebook.self, from: manualBytes)
        XCTAssertTrue(reopenedManual.markdown(title: "Authored", includeThoughts: false).contains(manual.actions))
        XCTAssertTrue(reopenedManual.searchableText.contains(manual.actions))
        XCTAssertTrue(reopenedManual.actionCards.isEmpty); XCTAssertEqual(try encoder.encode(reopenedManual), manualBytes)
        for name in ["Mic Jones", "System Lee", "Mic Speaker Jones"] {
            let source = correctedCommitment(track: "mic", cluster: 0, name: name)
            let items = try reconciled(source), item = try XCTUnwrap(items.first)
            let value = notebook(items, transcript: source); try value.validate()
            let bytes = try encoder.encode(value), reopened = try JSONDecoder().decode(MeetingNotebook.self, from: bytes)
            XCTAssertEqual(reopened.actionCards.first?.owner, name)
            XCTAssertTrue(reopened.markdown(title: "Authored", includeThoughts: false).contains(value.actions))
            XCTAssertTrue(reopened.searchableText.contains(value.actions)); XCTAssertEqual(try encoder.encode(reopened), bytes)

        }
    }
    func testMalformedStructuredPresentationRefusesWholeListBeforeIndexingOrClockConversion() throws {
        let source = correctedCommitment(track: "mic", cluster: 0, name: "Mic Jones")
        let items = try reconciled(source), item = try XCTUnwrap(items.first)
        let value = notebook(items, transcript: source); try value.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value), reopened = try JSONDecoder().decode(MeetingNotebook.self, from: bytes)
        var malformed = reopened
        malformed.actionResolutions = [.init(id: item.id, task: item.task, owner: item.owner,
            deadline: item.deadline, status: item.status, evidence: [])]
        XCTAssertThrowsError(try malformed.validate())
        XCTAssertTrue(malformed.markdown(title: "Authored", includeThoughts: false).contains("Saved action items unavailable"))
        XCTAssertFalse(malformed.searchableText.contains(value.actions))
        // Decode an actual malformed non-finite clock rather than calling
        // Int on it or adding a production/test result-injection seam.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var resolutions = try XCTUnwrap(object["actionResolutions"] as? [[String: Any]])
        var evidence = try XCTUnwrap(resolutions[0]["evidence"] as? [[String: Any]])
        evidence[0]["start"] = "NaN"; resolutions[0]["evidence"] = evidence; object["actionResolutions"] = resolutions
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let badClock = try decoder.decode(MeetingNotebook.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try badClock.validate())
        XCTAssertTrue(badClock.searchableText.contains("Saved action items unavailable"))
        XCTAssertFalse(badClock.markdown(title: "Authored", includeThoughts: false).contains(value.actions))
    }
}
