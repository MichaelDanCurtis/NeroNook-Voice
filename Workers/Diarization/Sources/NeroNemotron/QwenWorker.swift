import Foundation
import MLX
import MLXAudioTTS
import MLXAudioCore
import MLXLMCommon
import Darwin
import CryptoKit

struct QwenWorkerOptions:Decodable {
 let mode:String;let instruction:String;let temperature:Double;let topP:Double;let topK:Int;let repetitionPenalty:Double;let maxTokens:Int;let streamingInterval:Double
 func validate()throws {guard ["preset","clone","design"].contains(mode),instruction.utf8.count<=512,temperature.isFinite,(0...1.5).contains(temperature),topP.isFinite,(0.1...1).contains(topP),(0...100).contains(topK),repetitionPenalty.isFinite,(1...1.5).contains(repetitionPenalty),(128...1800).contains(maxTokens),streamingInterval.isFinite,(0.16...1).contains(streamingInterval) else{throw NSError(domain:"Invalid Qwen generation settings",code:1)}}
}
struct Request:Decodable {let id:UUID;let text:String;let voice:String;let language:String;let delivery:String;let options:QwenWorkerOptions?;let reference:String?;let referenceText:String?;let referenceHash:String?}
enum QwenWorker {
 static let voices:Set<String>=["Ryan","Aiden","Vivian","Serena","Uncle_Fu","Dylan","Eric","Ono_Anna","Sohee"]
 static let languages:Set<String>=["English","Chinese","Japanese","Korean","German","French","Russian","Portuguese","Spanish","Italian"]
 static let output=FileHandle(fileDescriptor:dup(STDOUT_FILENO),closeOnDealloc:true)
 static func emit(_ value:[String:Any])throws {let d=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]);try output.write(contentsOf:d+Data([10]))}
 static func main()async {
  do {
   _ = output;dup2(STDERR_FILENO,STDOUT_FILENO)
   guard CommandLine.arguments.count==3 else{throw NSError(domain:"Choose a local Qwen model folder",code:1)}
   // Third-party loader prints diagnostics. Keep stdout exclusively framed PCM.
   let directory=URL(fileURLWithPath:CommandLine.arguments[2])
   let config=try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("config.json"))) as! [String:Any]
   let modelType=config["tts_model_type"] as? String ?? ""
   let model=try await Qwen3TTSModel.fromModelDirectory(directory)
   MLX.Memory.cacheLimit=128*1024*1024
   try emit(["kind":"ready","version":1,"sampleRate":model.sampleRate])
   var cachedReference:(hash:String,audio:MLXArray)?
   var buffered=Data();var bytes=[UInt8](repeating:0,count:4096)
   while true {
    let n=read(STDIN_FILENO,&bytes,bytes.count);if n==0{return};if n<0{if errno==EINTR{continue};return}
    buffered.append(contentsOf:bytes.prefix(n));guard buffered.count<=16384 else{return}
    while let end=buffered.firstIndex(of:10) {
     let line=Data(buffered[..<end]);buffered.removeSubrange(...end)
     let r=try JSONDecoder().decode(Request.self,from:line)
     guard !r.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,r.text.utf8.count<=2048,voices.contains(r.voice),languages.contains(r.language),["natural","warm","relaxed"].contains(r.delivery) else {throw NSError(domain:"Invalid speech request",code:2)}
     let style=r.delivery=="warm" ? "Speak warmly and softly, with clear, natural pronunciation." : r.delivery=="relaxed" ? "Speak calmly, in a relaxed lower register, with clear pronunciation." : "Speak naturally with clear pronunciation."
     let options=r.options
     try options?.validate()
     let mode=options?.mode ?? "preset"
     guard modelType == (mode == "clone" ? "base" : mode == "design" ? "voice_design" : "custom_voice") else{throw NSError(domain:"Choose the matching Qwen model for this voice mode",code:2)}
     var reference:MLXArray?,referenceText:String?,voice:String?=r.voice+", "+style
     if mode == "clone" {
      guard let path=r.reference,let text=r.referenceText,!text.isEmpty,text.utf8.count<=2048,let hash=r.referenceHash else{throw NSError(domain:"Choose a saved reference recording and transcript",code:3)}
      let url=URL(fileURLWithPath:path).standardizedFileURL
      let expected=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NeroVoice/QwenVoices")
      guard url.deletingLastPathComponent().deletingLastPathComponent()==expected,UUID(uuidString:url.deletingLastPathComponent().lastPathComponent) != nil,url.lastPathComponent=="reference.wav",url.resolvingSymlinksInPath()==url else{throw NSError(domain:"Reference must belong to the local Voice library",code:4)}
      guard (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0 <= 3000000 else{throw NSError(domain:"Reference audio too large",code:5)}
      let data=try Data(contentsOf:url)
      guard SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==hash else{throw NSError(domain:"Reference audio changed",code:6)}
      let audio:MLXArray
      if let cachedReference,cachedReference.hash==hash { audio=cachedReference.audio }
      else { let (_,loaded)=try loadAudioArray(from:url,sampleRate:24000);audio=loaded;cachedReference=(hash,loaded) }
      guard audio.size>=72000,audio.size<=720000 else{throw NSError(domain:"Reference must be 3–30 seconds",code:7)}
      reference=audio;referenceText=text;voice=nil
     }else if mode == "design" {
      guard let instruction=options?.instruction,!instruction.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw NSError(domain:"Describe the voice first",code:8)}
      voice=instruction+" "+style
     }else if let instruction=options?.instruction,!instruction.isEmpty { voice=r.voice+", "+instruction+" "+style }
     var sequence=0,total=0;let began=ProcessInfo.processInfo.systemUptime
     do {
      for try await event in model.generateStream(text:r.text,voice:voice,refAudio:reference,refText:referenceText,language:r.language,generationParameters:GenerateParameters(maxTokens:options?.maxTokens ?? 1800,temperature:Float(options?.temperature ?? 0.9),topP:Float(options?.topP ?? 1),topK:options?.topK ?? 50,repetitionPenalty:Float(options?.repetitionPenalty ?? 1.1)),streamingInterval:options?.streamingInterval ?? 0.32) {
       try Task.checkCancellation()
       guard ProcessInfo.processInfo.systemUptime-began<150 else{throw NSError(domain:"Qwen speech generation timed out",code:3)}
       if case .audio(let audio)=event {
        let floats=audio.asArray(Float.self);guard floats.allSatisfy({$0.isFinite}) else{throw NSError(domain:"Nonfinite speech output",code:4)}
        total+=floats.count;guard total<=model.sampleRate*180 else{throw NSError(domain:"Speech output exceeds three minutes",code:5)}
        for start in stride(from:0,to:floats.count,by:8192) {
         let values=Array(floats[start..<min(start+8192,floats.count)])
         let pcm=values.withUnsafeBytes{Data($0)}
         try emit(["kind":"audio","id":r.id.uuidString,"sequence":sequence,"sampleRate":model.sampleRate,"pcm":pcm.base64EncodedString()]);sequence+=1
        }
       }
      }
      guard total>0 else{throw NSError(domain:"Qwen returned no audio",code:6)}
      try emit(["kind":"done","id":r.id.uuidString,"sequence":sequence,"frames":total])
     }catch{try emit(["kind":"error","id":r.id.uuidString,"message":String(error.localizedDescription.prefix(240))]);return}
    }
   }
  }catch{try? emit(["kind":"error","message":String(error.localizedDescription.prefix(240))]);exit(1)}
 }
}
