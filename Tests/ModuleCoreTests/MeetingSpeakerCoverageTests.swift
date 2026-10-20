import XCTest
@testable import ModuleCore

final class MeetingSpeakerCoverageTests: XCTestCase {
    /// Authored span-level oracle: these labels describe unique time coverage,
    /// not a learned-model benchmark or DER on real audio.
    func testAuthoredSpeakerSeparatedCoverageScore() throws {
        struct Fixture { let name: String; let spans: [MeetingSpeakerSpan]; let expected: String? }
        let cases: [Fixture] = [
            .init(name: "returning speaker", spans: [.init(start: 0, end: 10, speaker: 0)], expected: "system-0"),
            .init(name: "second speaker", spans: [.init(start: 0, end: 8, speaker: 1)], expected: "system-1"),
            .init(name: "duplicate short detection", spans: [.init(start: 0, end: 3, speaker: 0), .init(start: 0, end: 3, speaker: 0)], expected: nil),
            .init(name: "partial overlap same identity", spans: [.init(start: 0, end: 3, speaker: 1), .init(start: 2, end: 5, speaker: 1)], expected: nil),
            .init(name: "overlap people", spans: [.init(start: 0, end: 10, speaker: 0), .init(start: 4, end: 8, speaker: 1)], expected: nil),
            .init(name: "silence", spans: [], expected: nil),
            .init(name: "adjacent returning fragments", spans: [.init(start: 0, end: 3, speaker: 0), .init(start: 3, end: 7, speaker: 0)], expected: "system-0"),
            .init(name: "duplicate long span", spans: [.init(start: 0, end: 8, speaker: 1), .init(start: 1, end: 7, speaker: 1)], expected: "system-1")
        ]
        var oldCorrect = 0, currentCorrect = 0, oldFalseAssignments = 0, currentFalseAssignments = 0
        for fixture in cases {
            // Retained pre-change baseline: sum individual span durations.
            var oldCoverage: [Int: Double] = [:]
            for span in fixture.spans { oldCoverage[span.speaker, default: 0] += span.end - span.start }
            let order = oldCoverage.sorted { $0.value > $1.value }
            let old = order.first.flatMap { $0.value / 10 >= 0.55 && (order.dropFirst().first?.value ?? 0) / 10 < 0.2 ? "system-\($0.key)" : nil }
            var transcript = MeetingTranscript(locale: "en-US")
            transcript.utterances = [.init(start: 0, end: 10, track: "system", text: fixture.name)]
            try transcript.assign(fixture.spans, track: "system")
            let actual = transcript.utterances[0].speaker
            if old == fixture.expected { oldCorrect += 1 }; if actual == fixture.expected { currentCorrect += 1 }
            if fixture.expected == nil && old != nil { oldFalseAssignments += 1 }
            if fixture.expected == nil && actual != nil { currentFalseAssignments += 1 }
            XCTAssertEqual(actual, fixture.expected, fixture.name)
        }
        XCTAssertEqual(oldCorrect, 6); XCTAssertEqual(currentCorrect, 8)
        XCTAssertEqual(oldFalseAssignments, 2); XCTAssertEqual(currentFalseAssignments, 0)
        print("AUTHORED_COVERAGE_SCORE fixtures=8 baseline_correct=\(oldCorrect) current_correct=\(currentCorrect) baseline_false_assignment=\(oldFalseAssignments) current_false_assignment=\(currentFalseAssignments)")
    }
    func testWordBoundarySplittingRetainsUncertainWordAndTrackIdentity() throws {
        var transcript = MeetingTranscript(locale: "en-US")
        var line = MeetingUtterance(start: 0, end: 3, track: "mic", text: "One unknown two")
        line.words = [.init(text: "One", start: 0, end: 1), .init(text: " unknown", start: 1, end: 2), .init(text: " two", start: 2, end: 3)]
        transcript.utterances = [line]
        try transcript.assign([.init(start: 0, end: 1, speaker: 0), .init(start: 1, end: 1.3, speaker: 0), .init(start: 1, end: 1.3, speaker: 0), .init(start: 2, end: 3, speaker: 1)], track: "mic")
        XCTAssertEqual(transcript.utterances.map(\.speaker), ["mic-0", nil, "mic-1"])
        XCTAssertEqual(transcript.utterances.map(\.text), ["One", "unknown", "two"])
        XCTAssertEqual(transcript.utterances.flatMap { $0.words ?? [] }.map(\.text).joined(), line.text)
        var reviewed = line; reviewed.reviewed = true; reviewed.speaker = "mic-3"
        transcript.utterances = [reviewed]; try transcript.assign([], track: "mic")
        XCTAssertEqual(transcript.utterances[0], reviewed)
    }
}
