import AVFoundation
import ModuleCore
import VoiceAudio

/// The actual app's selected speech settings; not an engine or authority API.
/// Kept internal so service tests need not create profile/hotkey-owning VoiceModel.
@MainActor protocol ConversationPreferences: AnyObject {
    var preloader: SpeechPreloader { get }
    var conversationPace: ConversationPace { get }
    var interruptionSensitivity: Int { get set }
    var dictationASR: VoiceASRProvider { get }
    var locale: String { get }
    var microphone: String { get }
    var speechBackend: SpeechBackend { get }
    var qwenOptions: QwenOptions { get }
    var voiceID: String { get }
    var speechDelivery: SpeechDelivery { get }
    var selectedSpeechVoice: AVSpeechSynthesisVoice? { get }
    var qwenSpeaker: QwenSpeaker { get }
}

extension VoiceModel: ConversationPreferences {}
