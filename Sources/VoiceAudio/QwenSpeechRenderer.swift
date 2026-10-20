import Foundation
import AVFoundation
import ModuleCore

@MainActor final class QwenSpeechRenderer {
 private static weak var owner:QwenSpeechRenderer?
 var engineOutput:ConversationAudio?
 var changed:((SpeechPlayback.Phase,String?)->Void)?
 private var modelMode:QwenMode?
 private var session:QwenSpeechSession?,task:Task<Void,Never>?,deadline:Task<Void,Never>?
 private var state=SpeechPlayback(),preparing=false,preparation=UUID()
 private var ownOutput:ConversationAudio?,playback:ConversationAudio?
 func prepare(mode:QwenMode = .preset)async throws {
  if let other=Self.owner,other !== self {guard !other.state.active,!other.preparing else{throw VoiceProblem.message("Qwen is in use by another Voice activity")};other.shutdown()}
  Self.owner=self
  if modelMode != mode { session?.stop(); session=nil; modelMode=mode }
  if session?.usable==true{try await session!.prepare();return}
  let id=UUID();preparation=id;preparing=true;defer{if preparation==id{preparing=false}}
  let model=try QwenModel(mode:mode);guard model.ready else{throw VoiceProblem.message("Prepare the selected Qwen model in Qwen Voice Studio first (about 3.1 GB)")}
  try await model.verify();try Task.checkCancellation();guard preparation==id else{throw CancellationError()}
  let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroASR")
  guard FileManager.default.isExecutableFile(atPath:helper.path) else{throw VoiceProblem.message("This Nero Voice build is missing its Qwen helper")}
  let new=try QwenSpeechSession(helper:helper,model:model.directory);session=new;try await new.prepare()
 }
 func speak(_ text:String,voice:QwenSpeaker,locale:String,delivery:SpeechDelivery,options:QwenOptions = .init())throws {
  try options.validate(requireVoice:true)
  let selectedReference = try options.mode == .clone ? options.cloneID.map { try QwenVoiceLibrary().reference($0) } : nil
  try VoiceSession.validate(text);let language=try options.language == "Follow Voice" ? QwenLanguage.name(for:locale) : options.language;stop();let id=try state.begin(text);changed?(.preparing,nil)
  deadline=Task{[weak self] in try? await Task.sleep(for:.seconds(180));guard !Task.isCancelled,let self,self.state.token==id,self.state.active else{return};self.stop();self.changed?(.idle,"Qwen playback timed out; your text is retained") }
  var fields:[String:Any]=["id":id.uuidString,"text":text,"voice":voice.rawValue,"language":language,"delivery":delivery.rawValue,"options":try JSONSerialization.jsonObject(with:JSONEncoder().encode(options))]
  if let (profile,url)=selectedReference { fields["reference"]=url.path; fields["referenceText"]=profile.transcript; fields["referenceHash"]=profile.sha256 }
  let data=try JSONSerialization.data(withJSONObject:fields)
  task=Task{[weak self] in guard let self else{return};do{
   try await prepare(mode:options.mode);try Task.checkCancellation();guard state.token==id,state.active,let session else{return}
   let stream=try await session.stream(data,id:id)
   for try await pcm in stream {
    try Task.checkCancellation();guard state.token==id,state.active else{return}
    if playback==nil {
     if let engineOutput{playback=engineOutput}else{let output=ConversationAudio();try output.startOutput();ownOutput=output;playback=output}
     playback!.beginPlayback{[weak self] in self?.complete(id)}
    }
    let buffer=AVAudioPCMBuffer(pcmFormat:AVAudioFormat(standardFormatWithSampleRate:24000,channels:1)!,frameCapacity:AVAudioFrameCount(pcm.count/4))!;buffer.frameLength=buffer.frameCapacity
    _=pcm.withUnsafeBytes{memcpy(buffer.floatChannelData![0],$0.baseAddress!,pcm.count)}
    try playback!.appendPlayback(buffer)
    if state.started(id){changed?(.speaking,nil)}
   }
   guard state.token==id,state.active,let playback else{throw VoiceProblem.message("Qwen returned no playable audio")};playback.finishPlayback()
  }catch{guard state.token==id,state.active else{return};stop();changed?(.idle,error.localizedDescription)}}
 }
 private func complete(_ id:UUID){guard state.finished(id) else{return};deadline?.cancel();deadline=nil;task=nil;ownOutput?.stop();ownOutput=nil;playback=nil;changed?(.finished,nil)}
 func stop(){state.stop();deadline?.cancel();deadline=nil;task?.cancel();task=nil;session?.cancelPending();playback?.stopPlayback();playback=nil;ownOutput?.stop();ownOutput=nil;changed?(.idle,nil)}
 func shutdown(){preparation=UUID();preparing=false;stop();session?.stop();session=nil;if Self.owner === self{Self.owner=nil}}
}
