import Foundation
import AVFoundation
import ModuleCore

/// Shared Voice-owned synthesis selection; Agent/Fuego use the same SDK path.
@MainActor public final class SpeechOutput {
 private let apple=AppleSpeechOutput(),qwen=QwenSpeechRenderer()
 public var engineOutput:ConversationAudio? {didSet{apple.engineOutput=engineOutput;qwen.engineOutput=engineOutput}}
 public var changed:((SpeechPlayback.Phase,String?)->Void)?
 private var forwarding=true
 public init(){apple.changed={[weak self] p,e in if self?.forwarding==true{self?.changed?(p,e)}};qwen.changed={[weak self] p,e in if self?.forwarding==true{self?.changed?(p,e)}}}
 public func prepareQwen(mode:QwenMode = .preset)async throws {try await qwen.prepare(mode:mode)}
 public func prepareVoice2()throws{try apple.prepareVoice2()}
 public func speak(_ text:String,backend:SpeechBackend,voiceID:String,appleVoice:AVSpeechSynthesisVoice?,qwenSpeaker:QwenSpeaker,locale:String,delivery:SpeechDelivery,qwenOptions:QwenOptions = .init())throws {
  try VoiceSession.validate(text);stop()
  if backend == .qwen{try qwen.speak(text,voice:qwenSpeaker,locale:locale,delivery:delivery,options:qwenOptions)}
  else if voiceID==AppleSpeechOutput.voice2Identifier{try apple.speakVoice2(text,delivery:delivery)}
  else{guard let voice=appleVoice else{throw VoiceProblem.message("Choose an available Apple voice")};try apple.speak(text,voice:voice,delivery:delivery)}
 }
 public func stop(){forwarding=false;apple.stop();qwen.stop();forwarding=true;changed?(.idle,nil)}
 public func shutdown(){forwarding=false;apple.shutdown();qwen.shutdown();forwarding=true;changed?(.idle,nil)}
}
