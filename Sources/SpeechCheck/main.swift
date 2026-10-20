import Foundation
import AVFoundation
import VoiceAudio
import ModuleCore
@main struct Check {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--avatar-envelope-check") || CommandLine.arguments.contains("--avatar-conversation-envelope-check") {
            let conversation = CommandLine.arguments.contains("--avatar-conversation-envelope-check")
            if conversation && AVCaptureDevice.authorizationStatus(for:.audio) != .authorized {
                print("No existing microphone permission for the conversation-output diagnostic; no prompt requested");exit(2)
            }
            do {
                let audio=ConversationAudio(), speech=AppleSpeechOutput()
                let feed=MeetingLiveAudioFeed()
                let drain=Task {for try await packet in feed.stream{feed.consumed(packet)}}
                defer { speech.shutdown(); audio.stop(); feed.finish(); drain.cancel() }
                if conversation { try audio.start(microphone:nil,full:true,feed:feed) }
                else { try audio.startOutput() }
                speech.engineOutput=audio
                var finished=false, fault="", peak=0.0, samples=0
                speech.changed={phase,error in if phase == .finished {finished=true}; if let error {fault=error}}
                guard let voice=AVSpeechSynthesisVoice(language:"en-US") else {throw VoiceProblem.message("No local English speech voice")}
                try speech.speak("Nero and Ember follow the words I speak.",voice:voice,delivery:.natural)
                let start=ProcessInfo.processInfo.systemUptime
                while !finished && fault.isEmpty && ProcessInfo.processInfo.systemUptime-start<20 {
                    peak=max(peak,audio.playbackLevel);samples += 1
                    try await Task.sleep(for:.milliseconds(50))
                }
                speech.stop();let stopped=audio.playbackLevel
                guard finished,fault.isEmpty,peak>0.02,stopped==0 else {throw VoiceProblem.message("Speech envelope failed: peak=\(peak), stopped=\(stopped), \(fault)")}
                print("PASS \(conversation ? "full-duplex" : "output-only") Apple speech: measured playback envelope peak=\(peak), samples=\(samples), stop=\(stopped); no account, model download or saved audio")
            } catch {print("Avatar envelope check failed: \(error.localizedDescription)");exit(1)}
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--qwen-playback-check"), CommandLine.arguments.count > index+1 {
            do {
                guard let id = UUID(uuidString: CommandLine.arguments[index+1]) else { throw VoiceProblem.message("Choose a synthetic test reference") }
                var options = QwenOptions(); options.mode = .clone; options.cloneID = id
                let speaker = SpeechOutput(); defer { speaker.shutdown() }
                var completed = 0, began = 0, fault = ""
                speaker.changed = { phase, error in if let error { fault = error }; if phase == .speaking { began += 1 }; if phase == .finished { completed += 1 } }
                func say(_ text: String) throws { try speaker.speak(text, backend: .qwen, voiceID: "", appleVoice: nil, qwenSpeaker: .serena, locale: "en-US", delivery: .natural, qwenOptions: options) }
                try await speaker.prepareQwen(mode: .clone)
                try say("The cloned voice is playing through Nero’s local speech output.")
                for _ in 0..<600 { if completed == 1 || !fault.isEmpty { break }; try await Task.sleep(for: .milliseconds(50)) }
                guard fault.isEmpty, completed == 1 else { throw VoiceProblem.message(fault.isEmpty ? "Qwen playback did not complete" : fault) }
                try say(String(repeating: "This is a cancellation check. ", count: 20))
                for _ in 0..<300 { if began >= 2 || !fault.isEmpty { break }; try await Task.sleep(for: .milliseconds(50)) }
                guard fault.isEmpty, began >= 2 else { throw VoiceProblem.message("Second Qwen playback did not start") }
                speaker.stop(); try await Task.sleep(for: .seconds(1)); guard completed == 1 else { throw VoiceProblem.message("Retired Qwen output resumed") }
                try say("The cloned voice recovered after Stop.")
                for _ in 0..<600 { if completed == 2 || !fault.isEmpty { break }; try await Task.sleep(for: .milliseconds(50)) }
                guard fault.isEmpty, completed == 2 else { throw VoiceProblem.message(fault.isEmpty ? "Qwen did not recover" : fault) }
                print("PASS: actual cloned output-only playback completed, Stop did not resume, next playback recovered; no microphone or hosted inference; starts=\(began), completed=\(completed)")
            } catch { print("Qwen playback check failed: \(error.localizedDescription)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--conversation-level-check") {
            guard AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { print("No existing microphone permission for this diagnostic; no prompt requested");exit(2) }
            do {
                let audio=ConversationAudio(),feed=MeetingLiveAudioFeed()
                let drain=Task {for try await packet in feed.stream{feed.consumed(packet)}}
                defer {audio.stop();feed.finish();drain.cancel()}
                try audio.start(microphone:"BuiltInMicrophoneDevice",full:true,feed:feed)
                var peak=0.0
                for _ in 0..<30{try await Task.sleep(for:.milliseconds(100));peak=max(peak,audio.signal.rms)}
                print("Conversation capture metadata only: framesSeconds=\(audio.signal.time), peakRMS=\(peak), echoControl=\(audio.echoControl)")
                guard audio.signal.time>1,peak>0 else{throw VoiceProblem.message("Conversation capture remained silent")}
            } catch {print("Capture diagnostic failed: \(error.localizedDescription)");exit(1)}
            return
        }
        if CommandLine.arguments.contains("--conversation-playback-check") {
            do {
                let engine = ConversationAudio(), speaker = AppleSpeechOutput()
                try engine.startOutput();speaker.engineOutput=engine
                defer {speaker.stop();engine.stop()}
                var finished=0, started=0, fault="", speechRequested=0.0
                var starts:[Double]=[]
                speaker.changed={phase,error in if let error{fault=error};if phase == .speaking {started += 1;starts.append(ProcessInfo.processInfo.systemUptime-speechRequested)};if phase == .finished {finished += 1}}
                let begin=ProcessInfo.processInfo.systemUptime
                for (n,text) in ["This is Nero's local voice playback check.","The second sentence follows the first."].enumerated() {
                    speechRequested=ProcessInfo.processInfo.systemUptime
                    if CommandLine.arguments.contains("--voice2") {try speaker.speakVoice2(text,delivery:.warm)}
                    else {try speaker.speak(text,voice:AVSpeechSynthesisVoice(language:"en-US")!,delivery:.warm)}
                    for _ in 0..<400 {if finished==n+1 || !fault.isEmpty{break};try await Task.sleep(for:.milliseconds(50))}
                    guard fault.isEmpty,finished==n+1 else{throw VoiceProblem.message(fault.isEmpty ? "Speech playback did not drain":fault)}
                }
                let cancelledText="This deliberately long sentence should be interrupted before it finishes speaking and it should never resume after cancellation."
                if CommandLine.arguments.contains("--voice2") {try speaker.speakVoice2(cancelledText,delivery:.warm)}
                else {try speaker.speak(cancelledText,voice:AVSpeechSynthesisVoice(language:"en-US")!,delivery:.warm)}
                try await Task.sleep(for:.milliseconds(300));speaker.stop();let before=finished
                try await Task.sleep(for:.seconds(1));guard finished==before else{throw VoiceProblem.message("Cancelled playback finished a retired turn")}
                speechRequested=ProcessInfo.processInfo.systemUptime
                if CommandLine.arguments.contains("--voice2") {try speaker.speakVoice2("Playback has recovered.",delivery:.warm)}
                else {try speaker.speak("Playback has recovered.",voice:AVSpeechSynthesisVoice(language:"en-US")!,delivery:.warm)}
                for _ in 0..<400 {if finished==before+1 || !fault.isEmpty{break};try await Task.sleep(for:.milliseconds(50))}
                guard fault.isEmpty,finished==before+1 else{throw VoiceProblem.message("Playback did not recover after Stop")}
                speaker.shutdown()
                print("PASS: two scheduled chunks drained, cancelled render never resumed, next playback recovered; output only, no microphone/account; started=\(started), completed=\(finished), startDelays=\(starts), seconds=\(ProcessInfo.processInfo.systemUptime-begin)")
            }catch {print("Playback check failed: \(error.localizedDescription)");exit(1)}
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--conversation-file-check"), CommandLine.arguments.count > index + 1 {
            do {
                let args = CommandLine.arguments
                func option(_ name:String)->String? { args.firstIndex(of:name).flatMap { args.count > $0+1 ? args[$0+1] : nil } }
                let provider = MeetingASRProvider(rawValue:option("--provider") ?? "apple") ?? .apple
                let file = try AVAudioFile(forReading:URL(fileURLWithPath:args[index+1]))
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, file.length <= 60*16000 else { throw VoiceProblem.message("Use an authored 16 kHz mono fixture under one minute") }
                var service = MeetingLiveTranscriber(); defer { service.cancel() }
                let preload = SpeechPreloader(); defer { preload.release() }
                var preloadedSeconds = 0.0, acquireSeconds = 0.0
                var gate = ConversationTurn(pace:args.contains("--quick") ? .quick:.balanced), clock = 0.0, issue = "", partials = 0
                var lastLoud=0.0, lastUpdateEnd=0.0
                let preparing=ProcessInfo.processInfo.systemUptime
                var turns: [[String:Any]] = []
                let helper = URL(fileURLWithPath:option("--helper") ?? "")
                let onUpdate: (MeetingLiveUpdate) throws -> Void = { value in
                    try gate.receive(value,now:clock); partials += 1;lastUpdateEnd=value.end
                }
                let onFailure: (String) -> Void = { issue = $0 }
                if args.contains("--preload") {
                    try await preload.prepare(provider:provider,locale:"en-US",helper:helper)
                    preloadedSeconds = ProcessInfo.processInfo.systemUptime-preparing
                    let taking = ProcessInfo.processInfo.systemUptime
                    guard let prepared = preload.take(provider:provider,locale:"en-US",helper:helper,update:onUpdate,failure:onFailure) else { throw VoiceProblem.message("Prepared model was not reusable") }
                    service = prepared; acquireSeconds = ProcessInfo.processInfo.systemUptime-taking
                } else {
                    try await service.start(provider:provider,tracks:["mic"],locale:"en-US",helper:helper,update:onUpdate,failure:onFailure)
                }
                let feeding=ProcessInfo.processInfo.systemUptime
                while file.framePosition < file.length {
                    let start=Double(file.framePosition)/16000, pcm=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:1600)!
                    try file.read(into:pcm,frameCount:1600); clock=start+Double(pcm.frameLength)/16000
                    let samples=pcm.floatChannelData![0]; var power=0.0
                    for n in 0..<Int(pcm.frameLength) { power += Double(samples[n]*samples[n]) }
                    let rms=sqrt(power/Double(pcm.frameLength))
                    if rms>0.008 {lastLoud=clock}
                    _ = gate.audio(rms:rms,through:clock,allowed:true)
                    service.feed.append(pcm,track:"mic",start:start)
                    try await Task.sleep(for:.milliseconds(100)); if !issue.isEmpty {throw VoiceProblem.message(issue)}
                    if gate.canCommit(at:clock) {
                        let endpoint=ProcessInfo.processInfo.systemUptime, endpointClock=clock
                        let lastVoice=lastLoud, updateEnd=lastUpdateEnd
                        try await service.commit { through in
                            turns.append(["text":gate.commit(through:through),"through":through,
                                "lastLoudCaptureSeconds":lastVoice,"lastASRUpdateEnd":updateEnd,
                                "endpointCaptureSeconds":endpointClock,"endpointAfterVoiceSeconds":endpointClock-lastVoice,
                                "commitSeconds":ProcessInfo.processInfo.systemUptime-endpoint,
                                "endpointWallSeconds":endpoint-feeding])
                        }
                    }
                }
                try await service.finish()
                if !gate.text.isEmpty {turns.append(["text":gate.commit(through:clock),"through":clock])}
                let receipt:[String:Any] = ["scope":"Authored file only; no microphone or cloud", "provider":provider.rawValue,"updates":partials,"turns":turns,"prepareSeconds":feeding-preparing,"preloadPrepareSeconds":preloadedSeconds,"preloadAcquireSeconds":acquireSeconds]
                print(String(decoding:try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
                guard turns.count >= 2, partials > 1, turns.allSatisfy({ !($0["text"] as! String).isEmpty }) else { throw VoiceProblem.message("Two distinct file-fed conversation turns were not established") }
            } catch { print("Conversation fixture failed: \(error.localizedDescription)");exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--speaker-live-check"), CommandLine.arguments.count > index + 1 {
            do {
                try await SpeakerRuntime.prepare()
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[index+1]))
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, file.length <= 120*16000 else { throw VoiceProblem.message("Use a short 16 kHz mono fixture") }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Nero-Speaker-Check-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let store = try MeetingStore(root: root), audio = MeetingLiveTranscriber(), speakers = MeetingLiveSpeakerAnalyzer()
                var words = MeetingLiveState(), identities = MeetingLiveSpeakers(), transcript = MeetingTranscript(locale: "en-US")
                let epoch = try words.begin(tracks: ["mic", "system"], offset: 0), speakerEpoch = identities.epoch
                var fault = "", updates = 0
                try await speakers.start { track, spans, through in
                    try identities.receive(track: track, spans: spans, through: through, epoch: speakerEpoch)
                    transcript = try identities.applying(to: transcript); updates += 1
                } failure: { fault = $0 }
                try await audio.start(provider: .apple, tracks: ["mic", "system"], locale: "en-US", helper: URL(fileURLWithPath: "/unused")) { value in
                    if try words.receive(value, epoch: epoch) { transcript.utterances = words.settled; transcript = try identities.applying(to: transcript) }
                } failure: { fault = $0 }
                let meeting = Meeting(title: "Authored two-speaker fixture", source: "all", microphone: true)
                let writer = try MeetingAudioWriter(store: store, meeting: meeting, liveFeed: audio.feed, speakerFeed: speakers.feed)
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let start = Double(file.framePosition)/16000
                    let block = AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:1600)!
                    try file.read(into:block,frameCount:1600)
                    writer.append(block,track:"mic",start:start);writer.append(block,track:"system",start:start+0.25)
                    try await Task.sleep(for:.milliseconds(100))
                    if !fault.isEmpty { throw VoiceProblem.message(fault) }
                }
                let saved = try await writer.finish(state:"saved")
                try await audio.finish();try await speakers.finish();transcript = try identities.applying(to:transcript,final:true)
                let counts = Dictionary(uniqueKeysWithValues:["mic","system"].map { track in (track,Set(transcript.utterances.filter{$0.track==track}.compactMap(\.speaker)).count) })
                let receipt:[String:Any] = ["scope":"Authored synthetic file only; no microphone/system capture", "seconds":saved.duration,"speakerUpdates":updates,"speakersPerTrack":counts,"wordAlignedUtterances":words.settled.filter{$0.words?.isEmpty==false}.count,"utterances":transcript.utterances.map{["start":$0.start,"end":$0.end,"track":$0.track,"speaker":$0.speaker ?? "unknown","text":$0.text] as [String:Any]}]
                print(String(decoding:try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
                guard updates > 1, counts.values.allSatisfy({$0>=2}) else { throw VoiceProblem.message("The fixture did not establish two speakers within each source") }
            } catch { print("Speaker live fixture failed: \(error.localizedDescription)"); exit(1) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--live-meeting"), CommandLine.arguments.count > index + 1 {
            do {
                let arguments = CommandLine.arguments
                func option(_ key: String) -> String? { arguments.firstIndex(of: key).flatMap { arguments.count > $0+1 ? arguments[$0+1] : nil } }
                let provider = MeetingASRProvider(rawValue: option("--provider") ?? "apple") ?? .apple
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[index+1]))
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, file.length <= 60*16000 else { throw VoiceProblem.message("Synthetic fixture must be 16 kHz mono, at most one minute") }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("NeroVoice-LiveCheck-"+UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let store = try MeetingStore(root: root), service = MeetingLiveTranscriber()
                defer { service.cancel() }
                var state = MeetingLiveState(), partials = 0, liveFinals = 0, issue: String?
                let epoch = try state.begin(tracks: ["mic", "system"], offset: 2)
                var transcript = MeetingTranscript(locale: "en-US", provider: provider)
                var catchup: MeetingNotebook?, catchTask: Task<MeetingNotebook, Error>?, catchWindow: MeetingCatchUpWindow?
                let cancelAt = option("--cancel-after").flatMap(Double.init)
                var cancelled = false
                let started = ProcessInfo.processInfo.systemUptime
                try await service.start(provider: provider, tracks: ["mic", "system"], locale: "en-US", helper: URL(fileURLWithPath: option("--helper") ?? "")) { value in
                    let final = try state.receive(value, epoch: epoch)
                    if value.final && final { liveFinals += 1; transcript.utterances = state.settled }
                    if !value.final { partials += 1 }
                } failure: { issue = $0 }
                let meeting = Meeting(title: "Synthetic live check", source: "all", microphone: true)
                let writer = try MeetingAudioWriter(store: store, meeting: meeting, liveFeed: service.feed)
                let inputFrames = file.length
                while file.framePosition < file.length {
                    let offset = file.framePosition
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!
                    try file.read(into: buffer, frameCount: 1600)
                    writer.append(buffer, track: "mic", start: 2+Double(offset)/16000)
                    writer.append(buffer, track: "system", start: 2.25+Double(offset)/16000)
                    if let cancelAt, !cancelled, Double(offset)/16000 >= cancelAt { service.cancel(); state.retire(); cancelled = true }
                    if arguments.contains("--catchup"), catchTask == nil, Double(offset) / Double(file.length) >= 0.8, !transcript.utterances.isEmpty {
                        let end = transcript.utterances.map(\.end).max()!
                        let window = try MeetingCatchUpWindow(meetingID: meeting.id, transcript: transcript, through: end)
                        catchWindow = window
                        catchTask = Task { try await MeetingSummarizer.catchUp(window) }
                    }
                    try await Task.sleep(for: .milliseconds(100)); if let issue { throw VoiceProblem.message(issue) }
                }
                let beforeStop = liveFinals, saved = try await writer.finish(state: "saved")
                if !cancelled { try await service.finish() }; if let issue { throw VoiceProblem.message(issue) }
                if let catchTask { catchup = try await catchTask.value }
                try store.saveLiveTranscript(transcript, id: saved.id, provider: provider)
                let storedFrames = try saved.chunks.reduce(Int64(0)) { $0 + (try AVAudioFile(forReading: store.audio($1, meeting: saved))).length }
                guard !state.settled.isEmpty, Set(state.settled.map(\.track)) == ["mic", "system"], beforeStop > 0,
                      storedFrames == 2*inputFrames, state.settled.allSatisfy({ $0.start >= 2 && $0.end <= saved.duration+1 }) else { throw VoiceProblem.message("Live fixture did not satisfy transcript/audio/timestamp checks") }
                let receipt: [String: Any] = ["provider": provider.rawValue, "elapsedSeconds": ProcessInfo.processInfo.systemUptime-started,
                    "partialUpdates": partials, "settledBeforeStop": beforeStop, "settledAfterStop": state.settled.count, "cancelledLiveWhileAudioContinued": cancelled,
                    "savedFramesMatch": storedFrames == 2*inputFrames, "tracks": Array(Set(state.settled.map(\.track))).sorted(),
                    "lines": state.settled.map { ["track": $0.track, "start": $0.start, "end": $0.end, "text": $0.text] as [String: Any] },
                    "catchupWhileRecording": catchup.map { ["summary": $0.summary, "decisions": $0.decisions, "actions": $0.actions] } ?? [:],
                    "catchupSnapshotEnd": catchWindow?.end ?? 0, "catchupDigestMatchesSnapshot": catchWindow != nil && catchup?.sourceDigest == catchWindow?.digest,
                    "scope": "file-fed synthetic audio; no microphone/system capture"]
                print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            } catch { print("Live meeting fixture failed: \(error.localizedDescription)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--summary-check") {
            do {
                var transcript = MeetingTranscript(locale: "en-US")
                transcript.names = ["mic-0": "Alex", "mic-1": "Jordan"]
                var decision = MeetingUtterance(start: 0, end: 8, track: "mic", text: "We agreed to launch the website on Friday.")
                decision.speaker = "mic-0"
                var first = MeetingUtterance(start: 8, end: 16, track: "mic", text: "I am Alex. I will send the draft on Thursday.")
                first.speaker = "mic-0"
                var second = MeetingUtterance(start: 16, end: 24, track: "mic", text: "I am Jordan. I will review that draft before the Friday launch.")
                second.speaker = "mic-1"
                transcript.utterances = [decision, first, second]
                let start = ProcessInfo.processInfo.systemUptime
                let notes = try await MeetingSummarizer.draft(transcript, meetingID: UUID()) { _ in }
                try notes.validate()
                let facts = notes.searchableText.lowercased()
                let receipt: [String: Any] = ["fixture": "synthetic website meeting", "seconds": ProcessInfo.processInfo.systemUptime - start,
                    "available": MeetingSummarizer.available, "summary": notes.summary, "decisions": notes.decisions, "actions": notes.actions,
                    "sourceDigestMatches": notes.sourceDigest == MeetingNotebook.digest(transcript), "reviewed": notes.reviewed,
                    "mentionedExpectedFacts": ["website", "friday", "alex", "thursday", "jordan"].allSatisfy { facts.contains($0) }]
                print(String(decoding: try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            } catch { print("Local summary fixture unavailable: \(error.localizedDescription)"); exit(1) }
            return
        }
        guard CommandLine.arguments.count >= 2 else { print("Usage: SpeechCheck /path/to/synthetic-speech.aiff"); return }
        do {
            if let index = CommandLine.arguments.firstIndex(of: "--nemotron-stream"), CommandLine.arguments.count > index + 1 {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
                guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1, file.length <= 60 * 16_000 else { throw NSError(domain: "Local stream fixture must be 16 kHz mono and under one minute", code: 1) }
                let stream = try LocalDictationStream()
                defer { stream.cancel() }
                try await stream.start(helper: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                var captured = Data(), partials = 0, failure: String?
                stream.observe(audio: { captured }, partial: { _ in partials += 1 }, failure: { failure = $0 })
                while file.framePosition < file.length {
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 5600)!
                    try file.read(into: buffer)
                    captured.append(Data(bytes: buffer.floatChannelData![0], count: Int(buffer.frameLength) * 4))
                    try await Task.sleep(for: .milliseconds(350))
                }
                let text = try await stream.finish(captured)
                if let failure { throw NSError(domain: failure, code: 2) }
                guard partials > 0 else { throw NSError(domain: "No incremental transcript", code: 3) }
                print("Streaming fixture passed: \(partials) partial updates; final: \(text)"); return
            }
            if CommandLine.arguments.contains("--meeting") {
                var count = 0
                try await MeetingTranscription.transcribe(URL(fileURLWithPath: CommandLine.arguments[1]), track: "mic", locale: "en-US") { line in count += 1; print("\(line.start)-\(line.end): \(line.text)") }
                guard count > 0 else { throw NSError(domain: "Meeting fixture produced no transcript", code: 1) }; return
            }
            let text = try await SpeechPipeline.transcribeFile(URL(fileURLWithPath: CommandLine.arguments[1]), locale: "en-US", simulateCapture: CommandLine.arguments.contains("--capture-pipeline"))
            print(CommandLine.arguments.contains("--clean") ? await VoicePolisher.polish(text, tone: .clean, dictionary: "") : text)
        }
        catch { print("Speech fixture unavailable: \(error.localizedDescription)"); exit(1) }
    }
}
