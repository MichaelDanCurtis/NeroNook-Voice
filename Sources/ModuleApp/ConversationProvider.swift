import AppKit
import AVFoundation
import Foundation
import ModuleCore
import VoiceAudio
import NookPluginSDK

/// Voice alone owns capture, model lease, endpointing and audible output. The
/// caller receives ephemeral words through its exact reviewed SDK action run.
@MainActor final class ConversationProvider {
    let configuration:VoiceProductConfiguration
    var hasAmbientProductObservers:Bool{!observations.isEmpty}
    var send: ((PluginBusMessage)->Void)?
    var changed: (() -> Void)?
    private(set) var active = false
    private(set) var status = ""
    private var request: UUID?, epoch = UUID()
    private var sequence: UInt64 = 0, inputSequence: UInt64 = 0
    private var duplex = ConversationDuplexState()
    private var mode: String { duplex.mode.rawValue }
    private var listening: Bool { duplex.listening }
    private var playing = false, turn = 0
    private var expressionAdmission = PluginExpressionAdmission()
    private var expressionSegment: PluginExpressionSegment?
    private var gate = ConversationTurn()
    private var interruption = ConversationInterruption()
    private var pendingRecognition: MeetingLiveUpdate?
    private var audio: ConversationAudio?, recognizer: MeetingLiveTranscriber?
    private var speaker: SpeechOutput?
    private var task: Task<Void,Never>?, endpoint: Task<Void,Never>?
    private var preparationObserver: Task<Void, Never>?
    private var preparationID: UUID?
    private var speechRetirement: Task<Void, Never>?
    private var speechRetirementID: UUID?
    // Preparation and captured resource retirement have separate owners.
    // Neither one alone proves process-wide audio quiescence.
    var preparationIsOwned: Bool { task != nil }
    var busy: Bool { active || preparationIsOwned || speechRetirement != nil || !originalControlReturns.isEmpty }
    private let preparationCheckpoint: (@MainActor () async throws -> Void)?
    private var endpointID = UUID()
    private var monitor: Task<Void,Never>?
    private var originalControlReturns: [UUID: Task<Void, Never>] = [:]
    private var originalOutputReceipts: [SpeechOwnedRetirement] = []
    private let ioOutcomes=VoiceOriginalIOOutcomes()
    private var observations: [NSObjectProtocol] = []
    private var started = Date(), heartbeat = Date(), lastMeter = Date()
    private var peak = 0.0, recognized = false
    private weak var preferences: (any ConversationPreferences)?
    init(preparationCheckpoint: (@MainActor () async throws -> Void)? = nil, configuration suppliedConfiguration:VoiceProductConfiguration? = nil) {
        let configuration = suppliedConfiguration ?? .legacy
        self.configuration=configuration
        self.preparationCheckpoint = preparationCheckpoint
        guard configuration.allows(.observation)else{return}
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.stop("Conversation stopped for sleep or lock")}})
        }
    }
    func start(_ id: UUID, values: [String:PluginValue], preferences: any ConversationPreferences, available: Bool) throws {
        try configuration.require(.capture)
        guard !busy,available,!preferences.preloader.busy,!CommandLine.arguments.contains("--protocol-test") else {throw VoiceProblem.message("Finish the current Voice activity before Talk.")}
        guard originalOutputReceipts.allSatisfy({ $0.issue == nil }),ioOutcomes.issue == nil,preferences.preloader.resourceReturnIssue == nil else { throw VoiceProblem.message("The previous speech output could not stop cleanly. Restart Voice before another conversation.") }
        originalOutputReceipts.removeAll()
        try PluginSpeechConversation.action.input.validate(values)
        guard case .string(let requested)=values["mode"] else {throw VoiceProblem.message("Choose a duplex mode")}
        let mode = try PluginSpeechConversation.mode(requested);self.preferences=preferences
        duplex = ConversationDuplexState(mode: mode == "full" ? .full : .half)
        expressionAdmission = .init(); expressionSegment = nil
        active=true;request=id;epoch=UUID();sequence=0;inputSequence=0;turn=0;gate=ConversationTurn(pace:preferences.conversationPace);peak=0;recognized=false
        interruption = ConversationInterruption(sensitivity: preferences.interruptionSensitivity); pendingRecognition = nil
        let token=epoch;started=Date();heartbeat=Date();status="Preparing local conversation…"
        let operation = UUID(); preparationID = operation
        let original = Task{[weak self] in
            guard let self else{return}
            do {
                try requirePreparation(token)
                // Observation/cancellation only. No test supplies permission,
                // readiness, recognition or audio; production defaults to nil.
                try await preparationCheckpoint?()
                try requirePreparation(token)
                let allowed=await AVCaptureDevice.requestAccess(for:.audio)
                try requirePreparation(token)
                guard allowed else{throw VoiceProblem.message("Allow Nero Voice microphone access in System Settings.")}
                try Task.checkCancellation();guard active,epoch==token else{return}
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroASR")
                let onUpdate: (MeetingLiveUpdate) throws -> Void = { [weak self] value in
                    guard let self,self.active,self.epoch==token,self.listening else{return}
                    self.receiveRecognition(value)
                }
                let onFailure: (String) -> Void = { [weak self] error in guard let self,self.active,self.epoch == token else{return};self.stop(error,failed:true) }
                let prepared = preferences.preloader.take(provider:preferences.dictationASR,locale:preferences.locale,helper:helper,update:onUpdate,failure:onFailure)
                // take() publishes synchronously after transferring custody.
                // If that callout retired us, cancel the captured service.
                do { try requirePreparation(token) } catch { prepared?.cancel(); retainSpeechRetirement(prepared?.retirementCompletion(),issue:{[prepared] in prepared?.resourceReturnIssue}); throw error }
                if prepared == nil {
                    let originalPreloader=preferences.preloader
                    let originalPreloadRetirement=ioOutcomes.join(originalPreloader.retirementCompletion(),issue:{originalPreloader.resourceReturnIssue})
                    await originalPreloadRetirement?.value
                    try requirePreparation(token)
                }
                let recognizer=prepared ?? MeetingLiveTranscriber(),audio=ConversationAudio(),speaker=SpeechOutput()
                if prepared != nil { SpeechTiming.mark("speechPreloadUsed") }
                self.recognizer=recognizer;self.audio=audio;self.speaker=speaker;speaker.engineOutput=audio
                if preferences.speechBackend == .qwen { try preferences.qwenOptions.validate(requireVoice:true); try await speaker.prepareQwen(mode:preferences.qwenOptions.mode) }
                else if preferences.voiceID == AppleSpeechOutput.voice2Identifier { try speaker.prepareVoice2() }
                try requirePreparation(token)
                speaker.changed={ [weak self] phase,error in guard let self,self.active,self.epoch==token else{return}
                    if let error{self.stop(error,failed:true);return}
                    if phase == .speaking{if let segment = self.expressionSegment { self.emit("expressionStarted",text:segment.receipt.encoded(),turn:self.turn) };SpeechTiming.mark("playbackStarted",turn:self.turn);self.duplex.phase = .speaking;self.status="Speaking";self.emit("speaking",turn:self.turn)}
                    if phase == .finished{self.interruption.endPlayback(at:self.audio?.signal.time ?? 0);self.playing=false;self.expressionSegment=nil;self.duplex.phase = .thinking;self.emit("played",turn:self.turn)}
                    self.changed?()
                }
                audio.failure={ [weak self] error in guard let self,self.active,self.epoch == token else{return};self.stop(error,failed:true) }
                if prepared == nil {
                    try await recognizer.start(provider:preferences.dictationASR,tracks:["mic"],locale:preferences.locale,
                                               helper:helper,update:onUpdate,failure:onFailure)
                }
                try Task.checkCancellation();guard active,epoch==token else{return}
                try audio.start(microphone:preferences.microphone.isEmpty ? nil:preferences.microphone,full:mode=="full",feed:recognizer.feed)
                for _ in 0..<60 {
                    try Task.checkCancellation();guard active,epoch==token else{return}
                    if audio.signal.time>0{break};try await Task.sleep(for:.milliseconds(50))
                }
                guard audio.signal.time>0 else{throw VoiceProblem.message("The microphone did not deliver audio")}
                emit("expressionCapabilities",text:PluginExpressionCapability().encoded())
                try requirePreparation(token); emitControls(); try requirePreparation(token)
                SpeechTiming.mark("voiceReady");duplex.phase = .listening;status="Listening · \(preferences.dictationASR.title)"
                emit("ready",text:status,mode:mode);try requirePreparation(token);changed?()
                try requirePreparation(token)
                monitor=Task{[weak self] in while !Task.isCancelled{try? await Task.sleep(for:.milliseconds(100));guard let self,self.active,self.epoch==token else{return};self.tick()} }
            }catch{if epoch==token{stop(error.localizedDescription,failed:true)}}
        }
        // Publish ownership before any subscriber can stop/re-enter. The
        // observer awaits this exact task, even when Stop retires its epoch.
        task = original
        preparationObserver = Task { [weak self] in
            await original.value
            guard let self, self.preparationID == operation else { return }
            self.task = nil; self.preparationObserver = nil; self.preparationID = nil
            self.changed?()
        }
        changed?()
    }
    private func requirePreparation(_ token: UUID) throws {
        try Task.checkCancellation()
        guard active, epoch == token else { throw CancellationError() }
        guard ioOutcomes.issue == nil else{throw VoiceProblem.message("Previous local speech I/O needs recovery before Talk can start.")}
    }
    // Synchronous read-only capture, so callers can retain this exact observer
    // before releasing a hold or making any reentrant callout. Awaiting it joins
    // its original preparation task; this does not manufacture readiness.
    func preparationCompletion() -> Task<Void, Never>? { preparationObserver }
    func speechRetirementCompletion() -> Task<Void, Never>? { speechRetirement }
    // Retain the actual output/live-recognizer retirement before Stop notifies
    // any caller. Direct dictation and other resource owners remain separate.
    func retainSpeechRetirement(_ original:Task<Void,Never>?,issue:@escaping @MainActor ()->String?={nil}){
        guard let completion=ioOutcomes.join(original,issue:issue)else{return}
        let prior = speechRetirement, id = UUID(); speechRetirementID = id
        speechRetirement = Task { [weak self] in
            await prior?.value; await completion.value
            guard let self, self.speechRetirementID == id else { return }
            self.speechRetirement = nil; self.speechRetirementID = nil
            self.changed?()
        }
    }
    private func tick(){
        guard let audio else{return};let signal=audio.signal
        if Date().timeIntervalSince(started)>7200{stop("Two-hour conversation limit reached. Press Talk for a new session.");return}
        if signal.age>3{stop("The microphone stopped responding. Press Talk to reconnect.",failed:true);return}
        if Date().timeIntervalSince(heartbeat)>10,let request{heartbeat=Date();send?(.init(.update,requestID:request,update:.init(.running,message:status)))}
        peak=max(peak,signal.rms)
        if Date().timeIntervalSince(lastMeter)>0.2{lastMeter=Date();var values=PluginSpeechConversation.values("meter");
            if listening {values["text"] = .string(!recognized && Date().timeIntervalSince(started)>12 && peak<0.001 ? "No microphone sound detected · check the microphone in Voice settings" : "Listening · \(preferences?.dictationASR.title ?? "Local speech")")};values["level"] = .number(min(1,signal.rms*15));emit(values)
            var output=PluginSpeechConversation.values("playbackMeter",turn:turn)
            output["level"] = .number(playing && duplex.phase == .speaking ? audio.playbackLevel : 0);emit(output)}
        let sensitivity = preferences?.interruptionSensitivity ?? 50
        if sensitivity != interruption.sensitivity { interruption.sensitivity = sensitivity; emitControls() }
        interruption.audio(rms: signal.rms, playbackLevel: audio.playbackLevel, through: signal.time, allowed: listening)
        if let pending = pendingRecognition {
            if !interruption.protects(at: signal.time) { pendingRecognition = nil }
            else if interruption.decision(text: pending.text, start: pending.start, end: pending.end, now: signal.time) == .accept {
                pendingRecognition = nil; acceptRecognition(pending)
            }
        }
        if !interruption.protects(at: signal.time), gate.audio(rms:signal.rms,through:signal.time,allowed:listening){
            expressionSegment=nil;speaker?.stop();playing=false;duplex.phase = .listening;status="Listening";emit("speechStarted",turn:turn);changed?()
        }
        guard listening,endpoint==nil,gate.canCommit(at:signal.time) else{return}
        finishTurn()
    }
    private func receiveRecognition(_ value: MeetingLiveUpdate) {
        guard value.text.utf8.count <= 2048 else { stop("Keep a spoken turn under 2 KB; pause between turns.", failed: true); return }
        let time = audio?.signal.time ?? 0
        switch interruption.decision(text: value.text, start: value.start, end: value.end, now: time) {
        case .echo: pendingRecognition = nil; return
        case .hold: pendingRecognition = value; return
        case .accept: pendingRecognition = nil; acceptRecognition(value)
        }
    }
    private func acceptRecognition(_ value: MeetingLiveUpdate) {
        guard active, listening else { return }
        do {
            let time = audio?.signal.time ?? 0, wasSpeaking = gate.speaking
            try gate.receive(value, now: time)
            if !wasSpeaking && gate.speaking {
                interruption.admitUser(at: time); expressionSegment = nil; speaker?.stop(); playing = false
                duplex.phase = .listening; emit("speechStarted", turn: turn)
            }
            if !gate.text.isEmpty { recognized = true; emit("partial", text: gate.text) }
        } catch { stop(error.localizedDescription, failed: true) }
    }
    private func emitControls() {
        guard let preferences else { return }
        let devices = MicrophoneDeviceService.inputDevices()
        let device = devices.first { preferences.microphone.isEmpty ? $0.isDefault : $0.id == preferences.microphone }
        let controls = PluginSpeechConversationControls(microphone: device?.name ?? "Selected microphone", recognition: preferences.dictationASR.title, sensitivity: preferences.interruptionSensitivity)
        if let text = try? controls.encoded() { emit("controls", text: text) }
    }
    private func retainControlReturn(_ original: Task<Void, Never>?) {
        guard let original else { return }
        let id = UUID()
        originalControlReturns[id] = original
        Task { [weak self] in
            await original.value
            self?.originalControlReturns[id] = nil
            self?.changed?()
        }
    }
    private func cancelEndpoint() {
        endpointID = UUID()
        let original = endpoint; endpoint = nil
        retainControlReturn(original); original?.cancel()
    }
    private func finishTurn(typed: String? = nil) {
        SpeechTiming.mark("endpoint",turn:turn+1,milliseconds:1000*((audio?.signal.time ?? 0)-gate.lastVoice))
        cancelEndpoint()
        let commitStarted=ProcessInfo.processInfo.systemUptime
        let token = epoch, id = UUID(); endpointID = id
        endpoint = Task { [weak self] in
            guard let self else { return }
            defer { if self.endpointID == id { self.endpoint = nil } }
            do {
                guard let recognizer = self.recognizer else { throw VoiceProblem.message("Speech is not ready") }
                try await recognizer.commit { [weak self] through in
                    guard let self,self.active,self.epoch == token,self.endpointID == id else { return }
                    // This callback runs inside the ordered ack parser. Never
                    // wait for a continuation then retire through a later
                    // capture clock: newer PCM may already be queued.
                    let spoken = self.gate.commit(through: through)
                    guard typed != nil || self.listening else { return }
                    let text = (typed ?? spoken).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    // If the idle renderer retired during a long user turn,
                    // restart it while the Agent is preparing its response.
                    if self.preferences?.speechBackend == .apple && self.preferences?.voiceID == AppleSpeechOutput.voice2Identifier { try? self.speaker?.prepareVoice2() }
                    self.turn += 1; SpeechTiming.mark("committed",turn:self.turn,milliseconds:1000*(ProcessInfo.processInfo.systemUptime-commitStarted)); self.duplex.phase = .thinking; self.audio?.recognition(self.listening)
                    self.status = "Thinking"; self.emit("final",text:text,turn:self.turn); self.changed?()
                }
            } catch {
                if !Task.isCancelled,self.active,self.epoch == token,self.endpointID == id { self.stop(error.localizedDescription,failed:true) }
            }
        }
    }
    func receive(_ message:PluginBusMessage) throws {
        guard active,message.requestID==request,let frame=message.frame,frame.sequence==inputSequence else{throw VoiceProblem.message("Stale conversation command")}
        try frame.validate(PluginSpeechConversation.input);inputSequence += 1
        guard case .string(let kind)=frame.values["kind"] else{throw VoiceProblem.message("Missing conversation command")}
        let target:Int
        if case .number(let value)=frame.values["turn"] {
            guard value.isFinite, value.rounded() == value else { throw VoiceProblem.message("Invalid conversation turn") }; target = Int(value)
        } else { target = turn }
        if target<turn{return};guard target==turn else{throw VoiceProblem.message("Unknown conversation turn")}
        switch kind {
        case "text":
            guard case .string(let text)=frame.values["text"],!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw VoiceProblem.message("Enter a message")}
            interruption.admitUser(at: audio?.signal.time ?? 0); pendingRecognition = nil
            expressionSegment=nil;speaker?.stop();playing=false
            emit("speechStarted",turn:turn);duplex.phase = .thinking;audio?.recognition(listening)
            status="Thinking";finishTurn(typed:text)
        case "speak", "speakExpression":
            guard !playing,let preferences,let speaker,case .string(let payload)=frame.values["text"] else{throw VoiceProblem.message("Speech output is busy or empty")}
            let text: String
            let segment: PluginExpressionSegment?
            if kind == "speakExpression" {
                let parsed = try PluginExpressionSegment.decode(payload)
                guard let request else { throw VoiceProblem.message("Voice conversation ended") }
                try expressionAdmission.admit(parsed, session:request, turn:turn); segment = parsed; text = parsed.text
            } else { segment = nil; text = payload }
            guard !text.isEmpty else { throw VoiceProblem.message("Speech output is empty") }
            // Admission re-reads the selected runtime; a cue never selects one.
            let resolved = SpeechExpression.resolve(segment?.cue, backend:preferences.speechBackend, delivery:preferences.speechDelivery, options:preferences.qwenOptions)
            SpeechTiming.mark("speakReceived",turn:turn)
            interruption.beginPlayback(text, at: audio?.signal.time ?? 0);pendingRecognition = nil
            expressionSegment=segment;playing=true;duplex.phase = .speaking;audio?.recognition(listening);status="Preparing speech…"
            try speaker.speak(text, backend:preferences.speechBackend, voiceID:preferences.voiceID,
                              appleVoice:preferences.selectedSpeechVoice, qwenSpeaker:preferences.qwenSpeaker,
                              locale:preferences.locale, delivery:resolved.delivery, qwenOptions:resolved.options)
        case "sensitivity":
            guard case .string(let value)=frame.values["text"], let number=Int(value), (0...100).contains(number), let preferences else { throw VoiceProblem.message("Choose an interruption sensitivity from 0 to 100.") }
            preferences.interruptionSensitivity=number;interruption.sensitivity=number;interruption.resetEvidence();pendingRecognition=nil;emitControls()
        case "listen":duplex.phase = .listening;audio?.recognition(listening);status="Listening";emit("listening",turn:turn)
        case "interrupt":interruption.endPlayback(at:audio?.signal.time ?? 0);expressionSegment=nil;speaker?.stop();playing=false;duplex.phase = .thinking;audio?.recognition(listening)
        case "mode":
            guard case .string(let value)=frame.values["mode"] else{throw VoiceProblem.message("Choose a duplex mode")}
            let next=try PluginSpeechConversation.mode(value)
            if next=="full",audio?.echoControl != true{emit("mode",text:"Full duplex echo control is unavailable on this route. Half duplex remains active.",mode:mode);return}
            duplex.mode = next == "full" ? .full : .half
            if !listening { gate.discard(through:audio?.signal.time ?? 0);pendingRecognition=nil;interruption.resetEvidence() }
            audio?.recognition(listening);emit("mode",mode:mode)
        default:throw VoiceProblem.message("Unknown conversation command")
        };changed?()
    }
    private func emit(_ kind:String,text:String?=nil,mode:String?=nil,turn:Int?=nil){emit(PluginSpeechConversation.values(kind,text:text,mode:mode,turn:turn))}
    private func emit(_ values:[String:PluginValue]){
        guard let request,active else{return};let frame=PluginRunFrame(sequence:sequence,values:values)
        guard (try? frame.validate(PluginSpeechConversation.output)) != nil else{stop("Conversation frame exceeded its limit",failed:true);return}
        sequence += 1;send?(.init(.stream,requestID:request,frame:frame))
    }
    func stop(_ message:String="Conversation stopped",failed:Bool=false){
        let old=request;request=nil;active=false;epoch=UUID();task?.cancel();cancelEndpoint();let originalMonitor=monitor;monitor=nil;retainControlReturn(originalMonitor);originalMonitor?.cancel();duplex.phase = .closed
        speaker?.changed=nil;let originalReceipt=speaker?.ownedShutdown();speaker=nil
        if let originalReceipt { originalOutputReceipts.append(originalReceipt);retainSpeechRetirement(originalReceipt.completion) }
        let originalAudio=audio;audio=nil;retainControlReturn(originalAudio?.stopAndWait());let originalRecognizer=recognizer;recognizer=nil;originalRecognizer?.cancel();retainSpeechRetirement(originalRecognizer?.retirementCompletion(),issue:{[originalRecognizer] in originalRecognizer?.resourceReturnIssue});playing=false;expressionSegment=nil;expressionAdmission = .init();gate=ConversationTurn();interruption=ConversationInterruption();pendingRecognition=nil;status=message;changed?()
        if let old{send?(.init(.update,requestID:old,update:.init(failed ? .failed:.cancelled,message:String(message.prefix(280)))))}
    }
    @discardableResult func sharedRetirement() async -> Bool {
        let originalPreparation = task, originalObserver = preparationObserver
        let originalControls = Array(originalControlReturns.values)
        await originalPreparation?.value
        await originalObserver?.value
        for original in originalControls { await original.value }
        // Cancelled preparation can append its real recognizer/output cleanup
        // before returning; capture that resulting original tail after the join.
        let originalSpeech = speechRetirement
        await originalSpeech?.value
        let issues = originalOutputReceipts.compactMap(\.issue)
        if issues.isEmpty { originalOutputReceipts.removeAll() }
        return issues.isEmpty && ioOutcomes.issue == nil
    }
    func cancel(_ id:UUID){if id==request{stop()}}
}
