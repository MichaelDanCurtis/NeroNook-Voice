import Foundation
import XCTest
@testable import ModuleCore

final class DictationPersonalizationTests: XCTestCase {
    func store() throws -> DictationPersonalizationStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return try .init(root: root)
    }
    func testExactAppOverridesFallbackAndFrozenCopy() throws {
        var config = DictationPersonalization()
        config.apps = [.init(appID: "com.apple.TextEdit", name: "TextEdit", tone: .formal)]
        try config.validate()
        let frozenTone = config.tone(for: "com.apple.TextEdit", fallback: .clean)
        config.apps[0].tone = .literal
        XCTAssertEqual(frozenTone, .formal); XCTAssertEqual(config.tone(for: "com.apple.TextEdit", fallback: .clean), .literal)
        XCTAssertEqual(config.tone(for: "org.other.Editor", fallback: .clean), .clean)
        XCTAssertEqual(config.tone(for: nil, fallback: .formal), .formal)
    }
    func testExplicitSnippetOnlyIsExactAndOrdinaryMentionsDoNotExpand() throws {
        let snippet = DictationSnippet(name: "Email", text: "first.last+hello@example.test")
        let ordinary = try DictationSnippetPlan(raw: "Discuss the email tomorrow.", snippets: [snippet])
        XCTAssertTrue(ordinary.snippets.isEmpty)
        let plan = try DictationSnippetPlan(raw: "Insert, snippet, EMAIL!", snippets: [snippet])
        XCTAssertEqual(plan.exactText, snippet.text)
        XCTAssertEqual(try plan.render("Model changed it", fallback: ""), snippet.text)
        let short = DictationSnippet(name: "Address", text: "Short"), long = DictationSnippet(name: "Address work", text: "$42\\path\nSecond line\ninsert snippet address")
        let longer = try DictationSnippetPlan(raw: "insert snippet address work.", snippets: [short, long])
        XCTAssertEqual(longer.snippets.map(\.id), [long.id]); XCTAssertEqual(try longer.render("", fallback: ""), long.text)
    }
    func testEmbeddedMarkersArePreservedOnceAndFallbackRejectsReorderedOrLostAIOutput() throws {
        let a = DictationSnippet(name: "One", text: "Exact $1"), b = DictationSnippet(name: "Two", text: "Exact \\2")
        let plan = try DictationSnippetPlan(raw: "Please send insert snippet one and insert snippet two tomorrow.", snippets: [a,b])
        XCTAssertNil(plan.exactText)
        let baseline = VoiceCleanup.baseline(plan.prepared, tone: .clean)
        XCTAssertEqual(try plan.render("I deleted the placeholders.", fallback: baseline), "Please send Exact $1 and Exact \\2 tomorrow.")
        XCTAssertEqual(try plan.render("NRVOICE_SNIPPET_B NRVOICE_SNIPPET_A", fallback: baseline), try plan.render(baseline, fallback: baseline))
        XCTAssertEqual(try plan.render(baseline + " NRVOICE_SNIPPET_A", fallback: baseline), try plan.render(baseline, fallback: baseline))
        XCTAssertThrowsError(try plan.render("Missing", fallback: "Missing"))
        XCTAssertEqual(try plan.render(baseline + " NRVOICE_SNIPPET_", fallback: baseline), try plan.render(baseline, fallback: baseline))
        XCTAssertEqual(try plan.render(baseline.replacingOccurrences(of: "NRVOICE_SNIPPET_A", with: "NRVOICE_SNIPPET_AA"), fallback: baseline), try plan.render(baseline, fallback: baseline))
        let plain = try DictationSnippetPlan(raw: "Send the draft.", snippets: [])
        XCTAssertEqual(try plain.render("Send the draft. NRVOICE_SNIPPET_", fallback: "Send the draft."), "Send the draft.")
        let huge = DictationSnippet(name: "Big", text: String(repeating: "x", count: 2048))
        let overflow = try DictationSnippetPlan(raw: "Please insert snippet big now.", snippets: [huge])
        XCTAssertThrowsError(try overflow.render(overflow.prepared, fallback: overflow.prepared))
    }
    func testUnicodeNamesAndRepeatedExpansionAreBoundedAndNeverRecursive() throws {
        let snippet = DictationSnippet(name: "中文 地址", text: "北京\ninsert snippet 中文 地址")
        let plan = try DictationSnippetPlan(raw: "insert snippet 中文 地址!", snippets: [snippet]); XCTAssertEqual(plan.exactText, snippet.text)
        let many = try DictationSnippetPlan(raw: Array(repeating: "insert snippet 中文 地址", count: 8).joined(separator: ", "), snippets: [snippet])
        XCTAssertEqual(many.snippets.count, 8)
        XCTAssertThrowsError(try DictationSnippetPlan(raw: Array(repeating: "insert snippet 中文 地址", count: 9).joined(separator: ", "), snippets: [snippet]))
        XCTAssertThrowsError(try DictationSnippetPlan(raw: "NRVOICE_SNIPPET_A", snippets: []))
    }
    func testConfigurationLimitsCanonicalDuplicateNamesAndRoundTrip() throws {
        let store = try store(); var config = DictationPersonalization()
        XCTAssertFalse(try store.configuration().historyEnabled); XCTAssertEqual(try store.configuration().retentionDays, 7)
        config.apps = [.init(appID: "com.apple.TextEdit", name: "TextEdit", tone: .formal)]
        config.snippets = [.init(name: "Shipping address", text: "First line\nSecond line")]; try store.save(config)
        XCTAssertEqual(try store.configuration(), config)
        config.snippets.append(.init(name: "SHIPPING-address", text: "Duplicate")); XCTAssertThrowsError(try store.save(config)); XCTAssertEqual(try store.configuration().snippets.count, 1)
        config.snippets = [.init(name: "A", text: String(repeating: "名", count: 700))]; XCTAssertThrowsError(try config.validate())
        config.snippets = []; config.apps[0].appID = "../../elsewhere"; XCTAssertThrowsError(try config.validate())
    }
    func testHistoryOptOutPruningCountAndTextOnlyRoundTrip() throws {
        let store = try store(), now = Date(); var history = DictationHistory()
        let entry = DictationHistoryEntry(raw: "um hello", text: "Hello.", appID: "com.apple.TextEdit", appName: "TextEdit", tone: .clean, recognizer: "nemotron", created: now)
        XCTAssertFalse(try history.append(entry, enabled: false, days: 7, now: now)); XCTAssertTrue(history.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("history-v1.json").path))
        for n in 0..<205 { var value = entry; value.id = UUID(); value.created = now.addingTimeInterval(-Double(n)); try history.append(value, enabled: true, days: 7, now: now) }
        XCTAssertEqual(history.entries.count, 200)
        history.entries[0].created = now.addingTimeInterval(-8*86400); history.entries[1].created = now.addingTimeInterval(600)
        history.prune(days: 7, now: now); XCTAssertEqual(history.entries.count, 198)
        try store.save(history); XCTAssertEqual(try store.history(), history)
        let json = try String(contentsOf: store.root.appendingPathComponent("history-v1.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("audio")); XCTAssertFalse(json.contains("window"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.root.appendingPathComponent("history-v1.json").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.clearHistory(); XCTAssertTrue(try store.history().entries.isEmpty); XCTAssertEqual(try store.configuration(), .init())
        // Explicit native-UI QA only. Ordinary test runs never touch app data.
        if let path = ProcessInfo.processInfo.environment["NERO_DICTATION_UI_FIXTURE_ROOT"], let receipt = ProcessInfo.processInfo.environment["NERO_DICTATION_UI_RECEIPT"] {
            let appStore = try DictationPersonalizationStore(root: URL(fileURLWithPath: path)), config = try appStore.configuration()
            guard config.historyEnabled, try appStore.history().entries.isEmpty,
                  let snippet = config.snippets.first(where: { $0.name == "QA address" }), snippet.text == "Nero test line one\nUnit 42 · $1234" else { throw VoiceProblem.message("Native QA consent/fixture does not match; existing history kept") }
            let raw = "Insert snippet QA address.", plan = try DictationSnippetPlan(raw: raw, snippets: config.snippets)
            let text = try plan.render(plan.prepared, fallback: plan.prepared)
            var sample = DictationHistory(); let row = DictationHistoryEntry(raw: raw, text: text, appID: "com.apple.TextEdit", appName: "TextEdit", tone: config.tone(for: "com.apple.TextEdit", fallback: .clean), recognizer: "nemotron")
            try sample.append(row, enabled: config.historyEnabled, days: config.retentionDays); try appStore.save(sample)
            try JSONEncoder().encode(row).write(to: URL(fileURLWithPath: receipt), options: .atomic)
        }
    }
    func testUnsafeAndCorruptHistoryCannotOverwriteAnotherFile() throws {
        let store = try store(), outside = store.root.appendingPathComponent("private.txt"), history = store.root.appendingPathComponent("history-v1.json")
        try Data("Keep".utf8).write(to: outside); try FileManager.default.createSymbolicLink(at: history, withDestinationURL: outside)
        XCTAssertThrowsError(try store.history()); XCTAssertThrowsError(try store.save(DictationHistory())); XCTAssertThrowsError(try store.clearHistory())
        XCTAssertEqual(try Data(contentsOf: outside), Data("Keep".utf8))
        try FileManager.default.removeItem(at: history); let corrupt = Data("broken".utf8); try corrupt.write(to: history)
        XCTAssertThrowsError(try store.history()); XCTAssertEqual(try Data(contentsOf: history), corrupt)
    }
    func testHistoryDraftRestoreHasItsOwnOriginalAndRejectsOldCallbacks() throws {
        var session = VoiceSession(); let previous = session.begin(); XCTAssertTrue(session.ready(previous)); try session.partial("Old speech", token: previous)
        try session.loadDraft(raw: "raw words", text: "Clean words.")
        XCTAssertNotEqual(session.token, previous); XCTAssertEqual(session.phase, .review)
        try session.partial("Late callback", token: previous); XCTAssertEqual(session.transcript, "Clean words.")
        session.restore(); XCTAssertEqual(session.transcript, "raw words")
    }
}
