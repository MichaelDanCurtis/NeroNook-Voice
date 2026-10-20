import Foundation
import AVFoundation
import AudioToolbox
import ModuleCore

private final class ReferenceSink: @unchecked Sendable {
    let queue = DispatchQueue(label: "cafe.nero.voice.reference")
    private let slots = DispatchSemaphore(value: 16)
    private let file: AVAudioFile
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
            do { try self.file.write(from: out); self.frames += Int(out.frameLength) } catch { self.failure = error }
        }
    }
    func finish() throws { try queue.sync { active = false; if let failure { throw failure }; guard frames >= 72000 else { throw VoiceProblem.message("Record at least three seconds of speech") } } }
}

/// Explicit 30-second selected-microphone recording only; no ASR or system audio.
@MainActor public final class QwenReferenceRecorder {
    private var engine: AVAudioEngine?, sink: ReferenceSink?, url: URL?
    public init() {}
    public func start(microphone: String?) throws {
        cancel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nero-qwen-reference-"+UUID().uuidString+".wav")
        self.url = url
        let engine = AVAudioEngine(); self.engine = engine
        do {
            guard var device = MicrophoneDeviceService.deviceID(for: microphone), let unit = engine.inputNode.audioUnit else { throw VoiceProblem.message("Choose an available microphone in Voice settings") }
            var current = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let read = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
            if read != noErr || current != device {
                let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device)))
                guard result == noErr else { throw VoiceProblem.message("Cannot select the reference microphone") }
            }
            let format = engine.inputNode.inputFormat(forBus: 0)
            guard (8000...192000).contains(format.sampleRate), (1...8).contains(format.channelCount) else { throw VoiceProblem.message("Unsupported microphone format") }
            let sink = try ReferenceSink(url: url, input: format); self.sink = sink
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
            engine.prepare(); try engine.start()
        } catch { cancel(); throw error }
    }
    public func finish() throws -> URL {
        guard let url, let sink else { throw VoiceProblem.message("No reference recording is running") }
        engine?.stop(); engine?.inputNode.removeTap(onBus: 0); engine = nil
        do { try sink.finish(); self.sink = nil; self.url = nil; return url } catch { cancel(); throw error }
    }
    public func cancel() {
        engine?.stop(); if sink != nil { engine?.inputNode.removeTap(onBus: 0) }; engine = nil
        if let sink { try? sink.finish() }; self.sink = nil
        if let url { try? FileManager.default.removeItem(at: url) }; url = nil
    }
}
