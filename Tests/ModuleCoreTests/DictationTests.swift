import XCTest
@testable import ModuleCore

final class DictationTests: XCTestCase {
    func testInsertAtCaretAndUndoRange() throws {
        let edit = try XCTUnwrap(DictationEdit(value: "Hello world", selection: NSRange(location: 6, length: 0), insertion: "lovely "))
        XCTAssertEqual(edit.after, "Hello lovely world")
        XCTAssertEqual(edit.replacedText, "")
        XCTAssertEqual(edit.insertedRange, NSRange(location: 6, length: 7))
        XCTAssertTrue(edit.canUndo(value: edit.after, selection: NSRange(location: 13, length: 0)))
    }
    func testSelectionReplacementKeepsExactOriginalForUndo() throws {
        let edit = try XCTUnwrap(DictationEdit(value: "A red boat", selection: NSRange(location: 2, length: 3), insertion: "blue"))
        XCTAssertEqual(edit.after, "A blue boat"); XCTAssertEqual(edit.replacedText, "red")
        XCTAssertEqual((edit.after as NSString).replacingCharacters(in: edit.insertedRange, with: edit.replacedText), edit.before)
    }
    func testUTF16BoundaryAndCombinedCharacters() throws {
        let text = "Hi 👋🏽!"
        let edit = try XCTUnwrap(DictationEdit(value: text, selection: NSRange(location: 7, length: 0), insertion: "🌍"))
        XCTAssertEqual(edit.after, "Hi 👋🏽🌍!"); XCTAssertEqual(edit.caret.location, 9)
        XCTAssertNil(DictationEdit(value: "😀", selection: NSRange(location: 1, length: 0), insertion: "x"))
    }
    func testStaleValueOrSelectionCannotBeOverwrittenOrUndone() throws {
        let edit = try XCTUnwrap(DictationEdit(value: "draft", selection: NSRange(location: 5, length: 0), insertion: " text"))
        XCTAssertTrue(edit.matches(value: "draft", selection: edit.selection))
        XCTAssertFalse(edit.matches(value: "edited", selection: edit.selection))
        XCTAssertFalse(edit.matches(value: "draft", selection: NSRange(location: 0, length: 0)))
        XCTAssertFalse(edit.canUndo(value: "draft text!", selection: edit.caret))
        XCTAssertFalse(edit.canUndo(value: edit.after, selection: NSRange(location: 0, length: 0)))
    }
    func testRejectInvalidAndOversizedTargets() {
        XCTAssertNil(DictationEdit(value: "a", selection: NSRange(location: NSNotFound, length: 0), insertion: "b"))
        XCTAssertNil(DictationEdit(value: "a", selection: NSRange(location: 0, length: 2), insertion: "b"))
        XCTAssertNil(DictationEdit(value: String(repeating: "x", count: 131_073), selection: NSRange(location: 0, length: 0), insertion: "b"))
    }
    func testHoldDoesNotStopAnUnrelatedRecording() {
        var keys = DictationShortcutState()
        XCTAssertEqual(keys.press(style: .hold, busy: true), .none)
        XCTAssertEqual(keys.release(style: .hold), .none)
        XCTAssertEqual(keys.press(style: .hold, busy: false), .start)
        XCTAssertEqual(keys.release(style: .hold), .stop)
        XCTAssertEqual(keys.release(style: .hold), .none)
    }
    func testTogglePressStopsPreparationAndIgnoresRelease() {
        var keys = DictationShortcutState()
        XCTAssertEqual(keys.press(style: .toggle, busy: false), .start)
        XCTAssertEqual(keys.release(style: .toggle), .none)
        XCTAssertEqual(keys.press(style: .toggle, busy: true), .stop)
        XCTAssertEqual(keys.release(style: .toggle), .none)
        XCTAssertEqual(keys.press(style: .toggle, busy: true), .none)
    }
    func testFinishOrCancellationReleasesShortcutOwnership() {
        var keys = DictationShortcutState()
        XCTAssertEqual(keys.press(style: .toggle, busy: false), .start)
        keys.reset()
        XCTAssertEqual(keys.press(style: .toggle, busy: false), .start)
        keys.reset()
        XCTAssertEqual(keys.release(style: .hold), .none)
    }
}
