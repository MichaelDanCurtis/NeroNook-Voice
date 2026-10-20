import AVFoundation
import Foundation
import ModuleCore

@MainActor public final class AppleSpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    public var engineOutput: ConversationAudio? { didSet { voice2.engineOutput = engineOutput } }
    public var changed: ((SpeechPlayback.Phase, String?) -> Void)?
    private let voice2 = AppleVoice2Renderer()
    private let synthesizer = AVSpeechSynthesizer()
    private var state = SpeechPlayback()
    private var utteranceID: ObjectIdentifier?
    private var deadline: Task<Void, Never>?
    public override init() { super.init(); synthesizer.delegate = self
        voice2.started = { [weak self] in guard let self, self.state.started(self.state.token) else { return }; self.changed?(.speaking, nil) }
        voice2.finished = { [weak self] error in
            guard let self, self.state.active else { return }
            if let error { self.stop(); self.changed?(.idle, error) }
            else if self.state.finished(self.state.token) { self.deadline?.cancel(); self.changed?(.finished, nil) }
        }
    }
    public static let voice2Identifier = "com.apple.siri.natural.Simone"
    /// Prepare only the local renderer; never opens a microphone or synthesizes.
    public func prepareVoice2() throws { try voice2.prepare() }
    public func shutdown() { stop(); voice2.shutdown() }
    public func speakVoice2(_ text: String, delivery: SpeechDelivery) throws {
        try VoiceSession.validate(text); stop(); let token = try state.begin(text)
        changed?(.preparing, nil)
        do { try voice2.speak(text, delivery: delivery); armDeadline(token) }
        catch { stop(); throw error }
    }
    private func armDeadline(_ token: UUID) {
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, let self, self.state.token == token, self.state.active else { return }
            self.stop(); self.changed?(.idle, "Speech output timed out. Your text is still available.")
        }
    }

    public func speak(_ text: String, voice: AVSpeechSynthesisVoice, delivery: SpeechDelivery) throws {
        try VoiceSession.validate(text)
        stop()
        let token = try state.begin(text)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.rate = delivery.rate; utterance.pitchMultiplier = delivery.pitch
        utteranceID = engineOutput == nil ? ObjectIdentifier(utterance) : nil
        changed?(.preparing, nil)
        if let engine=engineOutput {
            engine.beginPlayback { [weak self] in guard let self,self.state.finished(token) else{return};self.deadline?.cancel();self.changed?(.finished,nil) }
            synthesizer.write(utterance) { [weak self] buffer in
                guard let pcm=buffer as? AVAudioPCMBuffer else{return}
                let isEnd = pcm.frameLength == 0
                let copy=Self.copyPCM(pcm)
                Task { @MainActor in
                    guard let self,self.state.token==token,self.state.active,let engine=self.engineOutput else{return}
                    do {
                        if isEnd {engine.finishPlayback()}
                        else if let copy {try engine.appendPlayback(copy);if self.state.started(token){self.changed?(.speaking,nil)}}
                        else {throw VoiceProblem.message("Invalid rendered speech buffer")}
                    }catch{self.stop();self.changed?(.idle,error.localizedDescription)}
                }
            }
        } else { synthesizer.speak(utterance) }
        armDeadline(token)
    }
    public func stop() {
        state.stop(); utteranceID = nil; deadline?.cancel(); deadline = nil
        engineOutput?.stopPlayback(); voice2.stop(); synthesizer.stopSpeaking(at: .immediate)
        changed?(.idle, nil)
    }
    nonisolated private static func copyPCM(_ input:AVAudioPCMBuffer)->AVAudioPCMBuffer? {
        guard input.frameLength>0,input.frameLength<=65536,let output=AVAudioPCMBuffer(pcmFormat:input.format,frameCapacity:input.frameLength) else{return nil}
        output.frameLength=input.frameLength
        let a=UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:input.audioBufferList)),b=UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        for i in a.indices {guard i<b.count,let from=a[i].mData,let to=b[i].mData else{return nil};memcpy(to,from,Int(a[i].mDataByteSize))}
        return output
    }
    private func event(_ id: ObjectIdentifier, started: Bool) {
        guard utteranceID == id else { return }
        let token = state.token
        if started { if state.started(token) { changed?(.speaking, nil) } }
        else if state.finished(token) {
            utteranceID = nil; deadline?.cancel(); deadline = nil; changed?(.finished, nil)
        }
    }
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self, utterance] in self?.event(ObjectIdentifier(utterance), started: true) }
    }
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self, utterance] in self?.event(ObjectIdentifier(utterance), started: false) }
    }
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self, utterance] in
            guard let self, self.utteranceID == ObjectIdentifier(utterance) else { return }
            self.stop()
        }
    }
}
