import Foundation
import CryptoKit
import Darwin
import ModuleCore

public struct QwenModel:Sendable {
 struct Asset:Codable,Sendable {let name:String;let bytes:Int;let sha256:String}
 struct Recipe:Codable,Sendable {let repository:String;let revision:String;let files:[Asset]}
 let recipe:Recipe
 public let directory:URL
 public init(mode:QwenMode = .preset,recipeURL:URL?=nil,directory:URL?=nil)throws {
  let file = mode == .preset ? "qwen-tts" : mode == .clone ? "qwen-base" : "qwen-design"
  let repo = mode == .preset ? "CustomVoice" : mode == .clone ? "Base" : "VoiceDesign"
  let revision = mode == .preset ? "41d3337e8b7f2843a75841595fc14e4b9a7a4b96" : mode == .clone ? "e7dd0585652209fa0d7783659aad4e8a324de11c" : "f90d617701d9f7f4ca499291e0b57f2b3c2fd2ee"
  guard let url=recipeURL ?? Bundle.main.url(forResource:file,withExtension:"json",subdirectory:"Models") else{throw VoiceProblem.message("Qwen model recipe is missing. Reinstall Nero Voice.")}
  recipe=try JSONDecoder().decode(Recipe.self,from:Data(contentsOf:url))
  guard recipe.repository=="mlx-community/Qwen3-TTS-12Hz-1.7B-\(repo)-8bit",recipe.revision==revision,!recipe.files.isEmpty,recipe.files.count<=32,recipe.files.allSatisfy({!$0.name.contains("..") && !$0.name.hasPrefix("/") && $0.bytes>0 && $0.sha256.count==64}) else{throw VoiceProblem.message("Invalid Qwen model recipe")}
  self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NeroVoice/Models/Qwen3-"+repo+"-8bit-"+recipe.revision,isDirectory:true)
 }
 public var downloadBytes:Int{recipe.files.reduce(0){$0+$1.bytes}}
 public var ready:Bool{recipe.files.allSatisfy{a in let v=try? directory.appendingPathComponent(a.name).resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey]);return v?.isSymbolicLink==false && v?.fileSize==a.bytes}}
 public func verify()async throws{try await verify(directory)}
 private func verify(_ folder:URL)async throws {
  let recipe=recipe
  let work=Task.detached {
   for a in recipe.files {
    try Task.checkCancellation();let url=folder.appendingPathComponent(a.name)
    var parent=url
    while parent.path.count>=folder.path.count {guard (try parent.resourceValues(forKeys:[.isSymbolicLinkKey])).isSymbolicLink != true else{throw VoiceProblem.message("Qwen model cannot contain links")};if parent==folder{break};parent.deleteLastPathComponent()}
    guard (try url.resourceValues(forKeys:[.fileSizeKey])).fileSize==a.bytes else{throw VoiceProblem.message("Qwen model is incomplete")}
    let fd=open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else{throw VoiceProblem.message("Could not verify Qwen")};defer{close(fd)}
    var hash=SHA256(),buffer=[UInt8](repeating:0,count:1048576)
    while true{try Task.checkCancellation();let n=read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0 else{throw VoiceProblem.message("Could not read Qwen model")};if n==0{break};buffer.withUnsafeBytes{hash.update(bufferPointer:UnsafeRawBufferPointer(rebasing:$0[..<n]))}}
    guard hash.finalize().map({String(format:"%02x",$0)}).joined()==a.sha256 else{throw VoiceProblem.message("Qwen model verification failed")}
   }
  }
  try await withTaskCancellationHandler{try await work.value}onCancel:{work.cancel()}
 }
 /// Explicit preparation only. No synthesis or capture, and no inference API.
 public func download(progress:@escaping @Sendable(Int,Int)->Void={_,_ in})async throws {
  if ready{try await verify();return}
  let fm=FileManager.default,parent=directory.deletingLastPathComponent();try fm.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  guard (try parent.resourceValues(forKeys:[.volumeAvailableCapacityKey])).volumeAvailableCapacity ?? 0 > downloadBytes+512000000 else{throw VoiceProblem.message("Qwen needs about 3.6 GB of free space")}
  let staging=parent.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:staging,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? fm.removeItem(at:staging)}
  let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=180;config.timeoutIntervalForResource=3600;let session=URLSession(configuration:config);defer{session.invalidateAndCancel()}
  for (i,a) in recipe.files.enumerated(){try Task.checkCancellation();progress(i,recipe.files.count);let url=URL(string:"https://huggingface.co/\(recipe.repository)/resolve/\(recipe.revision)/\(a.name)")!;let(temp,response)=try await session.download(from:url);defer{try? fm.removeItem(at:temp)};guard (response as? HTTPURLResponse)?.statusCode==200,(try temp.resourceValues(forKeys:[.fileSizeKey])).fileSize==a.bytes else{throw VoiceProblem.message("Qwen download was incomplete")};let dest=staging.appendingPathComponent(a.name);try fm.createDirectory(at:dest.deletingLastPathComponent(),withIntermediateDirectories:true);try fm.moveItem(at:temp,to:dest)}
  try await verify(staging);try Task.checkCancellation();if fm.fileExists(atPath:directory.path){try fm.removeItem(at:directory)};try fm.moveItem(at:staging,to:directory);progress(recipe.files.count,recipe.files.count)
 }
}
