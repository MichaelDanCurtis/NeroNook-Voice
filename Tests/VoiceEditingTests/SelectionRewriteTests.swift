import XCTest
import ModuleCore
@testable import VoiceEditing

@MainActor final class SelectionRewriteTests: XCTestCase {
    func testUTF16MultilineReplacementAndExactUndo() async throws {
        let editor = try Editor(value: "Before 🧊\nmake this clear after", range: NSRange(location: 10, length: 15))
        let model = SelectionRewrite(editor: editor) { _, _ in "Make this clearer" }
        try model.begin(); let selected = try XCTUnwrap(model.capture?.text)
        XCTAssertEqual(selected, "make this clear")
        model.result = "Make this clearer"; model.apply(); await settle(model)
        XCTAssertEqual(model.phase, .applied); XCTAssertEqual(editor.value, "Before 🧊\nMake this clearer after")
        model.undo(); await settle(model)
        XCTAssertEqual(model.phase, .undone); XCTAssertEqual(editor.value, "Before 🧊\nmake this clear after")
        XCTAssertEqual(editor.range, NSRange(location: 10, length: 15)); XCTAssertEqual(editor.writes, 2)
        model.close()
    }
    func testExplicitSelectionRequiredAndSurrogatesNeverSplit() throws {
        for range in [NSRange(location: 0, length: 0), NSRange(location: 1, length: 1), NSRange(location: 0, length: 1), NSRange(location: 99, length: 1)] {
            XCTAssertThrowsError(try SelectionCapture(app: "Editor", value: "🧊 hello", range: range))
        }
        XCTAssertThrowsError(try SelectionCapture(app: "Editor", value: String(repeating: "x", count: 6001), range: NSRange(location: 0, length: 6001)))
        XCTAssertThrowsError(try SelectionCapture(app: "Editor", value: " \n", range: NSRange(location: 0, length: 2)))
    }
    func testShortcutConflictUsesPhysicalKeysNotDisplayLabel() {
        let first = DictationShortcut(keyCode: 15, modifiers: 6144, keyLabel: "R")
        XCTAssertTrue(first.sameBinding(as: .init(keyCode: 15, modifiers: 6144, keyLabel: "Different layout")))
        XCTAssertFalse(first.sameBinding(as: .init(keyCode: 15, modifiers: 6656, keyLabel: "R")))
        XCTAssertFalse(first.sameBinding(as: .standard))
        XCTAssertTrue(DictationShortcut.standard.sameBinding(as: .init(modifiers: DictationShortcut.fn)))
    }
    func testGeneratorReceivesOnlySelectionAndChosenOperation() async throws {
        let editor = try Editor(value: "PRIVATE PREFIX highlight PRIVATE SUFFIX", range: NSRange(location: 15, length: 9))
        var observed = ""; var operation: SelectionTransformation?
        let model = SelectionRewrite(editor: editor) { text, op in observed = text; operation = op; return "highlighted" }
        try model.begin(); model.operation = .clarify; model.transform(); await settle(model)
        XCTAssertEqual(observed, "highlight"); XCTAssertEqual(operation, .clarify)
        XCTAssertEqual(editor.writes, 0); XCTAssertTrue(model.canApply)
        model.close()
    }
    func testSourceAndCaretChangesRefuseReplacement() async throws {
        for changed in ["value", "selection", "identity"] {
            let editor = try Editor(); let model = SelectionRewrite(editor: editor) { _, _ in "new" }
            try model.begin(); model.result = "new"
            if changed == "value" { editor.value = "user typed" }
            if changed == "selection" { editor.range = NSRange(location: 0, length: 0) }
            if changed == "identity" { editor.currentID = UUID() }
            let before = editor.value; model.apply(); await settle(model)
            XCTAssertEqual(model.phase, .reviewing); XCTAssertEqual(editor.value, before); XCTAssertEqual(editor.writes, 0)
            XCTAssertTrue(model.canApply); XCTAssertFalse(model.canUndo); model.close()
        }
    }
    func testLaterEditingInvalidatesUndo() async throws {
        let editor = try Editor(); let model = SelectionRewrite(editor: editor) { _, _ in "new" }
        try model.begin(); model.result = "new"; model.apply(); await settle(model)
        editor.value = "user's later change"; model.undo(); await settle(model)
        XCTAssertEqual(model.phase, .blocked); XCTAssertEqual(editor.value, "user's later change"); XCTAssertEqual(editor.writes, 1)
        model.close()
    }
    func testMovedCaretInvalidatesUndo() async throws {
        let editor = try Editor(); let model = SelectionRewrite(editor: editor) { _, _ in "new" }
        try model.begin(); model.result = "new"; model.apply(); await settle(model)
        editor.range = NSRange(location: 0, length: 0); model.undo(); await settle(model)
        XCTAssertEqual(model.phase, .blocked); XCTAssertEqual(editor.value, "new"); XCTAssertEqual(editor.writes, 1); model.close()
    }
    func testCancelWritesNothingAndClearsSensitiveState() throws {
        let editor = try Editor(); let model = SelectionRewrite(editor: editor) { _, _ in "new" }
        try model.begin(); model.result = "private replacement"; model.close()
        XCTAssertEqual(editor.writes, 0); XCTAssertNil(model.capture); XCTAssertEqual(model.result, ""); XCTAssertEqual(editor.forgets, 1)
        model.apply(); model.undo(); XCTAssertEqual(editor.writes, 0)
    }
    func testOnlyExplicitDismissalReturnsFocus() throws {
        let editor = try Editor(); let model = SelectionRewrite(editor: editor) { _, _ in "new" }
        try model.begin(); model.close(); XCTAssertEqual(editor.focusReturns, 0)
        try model.begin(); model.close(returnToEditor: true); XCTAssertEqual(editor.focusReturns, 1); XCTAssertEqual(editor.writes, 0)
    }
    func testPrewriteFocusFailureCanBeRetriedOnlyByAnotherExplicitApply() async throws {
        let editor = try Editor(); editor.prewriteFailure = true
        let model = SelectionRewrite(editor: editor) { _, _ in "new" }
        try model.begin(); model.result = "new"; model.apply(); await settle(model)
        XCTAssertEqual(model.phase, .reviewing); XCTAssertEqual(editor.writes, 0)
        editor.prewriteFailure = false
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(editor.writes, 0)
        model.apply(); await settle(model)
        XCTAssertEqual(model.phase, .applied); XCTAssertEqual(editor.writes, 1); model.close()
    }
    func testUnavailableModelKeepsManualPreview() async throws {
        let editor = try Editor(); let model = SelectionRewrite(editor: editor) { _, _ in throw SelectionProblem.unavailable }
        try model.begin(); model.transform(); await settle(model)
        XCTAssertEqual(model.phase, .reviewing); XCTAssertEqual(model.result, "original"); XCTAssertTrue(model.status.contains("cloud"))
        model.result = "manual"; model.apply(); await settle(model); XCTAssertEqual(editor.value, "manual"); model.close()
    }
    func testLateModelResultCannotResurrectClosedOrNewSession() async throws {
        let editor = try Editor(); var resume: CheckedContinuation<String, Error>?
        let model = SelectionRewrite(editor: editor) { _, _ in try await withCheckedThrowingContinuation { resume = $0 } }
        try model.begin(); model.transform()
        for _ in 0..<30 where resume == nil { await Task.yield() }
        model.close(); try model.begin(); resume?.resume(returning: "late private result")
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.result, "original"); XCTAssertEqual(model.phase, .reviewing); XCTAssertEqual(editor.writes, 0); model.close()
    }
    func testExpiryStillClosesAfterGenerationChangesEpoch() async throws {
        let editor = try Editor(); let model = SelectionRewrite(editor: editor, lifetime: .milliseconds(25)) { _, _ in "new" }
        try model.begin(); model.transform(); await settle(model)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(model.phase, .closed); XCTAssertNil(model.capture); XCTAssertEqual(model.result, ""); XCTAssertEqual(editor.writes, 0)
    }
    func testCancelWhileReturningFocusNeverWrites() async throws {
        let editor = try Editor(); editor.delay = true
        let model = SelectionRewrite(editor: editor) { _, _ in "new" }
        try model.begin(); model.result = "new"; model.apply()
        for _ in 0..<30 where !editor.entered { await Task.yield() }
        model.close(); try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(editor.writes, 0); XCTAssertEqual(editor.value, "original"); XCTAssertEqual(model.phase, .closed)
    }
    func testUnverifiedReadbackNeverOffersRetryOrUndo() async throws {
        let editor = try Editor(); editor.unverified = true
        let model = SelectionRewrite(editor: editor) { _, _ in "new" }
        try model.begin(); model.result = "new"; model.apply(); await settle(model)
        XCTAssertEqual(editor.value, "new"); XCTAssertEqual(model.phase, .blocked)
        XCTAssertFalse(model.canApply); XCTAssertFalse(model.canUndo); XCTAssertEqual(model.capture?.text, "original"); model.close()
    }
    func testEmptyAndOverlongResultsNeverApply() async throws {
        for result in ["  ", String(repeating: "x", count: 12_001)] {
            let editor = try Editor(); let model = SelectionRewrite(editor: editor) { _, _ in result }
            try model.begin(); model.transform(); await settle(model)
            XCTAssertEqual(model.result, "original"); model.result = result; model.apply()
            XCTAssertEqual(editor.writes, 0); model.close()
        }
    }
    private func settle(_ model: SelectionRewrite) async { for _ in 0..<200 { if !model.working { return }; await Task.yield() }; XCTFail("State did not settle") }
}

