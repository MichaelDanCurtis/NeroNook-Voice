import XCTest
@testable import ModuleCore
import NookPluginSDK

final class SpeechExpressionTests: XCTestCase {
    func testAppleUsesProsodyPresetsAndPreservesOtherControls() {
        let options = QwenOptions()
        XCTAssertEqual(SpeechExpression.resolve(.named("gentle"),backend:.apple,delivery:.natural,options:options).delivery,.warm)
        XCTAssertEqual(SpeechExpression.resolve(.named("reflective"),backend:.apple,delivery:.natural,options:options).delivery,.relaxed)
        XCTAssertEqual(SpeechExpression.resolve(.named("bright"),backend:.apple,delivery:.warm,options:options).delivery,.warm)
    }
    func testCloneAndDesignedIdentityNeverChange() {
        for mode in [QwenMode.clone, .design] {
            var options = QwenOptions(); options.mode = mode; options.cloneID = UUID(); options.instruction = "Original voice description"
            for cue in PluginExpressionCue.Delivery.allCases {
                let result = SpeechExpression.resolve(.named(cue.rawValue),backend:.qwen,delivery:.warm,options:options)
                XCTAssertEqual(result.options,options); XCTAssertEqual(result.delivery,.warm)
            }
        }
    }
    func testCustomVoiceUsesFixedInstructionAndNoSettingsMutation() throws {
        var options = QwenOptions(); options.instruction = "Clear diction"
        let result = SpeechExpression.resolve(.named("bright"),backend:.qwen,delivery:.natural,options:options)
        XCTAssertTrue(result.options.instruction.hasPrefix("Clear diction ")); XCTAssertTrue(result.options.instruction.contains("upbeat"))
        XCTAssertEqual(options.instruction,"Clear diction"); XCTAssertEqual(result.options.mode,.preset)
        XCTAssertEqual(result.options.cloneID,options.cloneID); XCTAssertEqual(result.options.maxTokens,options.maxTokens)
        try result.options.validate()
        options.instruction = String(repeating:"x",count:512)
        XCTAssertEqual(SpeechExpression.resolve(.named("bright"),backend:.qwen,delivery:.natural,options:options).options,options)
    }
    func testMalformedCueUsesSelectedDelivery() {
        var cue = PluginExpressionCue.named("gentle")!; cue.durationMs = 9999
        XCTAssertEqual(SpeechExpression.resolve(cue,backend:.apple,delivery:.relaxed,options:.init()).delivery,.relaxed)
    }
}
