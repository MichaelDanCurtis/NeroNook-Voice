import XCTest
@testable import ModuleCore

final class QwenOptionsTests: XCTestCase {
    func testPersistedSettingsAndOldInstallDefault() throws {
        XCTAssertEqual(QwenOptions.saved(nil).mode, .preset)
        XCTAssertEqual(QwenOptions.saved(Data("{}".utf8)), .init())
        var value = QwenOptions(); value.mode = .clone; value.cloneID = UUID(); value.language = "Japanese"; value.topK = 17
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(QwenOptions.saved(data), value)
        try value.validate(requireVoice: true)
    }
    func testMissingVoiceAndDesignDescription() throws {
        var value = QwenOptions(); value.mode = .clone
        XCTAssertThrowsError(try value.validate(requireVoice: true))
        value.mode = .design; value.instruction = " \n "
        XCTAssertThrowsError(try value.validate(requireVoice: true))
        value.instruction = "A calm narrator"
        try value.validate(requireVoice: true)
    }
    func testBoundsRejectCorruptedSavedOptions() throws {
        let edits: [(inout QwenOptions) -> Void] = [
            { $0.temperature = .infinity }, { $0.topP = 0 }, { $0.topK = -1 },
            { $0.repetitionPenalty = 2 }, { $0.maxTokens = 999999 }, { $0.streamingInterval = 0.01 },
            { $0.language = "Invented" }, { $0.instruction = String(repeating: "声", count: 200) }
        ]
        for edit in edits {
            var value = QwenOptions(); edit(&value)
            XCTAssertThrowsError(try value.validate())
            if let data = try? JSONEncoder().encode(value) { XCTAssertEqual(QwenOptions.saved(data), .init()) }
        }
    }
}