@MainActor private final class Editor: SelectionEditor {
    var value: String; var range: NSRange
    var currentID = UUID(); var writes = 0; var forgets = 0; var delay = false; var entered = false; var unverified = false; var focusReturns = 0; var prewriteFailure = false
    init(value: String = "original", range: NSRange = NSRange(location: 0, length: 8)) throws { self.value = value; self.range = range }
    func capture() throws -> SelectionCapture { try SelectionCapture(id: currentID, app: "Authored editor", value: value, range: range) }
    func replace(_ capture: SelectionCapture, with text: String) async throws -> DictationEdit {
        entered = true
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        if prewriteFailure { throw SelectionProblem.activeAppChanged }
        guard capture.id == currentID, capture.value == value, capture.range == range,
              let edit = DictationEdit(value: value, selection: range, insertion: text) else { throw SelectionProblem.changed }
        value = edit.after; range = edit.caret; writes += 1
        if unverified { throw SelectionProblem.unverified }; return edit
    }
    func undo(_ capture: SelectionCapture, edit: DictationEdit) async throws {
        guard capture.id == currentID, edit.canUndo(value: value, selection: range) else { throw SelectionProblem.changed }
        value = edit.before; range = edit.selection; writes += 1
    }
    func forget() { forgets += 1 }
    func restoreFocus() { focusReturns += 1 }
}
