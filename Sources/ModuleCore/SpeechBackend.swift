import Foundation
public enum SpeechBackend:String,CaseIterable,Codable,Sendable {case apple,qwen
 public var title:String {self == .apple ? "Apple · default":"Qwen3 · local MLX"}
}
public enum QwenSpeaker:String,CaseIterable,Codable,Sendable {
 case ryan="Ryan",aiden="Aiden",vivian="Vivian",serena="Serena",uncleFu="Uncle_Fu",dylan="Dylan",eric="Eric",anna="Ono_Anna",sohee="Sohee"
 public var title:String {switch self{case .ryan:return "Ryan · English";case .aiden:return "Aiden · English";case .anna:return "Anna · Japanese";case .sohee:return "Sohee · Korean";default:return rawValue.replacingOccurrences(of:"_",with:" ")+" · Chinese"}}
}
public enum QwenLanguage {
 public static func name(for locale:String)throws->String {
  let map=["en":"English","zh":"Chinese","ja":"Japanese","ko":"Korean","de":"German","fr":"French","ru":"Russian","pt":"Portuguese","es":"Spanish","it":"Italian"]
  guard let name=map[String(locale.prefix(2)).lowercased()] else{throw VoiceProblem.message("Qwen does not support this speaking language. Choose a supported language or Apple speech.")};return name
 }
}
/// One ordered utterance. Invalid/late/oversized frames never become playback.
public struct QwenSpeechWire:Sendable {
 public enum Event:Sendable {case ready,audio(Data),done,error(String)}
 public private(set) var ready=false
 public private(set) var active:UUID?
 public private(set) var frames=0
 private var next=0
 public init(){}
 public mutating func begin(_ id:UUID)throws{guard ready,active==nil else{throw VoiceProblem.message("Qwen is not ready or is already speaking")};active=id;next=0;frames=0}
 public mutating func accept(_ line:Data)throws->Event{
  guard line.count<=49152,let v=try JSONSerialization.jsonObject(with:line) as? [String:Any],let kind=v["kind"] as? String else{throw VoiceProblem.message("Invalid Qwen speech frame")}
  if kind=="ready"{guard !ready,active==nil,Set(v.keys)==["kind","version","sampleRate"],v["version"] as? Int==1,v["sampleRate"] as? Int==24000 else{throw VoiceProblem.message("Unsupported Qwen speech worker")};ready=true;return .ready}
  if kind=="error"{guard let text=v["message"] as? String,text.utf8.count<=1024,(!ready && v["id"]==nil)||(active != nil && v["id"] as? String==active!.uuidString) else{throw VoiceProblem.message("Stale Qwen error")};return .error(text)}
  guard let active,v["id"] as? String==active.uuidString,v["sequence"] as? Int==next else{throw VoiceProblem.message("Stale or out-of-order Qwen audio")}
  if kind=="audio" {
   guard Set(v.keys)==["kind","id","sequence","sampleRate","pcm"],v["sampleRate"] as? Int==24000,let s=v["pcm"] as? String,let pcm=Data(base64Encoded:s),!pcm.isEmpty,pcm.count<=32768,pcm.count%4==0,frames+pcm.count/4<=24000*180 else{throw VoiceProblem.message("Qwen audio exceeds its limits")}
   var values=[Float](repeating:0,count:pcm.count/4);_ = values.withUnsafeMutableBytes{pcm.copyBytes(to:$0)}
   guard values.allSatisfy({$0.isFinite && abs($0)<=4}) else{throw VoiceProblem.message("Invalid Qwen audio samples")};frames+=values.count;next+=1;return .audio(pcm)
  }
  guard kind=="done",Set(v.keys)==["kind","id","sequence","frames"],frames>0,v["frames"] as? Int==frames else{throw VoiceProblem.message("Incomplete Qwen audio")};self.active=nil;return .done
 }
}
