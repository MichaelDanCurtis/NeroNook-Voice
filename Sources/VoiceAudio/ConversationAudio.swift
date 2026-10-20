import AVFoundation
import AudioToolbox
import Foundation
import ModuleCore

/// Owns both VPIO directions so synthesized audio is in the echo reference.
/// No disk recording. The tap performs conversion plus a bounded feed append.
@MainActor public final class ConversationAudio {
    private let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    private var tap: ConversationInput?
    private var inputSink: AVAudioSinkNode?
    private var silence: AVAudioSourceNode?
    private var observer: NSObjectProtocol?
    private var playToken = UUID(), queued = 0
    private var renderedEnd = false
    private var completed: (() -> Void)?
    private var outputConverter: AVAudioConverter?
    private var outputInputFormat: AVAudioFormat?
    private var started = false, tapInstalled = false
    private let outputEnvelope = PlaybackEnvelope()
    private var playbackTapInstalled = false
    public var playbackLevel: Double { outputEnvelope.level }
    public private(set) var echoControl = false
    public var failure: ((String) -> Void)?
    public init() {}
    public var signal: (time: Double, rms: Double, age: Double) { tap?.signal ?? (0,0,0) }
    public func recognition(_ enabled: Bool) { tap?.setEnabled(enabled) }
    /// Output-only reuse for explicit playback; never opens an input node.
    public func startOutput() throws {
        guard !started else { throw VoiceProblem.message("Audio output already started") }
        engine.attach(player)
        engine.connect(player,to:engine.mainMixerNode,format:AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!)
        installPlaybackMeter()
        engine.prepare();try engine.start();started=true
    }
    public func start(microphone: String?, full: Bool, feed: MeetingLiveAudioFeed) throws {
        guard let device = MicrophoneDeviceService.deviceID(for: microphone), let unit = engine.inputNode.audioUnit else { throw VoiceProblem.message("Choose an available microphone in Voice settings.") }
        var current = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&current,&size)
        if current != device { var selected = device; guard AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&selected,size) == noErr else { throw VoiceProblem.message("Could not select the microphone.") } }
        do { try engine.inputNode.setVoiceProcessingEnabled(true); echoControl = engine.inputNode.isVoiceProcessingEnabled } catch { if full { throw VoiceProblem.message("Full duplex echo control is unavailable on this audio route. Choose Half duplex or a headset route.") } }
        engine.inputNode.isVoiceProcessingInputMuted = false
        let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let tap = try ConversationInput(format: format, feed: feed); self.tap = tap
        engine.attach(player)
        // VPIO requires matching client-side input/output formats, even when
        // the physical speakers and microphone use different hardware rates.
        engine.connect(engine.mainMixerNode,to:engine.outputNode,format:format)
        engine.connect(player,to:engine.mainMixerNode,format:AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!)
        installPlaybackMeter()
        // Keep both VPIO directions in the render graph. An idle player alone
        // does not sustain its downlink, and a tap alone is not an input sink.
        let sink = AVAudioSinkNode { _, frames, list in
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat:format,bufferListNoCopy:list,deallocator:nil) else {return noErr}
            guard buffer.frameCapacity >= frames else { return noErr };buffer.frameLength=frames
            tap.append(buffer);return noErr
        }
        inputSink=sink;engine.attach(sink);engine.connect(engine.inputNode,to:sink,format:format)
        let silentFormat = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let silence = AVAudioSourceNode(format:silentFormat) { silent,_,_,list in
            silent.pointee=true
            for buffer in UnsafeMutableAudioBufferListPointer(list) {if let data=buffer.mData{memset(data,0,Int(buffer.mDataByteSize))}}
            return noErr
        }
        self.silence=silence;engine.attach(silence);engine.connect(silence,to:engine.mainMixerNode,format:silentFormat)
        do { engine.prepare(); try engine.start(); started = true } catch { stop(); throw VoiceProblem.message("Could not open this microphone/speaker route. Choose another microphone or output, then press Talk again. (\((error as NSError).code))") }
        observer = NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:nil) { [weak self] _ in Task { @MainActor in self?.failure?("Audio route changed. Conversation stopped; press Talk to use the new route.") } }
    }
    public func beginPlayback(completed: @escaping () -> Void) { stopPlayback(); self.completed = completed }
    public func appendPlayback(_ input: AVAudioPCMBuffer) throws {
        guard started, input.frameLength > 0, input.frameLength <= 65536, input.format.channelCount <= 8,
              let format = AVAudioFormat(standardFormatWithSampleRate:48000,channels:1),
              let output = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(Double(input.frameLength)*48000/input.format.sampleRate)+1024) else { throw VoiceProblem.message("Unsupported speech output buffer") }
        if outputConverter == nil || outputInputFormat != input.format { outputConverter = AVAudioConverter(from:input.format,to:format);outputInputFormat=input.format }
        guard let converter=outputConverter else {throw VoiceProblem.message("Speech output conversion unavailable")}
        var fed=false, error:NSError?
        converter.convert(to:output,error:&error) { _,status in if fed { status.pointee = .noDataNow; return nil }; fed=true;status.pointee = .haveData;return input }
        guard error == nil else {throw VoiceProblem.message("Speech output conversion failed")}
        if output.frameLength > 0 {try schedule(output)}
    }
    private func schedule(_ output:AVAudioPCMBuffer) throws {
        guard queued < 1024 else { throw VoiceProblem.message("Speech playback could not keep up.") }
        queued += 1; let token = playToken
        player.scheduleBuffer(output,completionCallbackType:.dataPlayedBack) { [weak self] _ in Task { @MainActor in guard let self,self.playToken == token else{return};self.queued -= 1;self.completeIfDrained() } }
        if !player.isPlaying { player.play() }
    }
    public func playFile(_ url: URL, completed: @escaping () -> Void) throws {
        let file = try AVAudioFile(forReading:url)
        guard file.length > 0,Double(file.length)/file.processingFormat.sampleRate <= 180 else { throw VoiceProblem.message("Speech output exceeds its limit.") }
        beginPlayback(completed:completed)
        while file.framePosition < file.length { let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:8192)!;try file.read(into:buffer,frameCount:8192);try appendPlayback(buffer) }
        finishPlayback()
    }
    public func finishPlayback() {
        if let converter=outputConverter,let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1) {
            for _ in 0..<8 {
                let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4096)!;var error:NSError?
                let status=converter.convert(to:buffer,error:&error){_,state in state.pointee = .endOfStream;return nil}
                if error != nil {failure?("Could not finish speech output");return}
                if buffer.frameLength>0 {do{try schedule(buffer)}catch{failure?(error.localizedDescription);return}}
                if status == .endOfStream || buffer.frameLength==0 {break}
            }
        }
        outputConverter=nil;outputInputFormat=nil;renderedEnd = true; completeIfDrained()
    }
    private func completeIfDrained() { if renderedEnd && queued == 0 { let done=completed;completed=nil;done?() } }
    private func installPlaybackMeter() {
        let envelope = outputEnvelope
        player.installTap(onBus:0,bufferSize:1024,format:nil) { buffer, _ in envelope.append(buffer) }
        playbackTapInstalled = true
    }
    public func stopPlayback() { playToken=UUID();player.stop();outputEnvelope.clear();queued=0;renderedEnd=false;completed=nil;outputConverter=nil;outputInputFormat=nil }
    public func stop() { if let observer {NotificationCenter.default.removeObserver(observer)};observer=nil;tap?.finish();tap=nil;stopPlayback();if playbackTapInstalled {player.removeTap(onBus:0);playbackTapInstalled=false};engine.stop();if tapInstalled{engine.inputNode.removeTap(onBus:0)};tapInstalled=false;started=false }
}

