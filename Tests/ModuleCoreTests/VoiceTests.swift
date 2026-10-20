import XCTest
@testable import ModuleCore
import NookPluginSDK

final class VoiceTests: XCTestCase {
    func testRecordedShortcutValidationAndLegacyMigration() {
        XCTAssertEqual(DictationShortcut.standard.displayName, "Fn")
        XCTAssertEqual(DictationShortcut.fromLegacy("⌃⌥Space")?.displayName, "⌃⌥Space")
        XCTAssertEqual(DictationShortcut.fromLegacy("⌃⇧V")?.displayName, "⌃⇧V")
        XCTAssertNil(DictationShortcut.fromLegacy("Off"))
        XCTAssertTrue(DictationShortcut(keyCode: 9, modifiers: 4096, keyLabel: "V").valid)
        XCTAssertTrue(DictationShortcut(keyCode: 53, modifiers: 4096 | 2048, keyLabel: "Esc").valid)
        XCTAssertTrue(DictationShortcut(keyCode: 49, modifiers: 4096 | 2048, keyLabel: "Space").valid)
    }
    func testDictationCleanupKeepsExplicitCorrectionAndQuestion() {
        XCTAssertEqual(VoiceCleanup.baseline("How are we doings, I mean how are YOU doing", tone: .clean), "How are you doing?")
        XCTAssertEqual(VoiceCleanup.baseline("How are we doing? I mean, how are you doing?", tone: .clean), "How are you doing?")
        XCTAssertEqual(VoiceCleanup.baseline("Um, I I need this today", tone: .clean), "I need this today.")
    }

    func testAmbiguousCorrectionAndLiteralModeAreConservative() {
        XCTAssertEqual(VoiceCleanup.baseline("Tell Mary, I mean Sarah, that I'll be late", tone: .clean), "Tell Mary, I mean Sarah, that I'll be late.")
        XCTAssertEqual(VoiceCleanup.baseline("  um I I need this today  ", tone: .literal), "um I I need this today")
    }
    func testRatherPreferencesNeverDeleteTheBeginningOfDictation() {
        for tone in [DictationTone.clean, .formal] {
            XCTAssertEqual(VoiceCleanup.baseline("I would rather you send the invoice tomorrow", tone: tone), "I would rather you send the invoice tomorrow.")
            XCTAssertEqual(VoiceCleanup.baseline("I would rather we wait until Friday", tone: tone), "I would rather we wait until Friday.")
            XCTAssertEqual(VoiceCleanup.baseline("Rather than cancel, we should reschedule", tone: tone), "Rather than cancel, we should reschedule.")
        }
        XCTAssertEqual(VoiceCleanup.baseline("Please send it today, scratch that please send it tomorrow", tone: .clean), "Please send it tomorrow.")
    }
    func testCancelledPreparationCannotOpenLater() {
        var s = VoiceSession(); let old = s.begin(); s.cancel()
        XCTAssertFalse(s.ready(old)); XCTAssertFalse(s.recording)
    }
    func testOldCallbacksCannotOverwriteNewRecording() throws {
        var s = VoiceSession(); let old = s.begin(); XCTAssertTrue(s.ready(old))
        try s.partial("old", token: old); s.cancel()
        let current = s.begin(); XCTAssertTrue(s.ready(current))
        try s.partial("new", token: current); try s.partial("late old", token: old)
        try s.finish("late final", token: old)
        XCTAssertEqual(s.transcript, "new"); XCTAssertEqual(s.phase, .listening)
    }
    func testFinalizationPreservesLastWordsAndEditableOriginal() throws {
        var s = VoiceSession(); let id = s.begin(); XCTAssertTrue(s.ready(id))
        try s.partial("First", token: id); XCTAssertTrue(s.finishing(id))
        try s.partial("stale partial", token: id)
        try s.finish("First and last words", token: id)
        try s.edit("Reviewed text"); XCTAssertEqual(s.raw, "First and last words")
        s.restore(); XCTAssertEqual(s.transcript, "First and last words"); XCTAssertEqual(s.phase, .review)
    }
    func testCancelKeepsPartialAndNewPreparationKeepsDraftUntilReady() throws {
        var s = VoiceSession(); let id = s.begin(); _ = s.ready(id)
        try s.partial("partial", token: id); s.cancel(); _ = s.begin(); s.cancel()
        XCTAssertEqual(s.transcript, "partial"); XCTAssertFalse(s.recording)
    }
    func testEmptySpeechAndUTF8Boundary() throws {
        XCTAssertThrowsError(try VoiceSession.validate(" \n"))
        try VoiceSession.validate(String(repeating: "é", count: 1024))
        XCTAssertThrowsError(try VoiceSession.validate(String(repeating: "é", count: 1025)))
        var s = VoiceSession(); try s.edit("keep me")
        XCTAssertThrowsError(try s.edit(String(repeating: "x", count: 2049)))
        XCTAssertEqual(s.transcript, "keep me")
    }
    func testVolatileReplacementAndFinalTail() {
        var a = AppleSpeechTranscriptAssembler()
        a.receive(text: "The red", isFinal: false); a.receive(text: "The read", isFinal: false)
        XCTAssertEqual(a.displayText, "The read")
        a.receive(text: "The red light", isFinal: true); a.receive(text: "is", isFinal: false)
        a.receive(text: "is on", isFinal: false); a.receive(text: "is on.", isFinal: true)
        XCTAssertEqual(a.finishedText, "The red light is on.")
        a.receive(text: "Last word", isFinal: false)
        XCTAssertEqual(a.finishedText, "The red light is on. Last word")
    }
    func testDictionaryOnlyWholeLiteralTerms() {
        XCTAssertEqual(VoiceDictionary.apply("neronook and neronooks use c++ and $test", terms: "NeroNook\nC++\n$TEST"), "NeroNook and neronooks use C++ and $TEST")
        XCTAssertEqual(VoiceDictionary.apply("turn off the lamp", terms: "Turn on the lamp"), "turn off the lamp")
    }
    func testAssistantRequiresReadOnlyTextContract() {
        let ask = PluginRegisteredAction("ask", title: "Ask", input: .init([.init("prompt", .string), .init("context", .string, required: false)]), output: .init([.init("reply", .string)]))
        XCTAssertTrue(VoiceContract.accepts(ask))
        XCTAssertFalse(VoiceContract.accepts(.init("change", title: "Change", input: ask.input, output: ask.output, effect: .localChange)))
        XCTAssertFalse(VoiceContract.accepts(.init("decide", title: "Decide", input: ask.input, output: .init([.init("reply", .string), .init("decision", .boolean)]))))
        XCTAssertFalse(VoiceContract.accepts(.init("extra", title: "Extra", input: .init([.init("prompt", .string), .init("target", .string)]), output: ask.output)))
    }
    func testSubmitRejectsUnknownDestinationBlankTextAndUnknownFields() throws {
        var values: [String: PluginValue] = ["text": .string("Hello"), "destination": .string("Copy"), "read_reply": .boolean(false)]
        XCTAssertFalse(try VoiceContract.validate(values).1)
        values["destination"] = .string("Ask"); XCTAssertTrue(try VoiceContract.validate(values).1)
        values["destination"] = .string("Run"); XCTAssertThrowsError(try VoiceContract.validate(values))
        values["destination"] = .string("Copy"); values["text"] = .string(""); XCTAssertThrowsError(try VoiceContract.validate(values))
        values["text"] = .string("Hello"); values["secret"] = .string("no"); XCTAssertThrowsError(try VoiceContract.validate(values))
    }
}
