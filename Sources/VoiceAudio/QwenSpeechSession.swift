import Darwin
import Foundation
import ModuleCore

@MainActor final class QwenSpeechSession {
 private let worker=SpeechSessionProcess()
 private var wire=QwenSpeechWire(),closed=false
 private var waiters:[CheckedContinuation<Void,Error>]=[]
 private var pending:AsyncThrowingStream<Data,Error>.Continuation?
 private var reader:Task<Void,Never>?,timer:Task<Void,Never>?
 var usable:Bool{!closed}
 init(helper:URL,model:URL)throws {
  let env=["HOME":FileManager.default.homeDirectoryForCurrentUser.path,"PATH":"/usr/bin:/bin","TMPDIR":FileManager.default.temporaryDirectory.path,"LANG":"en_US.UTF-8","HF_HUB_OFFLINE":"1","TRANSFORMERS_OFFLINE":"1","HF_HUB_DISABLE_IMPLICIT_TOKEN":"1"]
  let fd=try worker.start(executable:"/usr/bin/sandbox-exec",arguments:["-p","(version 1)(allow default)(deny network*)(deny device-microphone)(deny device-camera)",helper.path,"--tts",model.path],environment:env)
  let worker=self.worker
  reader=Task.detached{[weak self] in
   defer{close(fd);worker.reap()};var buffer=Data(),bytes=[UInt8](repeating:0,count:8192)
   while !Task.isCancelled {
    let n=read(fd,&bytes,bytes.count);if n<0 && errno==EINTR{continue};if n<=0{break};buffer.append(contentsOf:bytes.prefix(n))
    while let end=buffer.firstIndex(of:10){let line=Data(buffer[..<end]);buffer.removeSubrange(...end);await self?.receive(line)}
    if buffer.count>49152{break}
   };await self?.stop("Qwen speech worker disconnected")
  };arm(90)
 }
 deinit{timer?.cancel();reader?.cancel();worker.stop()}
 func prepare()async throws{try Task.checkCancellation();guard !closed,waiters.count<4 else{throw VoiceProblem.message("Qwen speech worker unavailable")};if wire.ready{return};try await withTaskCancellationHandler { try await withCheckedThrowingContinuation{waiters.append($0)} } onCancel: { Task { @MainActor [weak self] in self?.stop("Qwen preparation cancelled") } };try Task.checkCancellation()}
 func stream(_ data:Data,id:UUID)async throws->AsyncThrowingStream<Data,Error>{
  try await prepare();guard !closed,pending==nil,data.count<=8192,!data.contains(10) else{throw VoiceProblem.message("Qwen speech is busy")};try wire.begin(id)
  let pair=AsyncThrowingStream<Data,Error>.makeStream(bufferingPolicy:.bufferingOldest(8));pending=pair.continuation
  pair.continuation.onTermination={[weak self] reason in if case .cancelled=reason{Task{@MainActor in self?.cancelPending()}}}
  arm(180);let worker=self.worker
  Task{[weak self] in let sent=await Task.detached{worker.write(data+Data([10]))}.value;if !sent{self?.stop("Qwen request could not be delivered")}}
  return pair.stream
 }
 private func receive(_ line:Data){guard !closed else{return};do{switch try wire.accept(line){
 case .ready:let old=waiters;waiters=[];arm(60);old.forEach{$0.resume()}
 case .audio(let pcm):guard let pending else{throw VoiceProblem.message("Unexpected Qwen audio")};if case .dropped=pending.yield(pcm){throw VoiceProblem.message("Qwen playback could not keep up")}
 case .done:let old=pending;pending=nil;old?.finish();arm(60)
 case .error(let text):stop(text)
 }}catch{stop(error.localizedDescription)}}
 func cancelPending(){if pending != nil || !waiters.isEmpty{stop("Qwen speech cancelled")}}
 private func arm(_ seconds:Int){timer?.cancel();timer=Task{[weak self] in try? await Task.sleep(for:.seconds(seconds));guard !Task.isCancelled else{return};self?.stop("Qwen speech timed out or its idle model was released")}}
 func stop(_ message:String="Qwen speech stopped") {guard !closed else{return};closed=true;timer?.cancel();reader?.cancel();worker.stop();let error=VoiceProblem.message(message);let old=waiters;waiters=[];old.forEach{$0.resume(throwing:error)};pending?.finish(throwing:error);pending=nil}
}