/// A scalar from the local speech player render bus. No audio is retained,
/// captured from other applications, or sent over the plugin transport.
private final class PlaybackEnvelope: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0, updated = 0.0
    var level: Double { lock.lock(); defer { lock.unlock() }; return ProcessInfo.processInfo.systemUptime - updated < 0.3 ? value : 0 }
    func clear() { lock.lock(); value=0; updated=0; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, buffer.frameLength <= 8192, let samples=buffer.floatChannelData?[0] else { return }
        var energy=0.0
        for n in 0..<Int(buffer.frameLength) { let x=Double(samples[n]); if x.isFinite { energy += x*x } }
        let level=min(1,sqrt(energy/Double(buffer.frameLength))*8)
        lock.lock(); value=level; updated=ProcessInfo.processInfo.systemUptime; lock.unlock()
    }
}

private final class ConversationInput: @unchecked Sendable {
    private let lock=NSLock(), converter:AVAudioConverter, feed:MeetingLiveAudioFeed
    private let output = AVAudioFormat(standardFormatWithSampleRate:16000,channels:1)!
    private var enabled=true,active=true,frames=0,level=0.0,last=Date()
    init(format:AVAudioFormat,feed:MeetingLiveAudioFeed) throws { guard format.sampleRate>=8000,format.channelCount>0,format.channelCount<=8,let converter=AVAudioConverter(from:format,to:output) else {throw VoiceProblem.message("No usable conversation input")};self.converter=converter;self.feed=feed }
    var signal:(time:Double,rms:Double,age:Double){lock.lock();defer{lock.unlock()};return(Double(frames)/16000,level,Date().timeIntervalSince(last))}
    func setEnabled(_ enabled:Bool){lock.lock();self.enabled=enabled;lock.unlock()}
    func append(_ input:AVAudioPCMBuffer){lock.lock();defer{lock.unlock()};guard active else{return}
        guard input.frameLength<=8192,let buffer=AVAudioPCMBuffer(pcmFormat:output,frameCapacity:AVAudioFrameCount(Double(input.frameLength)*16000/input.format.sampleRate)+1024) else{feed.fail("Unsupported conversation audio");return}
        var fed=false,error:NSError?;converter.convert(to:buffer,error:&error){_,status in if fed{status.pointee = .noDataNow;return nil};fed=true;status.pointee = .haveData;return input}
        guard error==nil,let samples=buffer.floatChannelData?[0],buffer.frameLength>0 else{return}
        let count=Int(buffer.frameLength);var power=0.0
        for n in 0..<count {power += Double(samples[n]*samples[n]);if !enabled{samples[n]=0}}
        level=enabled ? sqrt(power/Double(count)):0;last=Date();feed.append(buffer,track:"mic",start:Double(frames)/16000);frames+=count
    }
    func finish(){lock.lock();active=false;lock.unlock()}
}
