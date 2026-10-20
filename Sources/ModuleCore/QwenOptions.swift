import Foundation

public enum QwenMode: String, Codable, CaseIterable, Sendable {
    case preset, clone, design
    public var title: String { switch self { case .preset: return "Preset voices"; case .clone: return "Cloned voice"; case .design: return "Describe a voice" } }
    public var modelType: String { switch self { case .preset: return "custom_voice"; case .clone: return "base"; case .design: return "voice_design" } }
}

public struct QwenOptions: Codable, Equatable, Sendable {
    public var mode: QwenMode = .preset
    public var cloneID: UUID?
    public var language = "Follow Voice"
    public var instruction = ""
    public var temperature: Double = 0.9
    public var topP: Double = 1
    public var topK = 50
    public var repetitionPenalty: Double = 1.1
    public var maxTokens = 1800
    public var streamingInterval: Double = 0.32
    public init() {}
    public static let languages = ["Follow Voice", "English", "Chinese", "Japanese", "Korean", "German", "French", "Russian", "Portuguese", "Spanish", "Italian"]
    public func validate(requireVoice: Bool = false) throws {
        guard Self.languages.contains(language), instruction.utf8.count <= 512,
              temperature.isFinite, (0...1.5).contains(temperature), topP.isFinite, (0.1...1).contains(topP),
              (0...100).contains(topK), repetitionPenalty.isFinite, (1...1.5).contains(repetitionPenalty),
              (128...1800).contains(maxTokens), streamingInterval.isFinite, (0.16...1).contains(streamingInterval) else {
            throw VoiceProblem.message("Qwen settings are outside their supported limits")
        }
        if requireVoice && mode == .clone && cloneID == nil { throw VoiceProblem.message("Save and select a reference voice in Qwen Voice Studio") }
        if requireVoice && mode == .design && instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw VoiceProblem.message("Describe the voice in Qwen Voice Studio first") }
    }
    public static func saved(_ data: Data?) -> Self {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data), (try? value.validate()) != nil else { return .init() }
        return value
    }
}
