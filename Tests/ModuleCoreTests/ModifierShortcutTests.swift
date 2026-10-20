import XCTest
@testable import ModuleCore

final class ModifierShortcutTests: XCTestCase {
    func testOldBindingsDecodeAndFnIsOnlyTheNewDefault() throws {
        let old = Data(#"{"keyCode":9,"modifiers":6144,"keyLabel":"V"}"#.utf8)
        let saved = try JSONDecoder().decode(DictationShortcut.self, from: old)
        XCTAssertEqual(saved, .legacyStandard); XCTAssertTrue(saved.valid)
        XCTAssertEqual(DictationShortcut.fromLegacy("⌃⌥V"), saved)
        XCTAssertEqual(DictationShortcut.standard.displayName, "Fn")
        XCTAssertEqual(DictationShortcut.optionCommand.displayName, "⌥⌘")
        XCTAssertNil(DictationShortcut.fromLegacy("Off"))
        for binding in [saved, .standard, .optionCommand, .init(modifiers: 4096), .init(modifiers: DictationShortcut.fn | 256), .init(keyCode:122, modifiers:0, keyLabel:"F1")] {
            XCTAssertTrue(binding.valid); XCTAssertEqual(try JSONDecoder().decode(DictationShortcut.self, from: JSONEncoder().encode(binding)), binding)
        }
        XCTAssertFalse(DictationShortcut(modifiers: 0).valid)
        XCTAssertFalse(DictationShortcut(modifiers: 1).valid)
        XCTAssertFalse(DictationShortcut(keyCode:0, modifiers:0, keyLabel:"A").valid)
        XCTAssertFalse(DictationShortcut(keyCode:63, modifiers:256, keyLabel:"Fn").valid)
    }
    func testModifierHoldFiresOnceAndStopsOnFirstRelease() {
        var state = ModifierHoldState(); let fn = DictationShortcut.fn
        XCTAssertEqual(state.flags(fn, target: fn), .arm)
        XCTAssertEqual(state.armCompleted(), .press)
        XCTAssertEqual(state.flags(fn, target: fn), .none)
        XCTAssertEqual(state.armCompleted(), .none)
        XCTAssertEqual(state.flags(0, target: fn), .release)
        XCTAssertEqual(state.flags(0, target: fn), .none)
        XCTAssertEqual(state.flags(fn, target: fn), .arm)
    }
    func testShortTapNeverRecordsAndStaleArmCannotStart() {
        var state = ModifierHoldState(); let fn = DictationShortcut.fn
        XCTAssertEqual(state.flags(fn, target: fn), .arm)
        XCTAssertEqual(state.flags(0, target: fn), .none)
        XCTAssertEqual(state.armCompleted(), .none)
        _ = state.flags(fn, target: fn); state.reset()
        XCTAssertEqual(state.armCompleted(), .none)
    }
    func testFnArrowAndOrdinaryShortcutNeverStartDictation() {
        var state = ModifierHoldState(); let fn = DictationShortcut.fn
        _ = state.flags(fn, target: fn)
        XCTAssertEqual(state.key(123, down:true), .none)
        XCTAssertEqual(state.armCompleted(), .none)
        _ = state.key(123, down:false)
        XCTAssertEqual(state.flags(fn, target:fn), .none)
        _ = state.flags(0,target:fn)
        XCTAssertEqual(state.flags(fn,target:fn), .arm)
    }
    func testTypingOrExtraModifierCancelsActiveHoldWithoutReleasePaste() {
        var state = ModifierHoldState(); let fn = DictationShortcut.fn
        _ = state.flags(fn,target:fn); _ = state.armCompleted()
        XCTAssertEqual(state.key(0,down:true), .cancel)
        XCTAssertEqual(state.flags(0,target:fn), .none)
        _ = state.key(0,down:false); _ = state.flags(fn,target:fn); _ = state.armCompleted()
        XCTAssertEqual(state.flags(fn | 256,target:fn), .cancel)
        XCTAssertEqual(state.flags(fn,target:fn), .none)
        XCTAssertEqual(state.armCompleted(), .none)
    }
    func testChordCannotRearmUntilAllModifiersRelease() {
        var state = ModifierHoldState(); let combo:UInt32 = 256 | 2048
        XCTAssertEqual(state.flags(256,target:combo), .none)
        XCTAssertEqual(state.flags(combo,target:combo), .arm); _ = state.armCompleted()
        XCTAssertEqual(state.flags(256,target:combo), .release)
        XCTAssertEqual(state.flags(combo,target:combo), .none)
        _ = state.flags(0,target:combo)
        XCTAssertEqual(state.flags(combo,target:combo), .arm)
    }
    func testKeyAlreadyHeldPreventsActivation() {
        var state = ModifierHoldState(); let fn = DictationShortcut.fn
        _ = state.key(0,down:true)
        XCTAssertEqual(state.flags(fn,target:fn), .none)
        _ = state.key(0,down:false)
        XCTAssertEqual(state.armCompleted(), .none)
    }
}
