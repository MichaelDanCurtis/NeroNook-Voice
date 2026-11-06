import Foundation
import AVFoundation
import AudioToolbox
import ModuleCore

private final class ReferenceSink: @unchecked Sendable {
    let queue = DispatchQueue(label: "cafe.nero.voice.reference")
    private let slots = DispatchSemaphore(value: 16)
    private var file: AVAudioFile?
    private let converter: AVAudioConverter
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
    private var frames = 0, active = true
    private var failure: Error?
    init(url: URL, input: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: input, to: format) else { throw VoiceProblem.message("Cannot prepare reference recording") }
        self.converter = converter; file = try AVAudioFile(forWriting: url, settings: format.settings)
    }
    func append(_ input: AVAudioPCMBuffer) {
        guard input.frameLength > 0, input.frameLength <= 8192, slots.wait(timeout: .now()) == .success else { queue.async { self.failure = VoiceProblem.message("Reference audio could not keep up") }; return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { slots.signal(); return }
        copy.frameLength = input.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList)), dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<src.count { memcpy(dst[i].mData!, src[i].mData!, Int(src[i].mDataByteSize)) }
        queue.async { defer { self.slots.signal() }; guard self.active, self.failure == nil, self.frames < 720000 else { return }
            guard let out = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: 32768) else { return }
            var fed = false, error: NSError?
            self.converter.convert(to: out, error: &error) { _, state in if fed { state.pointee = .noDataNow; return nil }; fed = true; state.pointee = .haveData; return copy }
            if let error { self.failure = error; return }
            out.frameLength = min(out.frameLength, AVAudioFrameCount(720000-self.frames))
            do { try self.file?.write(from: out); self.frames += Int(out.frameLength) } catch { self.failure = error }
        }
    }
    func finish() throws { try queue.sync { active = false; defer { file = nil }; if let failure { throw failure }; guard frames >= 72000 else { throw VoiceProblem.message("Record at least three seconds of speech") } } }
}

/// Shared production stop tail: native admission closes before Stop; actual
/// entered tap callbacks return before the final writer-queue/file barrier.
@MainActor final class QwenReferenceReturnTail {
    let admission=VoiceAudioCallbackAdmission()
    private var original:Task<Result<URL,Error>,Never>?
    private(set)var immediate:Result<URL,Error>?
    func stop(native:()->Void,writer:@escaping @MainActor () ->Result<URL,Error>)->Task<Result<URL,Error>,Never>{
        if let original{return original}
        admission.seal();native();admission.nativeStopReturned()
        if admission.enteredCallbackCount == 0{
            let result=writer();immediate=result
            let task=Task{result};original=task;return task
        }
        let task=Task{[self] in
            await admission.waitForReturn()
            let result=writer();immediate=result;return result
        }
        original=task;return task
    }
}

/// Explicit selected-microphone recording only. No ASR or system audio.
@MainActor public final class QwenReferenceRecorder {
    @MainActor private final class Original {
        let id=UUID(),engine:AVAudioEngine,sink:ReferenceSink,url:URL
        let tail=QwenReferenceReturnTail()
        var tapInstalled=false,cancelled=false
        var cleanupIssue:String?
        init(engine:AVAudioEngine,sink:ReferenceSink,url:URL){self.engine=engine;self.sink=sink;self.url=url}
    }
    private var current:Original?
    private var pending:[UUID:(task:Task<Void,Never>,original:Original)]=[:]
    public private(set)var retirementIssue:String?
    public init(){}
    public func start(microphone:String?)throws{
        guard current == nil,pending.isEmpty else{throw VoiceProblem.message("The previous reference recording is still returning. Try again shortly.")}
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("nero-qwen-reference-"+UUID().uuidString+".wav")
        let engine=AVAudioEngine()
        do{
            guard var device=MicrophoneDeviceService.deviceID(for:microphone),let unit=engine.inputNode.audioUnit else{throw VoiceProblem.message("Choose an available microphone in Voice settings")}
            var selected=AudioDeviceID(0),size=UInt32(MemoryLayout<AudioDeviceID>.size)
            let read=AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&selected,&size)
            if read != noErr || selected != device{
                guard AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,UInt32(MemoryLayout.size(ofValue:device))) == noErr else{throw VoiceProblem.message("Cannot select the reference microphone")}
            }
            let format=engine.inputNode.inputFormat(forBus:0)
            guard (8000...192000).contains(format.sampleRate),(1...8).contains(format.channelCount) else{throw VoiceProblem.message("Unsupported microphone format")}
            let sink=try ReferenceSink(url:url,input:format),original=Original(engine:engine,sink:sink,url:url)
            current=original
            let gate=original.tail.admission
            engine.inputNode.installTap(onBus:0,bufferSize:1024,format:format){buffer,_ in
                guard let entered=gate.enter()else{return};defer{entered.finish()}
                sink.append(buffer)
            }
            original.tapInstalled=true;engine.prepare();try engine.start()
        }catch{
            if current != nil{cancel()}else if FileManager.default.fileExists(atPath:url.path){try? FileManager.default.removeItem(at:url)}
            throw error
        }
    }
    private func stop(_ original:Original)->Task<Result<URL,Error>,Never>{
        original.tail.stop(native:{
            original.engine.stop()
            if original.tapInstalled{original.engine.inputNode.removeTap(onBus:0);original.tapInstalled=false}
        },writer:{Result{try original.sink.finish();return original.url}})
    }
    private func claim(_ original:Original,_ result:Result<URL,Error>)throws->URL{
        guard current === original,!original.cancelled else{throw CancellationError()}
        do{let url=try result.get();current=nil;return url}
        catch{cancel();throw error}
    }
    /// Source-compatible synchronous entry only returns when no original tap
    /// callback remains. The app uses finishAndWait for the asynchronous case.
    public func finish()throws->URL{
        guard let original=current else{throw VoiceProblem.message("No reference recording is running")}
        _=stop(original)
        guard let result=original.tail.immediate else{throw VoiceProblem.message("Reference callbacks are finishing; wait before trying again.")}
        return try claim(original,result)
    }
    public func finishOwned()->Task<Result<URL,Error>,Never>{
        guard let original=current else{return Task{.failure(VoiceProblem.message("No reference recording is running"))}}
        let returned=stop(original)
        return Task{[self,original] in
            let result=await returned.value
            return Result{try claim(original,result)}
        }
    }
    public func finishAndWait()async throws->URL{try await finishOwned().value.get()}
    public func cancel(){_ = ownedCancellation()}
    public func ownedCancellation()->Task<Void,Never>?{ownedCancellationResult().completion}
    public func ownedCancellationResult()->(completion:Task<Void,Never>?,issue:@MainActor () ->String?){
        cancelCurrent()
        let captured=Array(pending.values)
        let returned:Task<Void,Never>?=captured.isEmpty ? nil:Task{for original in captured{await original.task.value}}
        return(returned,{captured.compactMap{$0.original.cleanupIssue}.first})
    }
    private func cancelCurrent(){
        guard let original=current else{return};current=nil;original.cancelled=true
        let returned=stop(original)
        let task=Task{[self,original] in
            _=await returned.value
            do{try FileManager.default.removeItem(at:original.url)}catch{original.cleanupIssue=error.localizedDescription;retirementIssue=error.localizedDescription}
        }
        pending[original.id]=(task,original)
        Task{[weak self] in await task.value;self?.pending[original.id]=nil}
    }
    public func cancelAndWait()async{await ownedCancellation()?.value}
}
