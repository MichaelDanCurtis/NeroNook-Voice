import Foundation
import NookPluginSDK

/// Adapter controls only. The selected backend, model, clone and voice remain
/// untouched. Clone and VoiceDesign retain their original reference/description.
public enum SpeechExpression {
    public struct Resolution: Equatable {
        public let delivery: SpeechDelivery
        public let options: QwenOptions
        public let support: String
    }
    public static func resolve(_ cue: PluginExpressionCue?, backend: SpeechBackend, delivery: SpeechDelivery, options: QwenOptions) -> Resolution {
        guard let cue, (try? cue.validate()) != nil, cue.delivery != .natural else {
            return .init(delivery: delivery, options: options, support: "selected-delivery")
        }
        if backend == .apple {
            let supported: SpeechDelivery
            switch cue.delivery { case .gentle: supported = .warm; case .reflective: supported = .relaxed; default: supported = delivery }
            return .init(delivery: supported, options: options, support: "apple-prosody-presets")
        }
        // Only the pinned 1.7B CustomVoice preset path receives fixed style
        // instructions. Base clone has no such API; design instructions define
        // identity, so a transient cue must not append to that description.
        guard options.mode == .preset else { return .init(delivery: delivery, options: options, support: "visual-only-selected-voice") }
        let instruction: String
        switch cue.delivery {
        case .gentle: instruction = "Speak gently and unhurriedly, with clear pronunciation."
        case .bright: instruction = "Speak with light, upbeat energy and clear pronunciation."
        case .reflective: instruction = "Speak calmly and thoughtfully, with clear pronunciation."
        case .playful: instruction = "Speak with a subtle playful lilt and clear pronunciation."
        case .natural: instruction = ""
        }
        var value = options
        let combined = [options.instruction, instruction].filter { !$0.isEmpty }.joined(separator: " ")
        guard combined.utf8.count <= 512 else { return .init(delivery: delivery, options: options, support: "visual-only-instruction-limit") }
        value.instruction = combined
        return .init(delivery: delivery, options: value, support: "qwen-1.7b-customvoice-instruction")
    }
}
