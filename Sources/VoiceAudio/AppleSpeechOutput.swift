import AVFoundation
import Foundation
import ModuleCore

/// Read-only result for the captured original provider/stop generation. Issue
/// reads consult only captured latches, never a mutable newly selected driver.
public struct SpeechOwnedRetirement: Sendable {
    public let completion: Task<Void, Never>?
    private let capturedIssue: @Sendable () -> String?
    public var issue: String? { capturedIssue() }
    init(completion: Task<Void, Never>?, issue: @escaping @Sendable () -> String?) {
        self.completion = completion; capturedIssue = issue
    }
}

@MainActor public final class AppleSpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    public var engineOutput: ConversationAudio? { didSet { voice2.engineOutput = engineOutput } }
    public var changed: ((SpeechPlayback.Phase, String?) -> Void)?
    private let voice2 = AppleVoice2Renderer()
    private let synthesizer = AVSpeechSynthesizer()
    private var state = SpeechPlayback()
    private var utteranceID: ObjectIdentifier?
    private var regular: AppleOriginalUtterance?
    nonisolated private let callbackIndex = AppleUtteranceCallbacks()
    private var deadline: Task<Void, Never>?
    private var originalStops: [UUID: SpeechOwnedRetirement] = [:]
    private var knownPriorIssue: String?
    public override init() { super.init(); synthesizer.delegate = self
        voice2.started = { [weak self] in guard let self, self.state.started(self.state.token) else { return }; self.changed?(.speaking, nil) }
        voice2.finished = { [weak self] error in
            guard let self, self.state.active else { return }
            if let error { self.stop(); self.changed?(.idle, error) }
            else if self.state.finished(self.state.token) { self.deadline?.cancel(); self.changed?(.finished, nil) }
        }
    }
    public static let voice2Identifier = "com.apple.siri.natural.Simone"
    public func prepareVoice2() throws { try voice2.prepare() }
    @discardableResult public func shutdown() -> Task<Void, Never>? { ownedShutdown().completion }
    public func ownedShutdown() -> SpeechOwnedRetirement {
        stop()
        let worker = voice2.shutdown(), originals = Array(originalStops.values), prior = knownPriorIssue
        let completion: Task<Void, Never>? = worker == nil && originals.isEmpty ? nil : Task {
            await worker?.value
            for original in originals { await original.completion?.value }
        }
        return .init(completion: completion, issue: { prior ?? originals.compactMap(\.issue).first })
    }
    var workerRetirementIsOwned: Bool { voice2.workerRetirementIsOwned || !originalStops.isEmpty }
    public func speakVoice2(_ text: String, delivery: SpeechDelivery) throws {
        try VoiceSession.validate(text); stop(); let token = try state.begin(text)
        do {
            try SpeechSynthesisStartGuard.notifyThenStart(
                isCurrent:{self.state.token==token && self.state.active},
                notify:{self.changed?(.preparing,nil)},
                start:{try self.voice2.speak(text,delivery:delivery)})
            guard state.token==token,state.active else{throw CancellationError()}
            armDeadline(token)
        } catch {
            if state.token==token{stop()}
            throw error
        }
    }
    private func armDeadline(_ token: UUID) {
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, let self, self.state.token == token, self.state.active else { return }
            self.stop(); self.changed?(.idle, "Speech output timed out. Your text is still available.")
        }
    }
    public func speak(_ text: String, voice: AVSpeechSynthesisVoice, delivery: SpeechDelivery) throws {
        try VoiceSession.validate(text); stop()
        let token = try state.begin(text), original = AppleOriginalUtterance()
        regular = original
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.rate = delivery.rate; utterance.pitchMultiplier = delivery.pitch
        let id = ObjectIdentifier(utterance)
        callbackIndex.install(id, original: original)
        utteranceID = engineOutput == nil ? id : nil
        try SpeechSynthesisStartGuard.notifyThenStart(
            isCurrent:{self.state.token==token && self.state.active && self.regular === original && original.admission.isOpen},
            notify:{self.changed?(.preparing,nil)},start:{
        if let engine = self.engineOutput {
            engine.beginPlayback { [weak self] in
                guard let self, self.state.finished(token) else { return }
                self.deadline?.cancel(); self.changed?(.finished, nil)
            }
            original.willStartNative()
            synthesizer.write(utterance) { [weak self] buffer in
                guard let entered = original.admission.enter() else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { entered.finish(); return }
                let isEnd = pcm.frameLength == 0
                if isEnd { original.nativeFinished() }
                let copy = Self.copyPCM(pcm)
                Task { @MainActor in
                    defer { entered.finish() }
                    guard let self, self.state.token == token, self.state.active, let engine = self.engineOutput else { return }
                    do {
                        if isEnd { engine.finishPlayback() }
                        else if let copy { try engine.appendPlayback(copy); if self.state.started(token) { self.changed?(.speaking, nil) } }
                        else { throw VoiceProblem.message("Invalid rendered speech buffer") }
                    } catch {
                        original.failed("rendered-buffer-delivery-failed")
                        self.stop(); self.changed?(.idle, error.localizedDescription)
                    }
                }
            }
        } else { original.willStartNative();self.synthesizer.speak(utterance) }
        })
        guard state.token==token,state.active,regular === original,original.admission.isOpen else{throw CancellationError()}
        armDeadline(token)
    }
    public func stop() {
        let original = regular, originalDeadline = deadline
        let hadActiveRegular = original != nil && state.active
        regular = nil; deadline = nil
        // Seal before state, engine or synthesizer callbacks can re-enter.
        original?.admission.seal()
        callbackIndex.removeAll()
        state.stop(); utteranceID = nil; originalDeadline?.cancel()
        engineOutput?.stopPlayback(); voice2.stop()
        let accepted = synthesizer.stopSpeaking(at: .immediate)
        if hadActiveRegular && original?.nativeStartWasAdmitted == true && !accepted && original?.synthesisFinished != true {
            original?.failed("apple-stop-refused")
        }
        original?.admission.nativeStopReturned()
        if original != nil || originalDeadline != nil {
            let id = UUID()
            let completion = Task {
                await originalDeadline?.value
                await original?.admission.waitForReturn()
            }
            let receipt = SpeechOwnedRetirement(completion: completion, issue: { original?.issue })
            originalStops[id] = receipt
            Task { [weak self] in
                await completion.value
                if let issue = receipt.issue, self?.knownPriorIssue == nil { self?.knownPriorIssue = issue }
                self?.originalStops[id] = nil
            }
        }
        changed?(.idle, nil)
    }
    nonisolated private static func copyPCM(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0, input.frameLength <= 65536,
              let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else { return nil }
        output.frameLength = input.frameLength
        let a = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let b = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        for i in a.indices {
            guard i < b.count, let from = a[i].mData, let to = b[i].mData else { return nil }
            memcpy(to, from, Int(a[i].mDataByteSize))
        }
        return output
    }
    private func event(_ id: ObjectIdentifier, started: Bool) {
        guard utteranceID == id else { return }
        let token = state.token
        if started { if state.started(token) { changed?(.speaking, nil) } }
        else if state.finished(token) { utteranceID = nil; deadline?.cancel(); changed?(.finished, nil) }
    }
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        guard let original = callbackIndex.lookup(id), let entered = original.admission.enter() else { return }
        Task { @MainActor [weak self, utterance] in
            defer { entered.finish() }; self?.event(ObjectIdentifier(utterance), started: true)
        }
    }
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        guard let original = callbackIndex.lookup(id), let entered = original.admission.enter() else { return }
        original.nativeFinished()
        Task { @MainActor [weak self, utterance] in
            defer { entered.finish() }; self?.event(ObjectIdentifier(utterance), started: false)
        }
    }
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        guard let original = callbackIndex.lookup(id), let entered = original.admission.enter() else { return }
        original.nativeFinished()
        Task { @MainActor [weak self, utterance] in
            defer { entered.finish() }
            guard let self, self.utteranceID == ObjectIdentifier(utterance) else { return }
            self.stop()
        }
    }
}
private final class AppleOriginalUtterance: @unchecked Sendable {
    let admission = VoiceAudioCallbackAdmission()
    private let lock = NSLock()
    private var finished = false, nativeAdmitted = false
    private var firstIssue: String?
    var synthesisFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var nativeStartWasAdmitted:Bool{lock.lock();defer{lock.unlock()};return nativeAdmitted}
    func willStartNative(){lock.lock();nativeAdmitted=true;lock.unlock()}
    var issue: String? { lock.lock(); defer { lock.unlock() }; return firstIssue }
    func nativeFinished() { lock.lock(); finished = true; lock.unlock() }
    func failed(_ reason: String) { lock.lock(); if firstIssue == nil { firstIssue = reason }; lock.unlock() }
}
private final class AppleUtteranceCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var originals: [ObjectIdentifier: AppleOriginalUtterance] = [:]
    func install(_ id: ObjectIdentifier, original: AppleOriginalUtterance) { lock.lock(); originals[id] = original; lock.unlock() }
    func lookup(_ id: ObjectIdentifier) -> AppleOriginalUtterance? { lock.lock(); defer { lock.unlock() }; return originals[id] }
    func removeAll() { lock.lock(); originals.removeAll(); lock.unlock() }
}

/// Actual pre-effect fence used by both regular Apple and Voice2 start paths.
/// Tests substitute only the final effect closure, never a native admission.
@MainActor enum SpeechSynthesisStartGuard {
    static func notifyThenStart(isCurrent:()->Bool,notify:()->Void,start:()throws->Void)throws{
        notify()
        guard isCurrent() else{throw CancellationError()}
        try start()
    }
}
