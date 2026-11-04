import AVFoundation
import AudioToolbox
import Speech
import Foundation
import ModuleCore

/// Audio callbacks touch only this lock-owned converter and bounded stream.
/// The capture buffer is converted synchronously, never retained after the tap.
final class AudioBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var buffers = 0
    private var lastBuffer = Date.distantPast
    private var level = 0.0
    func signal() -> (count: Int, age: TimeInterval, level: Double) { lock.lock(); defer { lock.unlock() }; return (buffers, Date().timeIntervalSince(lastBuffer), level) }
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let maxInputFrames: AVAudioFrameCount
    private let captureLocally: Bool
    private var captured = Data()
    private var captureError: String?
    private var nextStamp: CMTime?
    func error() -> String? { lock.lock(); defer { lock.unlock() }; return captureError }
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    init(input: AVAudioFormat, output: AVAudioFormat, continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?, captureLocally: Bool = false,
         maxInputFrames: AVAudioFrameCount = 8192) throws {
        guard maxInputFrames > 0, maxInputFrames <= 16384 else { throw VoiceProblem.message("Invalid speech buffer limit.") }
        self.maxInputFrames = maxInputFrames
        guard let converter = AVAudioConverter(from: input, to: output) else { throw VoiceProblem.message("This microphone format cannot be converted for speech.") }
        self.converter = converter; self.outputFormat = output; self.continuation = continuation
        guard !captureLocally || (output.sampleRate == 16_000 && output.channelCount == 1 && output.commonFormat == .pcmFormatFloat32) else {
            throw VoiceProblem.message("Local dictation needs 16 kHz mono microphone audio.")
        }
        self.captureLocally = captureLocally
    }
    func append(_ input: AVAudioPCMBuffer, startTime: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        guard input.frameLength > 0, input.frameLength <= maxInputFrames, input.format.channelCount <= 8 else { fail("Unsupported microphone buffer."); return }
        buffers += 1; lastBuffer = Date()
        var peak: Float = 0
        if let channels = input.floatChannelData {
            for channel in 0..<Int(input.format.channelCount) {
                let samples = channels[input.format.isInterleaved ? 0 : channel]
                for frame in 0..<Int(input.frameLength) { peak = max(peak, abs(samples[frame * input.stride + (input.format.isInterleaved ? channel : 0)])) }
            }
        }
        level = peak > 0 ? max(0, min(1, (20 * log10(Double(peak)) + 60) / 60)) : 0
        let frames = Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate
        guard frames.isFinite, frames > 0, frames < 65536,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(frames) + 64) else { fail("Invalid microphone format."); return }
        var fed = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        guard error == nil else { fail("Microphone conversion failed."); return }
        guard output.frameLength > 0 else { return }
        if let startTime {
            let incoming = CMTime(seconds: startTime, preferredTimescale: 48000)
            nextStamp = nextStamp.map { CMTimeMaximum($0, incoming) } ?? incoming
        }
        let stamp = nextStamp
        if let stamp { nextStamp = CMTimeAdd(stamp, CMTime(value: Int64(output.frameLength), timescale: Int32(outputFormat.sampleRate))) }
        if let continuation, case .dropped = continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: stamp)) {
            fail("Speech could not keep up. Recording stopped without silently dropping words.")
        }
        guard active else { return }
        if captureLocally { appendCapture(output) }
    }
    private func appendCapture(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { fail("Invalid local speech buffer."); return }
        let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
        guard captured.count + bytes <= 4_096_000 else { fail("Dictation reached its one-minute audio limit."); return }
        captured.append(contentsOf: UnsafeRawBufferPointer(start: channel, count: bytes))
    }
    func capturedAudio() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return captureLocally ? captured : nil
    }
    private func fail(_ text: String) { captureError = text; active = false; continuation?.finish(throwing: VoiceProblem.message(text)) }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        // Flush the resampler tail before closing the analyzer input.
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in status.pointee = .endOfStream; return nil }
            if error != nil { fail("Could not finish microphone conversion."); return }
            if output.frameLength > 0 {
                let stamp = nextStamp
                if let stamp { nextStamp = CMTimeAdd(stamp, CMTime(value: Int64(output.frameLength), timescale: Int32(outputFormat.sampleRate))) }
                if let continuation, case .dropped = continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: stamp)) {
                    fail("Speech could not keep up while finishing."); return
                }
                if captureLocally { appendCapture(output) }
            }
            guard active else { return }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        active = false; continuation?.finish()
    }
}

@MainActor public final class SpeechPipeline {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var bridge: AudioBridge?
    private var captureError: String?
    public var capturedSnapshot: Data? { bridge?.capturedAudio() }
    public var inputError: String? { bridge?.error() ?? captureError }
    private var results: Task<String, Error>?
    private var started = false
    private var cancelled = false
    private var starting = false
    private var finishing = false
    private var epoch = UUID()
    private var originalStart: Task<Void, Never>?
    private var originalFinish: Task<Void, Never>?
    private var retirement: Task<Void, Never>?
    private let startCheckpoint: (@MainActor () async throws -> Void)?
    private var configurationObserver: NSObjectProtocol?
    public private(set) var capturedAudio: Data?
    public init() { startCheckpoint = nil }
    // Observation/cancellation only. Tests must stop before Apple assets, device
    // selection or engine construction; no permission/readiness can be supplied.
    init(startCheckpoint: @escaping @MainActor () async throws -> Void) { self.startCheckpoint = startCheckpoint }
    var startIsOwned: Bool { starting }
    var finishIsOwned: Bool { finishing }
    public var inputSignal: (count: Int, age: TimeInterval, level: Double)? { bridge?.signal() }
    public static func prepare(localeIdentifier: String, install: Bool, wordTiming: Bool = false) async throws -> SpeechTranscriber {
        try Task.checkCancellation()
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier))
        try Task.checkCancellation()
        guard let locale = supported else { throw VoiceProblem.message("Apple Speech does not support this language on this Mac.") }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: wordTiming ? [.audioTimeRange] : [])
        // A nil installation request is Apple's authoritative "nothing to install"
        // response. Some OS versions report .supported even for available assets.
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        try Task.checkCancellation()
        if let request {
            guard install else { throw VoiceProblem.message("Prepare this language in Settings before recording.") }
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        return transcriber
    }
    public func start(microphone: String?, locale: String, provider: VoiceASRProvider = .apple, partial: @escaping @MainActor (String) -> Void, failure: @escaping @MainActor (String) -> Void) async throws {
        let (token, end) = try beginStart()
        defer { starting = false; end.finish() }
        // Reserve original return custody before releasing any prepared lease.
        LocalModelProcess.releaseIdle()
        let previousRetirement = VoiceRecognitionRetirement.pending()
        do {
            try requireCurrent(token)
            await previousRetirement?.value
            try requireCurrent(token)
            try await startCheckpoint?()
            try requireCurrent(token)
            let transcriber = provider == .apple ? try await Self.prepare(localeIdentifier: locale, install: false) : nil
            try requireCurrent(token)
            guard let device = MicrophoneDeviceService.deviceID(for: microphone) else {
                throw VoiceProblem.message("The selected microphone is unavailable. Choose an available input in Voice settings.")
            }
            // The input unit may already point to the selected device. Reapplying
            // CurrentDevice can intermittently fail after a default-route change,
            // even though the unit is ready to record. A fresh engine is a safe
            // retry when Core Audio reports a transient routing failure.
            var configured: AVAudioEngine?
            var routeError = noErr
            for attempt in 0..<2 {
                try requireCurrent(token)
                let candidate = AVAudioEngine()
                guard let unit = candidate.inputNode.audioUnit else {
                    throw VoiceProblem.message("The selected microphone is unavailable.")
                }
                var current = AudioDeviceID(0)
                var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                let read = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                kAudioUnitScope_Global, 0, &current, &size)
                if read == noErr && current == device {
                    configured = candidate
                    break
                }
                var selected = device
                routeError = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                                  kAudioUnitScope_Global, 0, &selected,
                                                  UInt32(MemoryLayout<AudioDeviceID>.size))
                if routeError == noErr {
                    configured = candidate
                    break
                }
                if attempt == 0 {
                    try await Task.sleep(for: .milliseconds(150))
                    try requireCurrent(token)
                }
            }
            try requireCurrent(token)
            guard let engine = configured else {
                throw VoiceProblem.message("macOS could not route the microphone (\(routeError)). Choose a different input in Voice settings, then try again.")
            }
            self.engine = engine
            // Hardware input, not the client/output format inherited from speakers.
            // On this Mac the HDMI output is 96 kHz while the microphone is 48 kHz.
            let inputFormat = engine.inputNode.inputFormat(forBus: 0)
            guard inputFormat.sampleRate >= 8000, inputFormat.sampleRate <= 192000, inputFormat.channelCount > 0, inputFormat.channelCount <= 8 else {
                throw VoiceProblem.message("The microphone has no usable speech format.")
            }
            let available = transcriber == nil
                ? AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
                : await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber!], considering: inputFormat)
            try requireCurrent(token)
            guard let outputFormat = available else { throw VoiceProblem.message("The microphone has no usable speech format.") }
            let streamAndContinuation = transcriber == nil ? nil : AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
            let bridge = try AudioBridge(input: inputFormat, output: outputFormat, continuation: streamAndContinuation?.continuation, captureLocally: provider != .apple); self.bridge = bridge
            if let transcriber, let streamAndContinuation {
                let analyzer = SpeechAnalyzer(modules: [transcriber]); self.analyzer = analyzer
                try await analyzer.prepareToAnalyze(in: outputFormat)
                try requireCurrent(token)
                results = Task { [weak self] in
                    var assembler = AppleSpeechTranscriptAssembler()
                    do {
                        for try await result in transcriber.results {
                            guard let self else { throw CancellationError() }
                            try self.requireCurrent(token)
                            let text = assembler.receiveAndRead(String(result.text.characters), final: result.isFinal)
                            try VoiceSession.validate(text, allowEmpty: true)
                            partial(text)
                            try self.requireCurrent(token)
                        }
                        guard let self else { throw CancellationError() }
                        try self.requireCurrent(token)
                        return assembler.finishedText
                    } catch {
                        if !Task.isCancelled, let self, !self.cancelled, self.epoch == token {
                            self.cancel()
                            failure(error.localizedDescription)
                        }
                        throw error
                    }
                }
                try await analyzer.start(inputSequence: streamAndContinuation.stream)
                try requireCurrent(token)
            }
            try requireCurrent(token)
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in bridge.append(buffer) }
            started = true
            engine.prepare()
            try requireCurrent(token)
            try engine.start()
            try requireCurrent(token)
            configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.started, !self.cancelled, self.epoch == token, let engine = self.engine else { return }
                    // Selecting/starting an input also posts this notification. Ignore
                    // those queued notices while the selected route is still healthy.
                    let current = engine.inputNode.inputFormat(forBus: 0)
                    let selected = MicrophoneDeviceService.deviceID(for: microphone)
                    if engine.isRunning, selected == device, current == inputFormat { return }
                    self.cancel(); failure("The microphone changed or disconnected. Review the partial transcript, then record again.")
                }
            }
            // A running engine does not prove that installTap attached successfully.
            // Never show Listening until real (possibly silent) buffers arrive.
            for _ in 0..<60 {
                try requireCurrent(token)
                if bridge.signal().count > 0 { return }
                try await Task.sleep(for: .milliseconds(50))
                try requireCurrent(token)
            }
            throw VoiceProblem.message("The microphone is not delivering audio. Choose a microphone in Voice settings, then try again.")
        } catch { cancel(); throw error }
    }
    private func beginStart() throws -> (UUID, AsyncStream<Void>.Continuation) {
        try Task.checkCancellation()
        guard !cancelled, !starting, !finishing, !started, engine == nil, analyzer == nil, results == nil else { throw CancellationError() }
        starting = true; epoch = UUID()
        let pair = AsyncStream<Void>.makeStream()
        originalStart = Task { for await _ in pair.stream {} }
        return (epoch, pair.continuation)
    }
    private func requireCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !cancelled, epoch == token else { throw CancellationError() }
    }
    private func stopCapture() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }; configurationObserver = nil
        bridge?.finish(); captureError = bridge?.error(); capturedAudio = bridge?.capturedAudio(); engine?.stop()
        if started { engine?.inputNode.removeTap(onBus: 0) }; started = false; engine = nil; bridge = nil
    }
    public func finish() async throws -> String {
        try Task.checkCancellation()
        guard !cancelled, !starting, !finishing else { throw CancellationError() }
        finishing = true
        let pair = AsyncStream<Void>.makeStream()
        originalFinish = Task { for await _ in pair.stream {} }
        defer { finishing = false; pair.continuation.finish() }
        let token = epoch
        do {
            stopCapture()
            try requireCurrent(token)
            if let captureError { throw VoiceProblem.message(captureError) }
            if analyzer == nil {
                guard let capturedAudio, !capturedAudio.isEmpty else { throw VoiceProblem.message("No microphone audio was captured.") }
                return ""
            }
            guard let analyzer, let results else { throw CancellationError() }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try requireCurrent(token)
            // Drain finalized results before returning; do not cancel the last words.
            let text = try await results.value
            try requireCurrent(token)
            self.results = nil; self.analyzer = nil
            return text
        } catch { cancel(); throw error }
    }
    /// Captured original start/finish/result returns and analyzer cancellation;
    /// not a guarantee that every Core Audio callback or OS resource is gone.
    public func retirementCompletion() -> Task<Void, Never>? { retirement }
    /// An external owner may join. Never await this from this pipeline's own
    /// start checkpoint or result callback, which the same drain must observe.
    public func cancelAndWait() async {
        cancel()
        await retirement?.value
    }
    public func cancel() {
        guard !cancelled else { return }
        cancelled = true; epoch = UUID()
        let start = originalStart, finish = originalFinish, originalResults = results
        // Cancellation must be scheduled before joining start or finish, which
        // may themselves await this analyzer. No self-await in cancel/results.
        let analyzerCancellation = analyzer.map { analyzer in Task { await analyzer.cancelAndFinishNow() } }
        let drain = Task {
            await start?.value
            await finish?.value
            await analyzerCancellation?.value
            _ = try? await originalResults?.value
        }
        retirement = drain
        VoiceRecognitionRetirement.retain(drain)
        stopCapture(); capturedAudio = nil
        originalResults?.cancel(); results = nil; analyzer = nil
    }
    /// Explicit synthetic/file fixture path; never opens a microphone or downloads assets.
    public static func transcribeFile(_ url: URL, locale: String, simulateCapture: Bool = false) async throws -> String {
        let transcriber = try await prepare(localeIdentifier: locale, install: false)
        let file = try AVAudioFile(forReading: url)
        guard Double(file.length) / file.processingFormat.sampleRate <= 60 else { throw VoiceProblem.message("Fixture must be under one minute.") }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task { () throws -> String in
            var assembler = AppleSpeechTranscriptAssembler()
            for try await result in transcriber.results { _ = assembler.receiveAndRead(String(result.text.characters), final: result.isFinal) }
            return assembler.finishedText
        }
        do {
            if simulateCapture {
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: file.processingFormat) else { throw VoiceProblem.message("No speech format") }
                try await analyzer.prepareToAnalyze(in: format)
                let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
                let bridge = try AudioBridge(input: file.processingFormat, output: format, continuation: continuation)
                try await analyzer.start(inputSequence: stream)
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else { throw VoiceProblem.message("No fixture buffer") }
                    try file.read(into: buffer, frameCount: 1024); bridge.append(buffer)
                    try await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate))
                }
                bridge.finish(); try await analyzer.finalizeAndFinishThroughEndOfInput()
            } else { try await analyzer.start(inputAudioFile: file, finishAfterFile: true) }
            return try await results.value
        }
        catch { results.cancel(); await analyzer.cancelAndFinishNow(); throw error }
    }
}
private extension AppleSpeechTranscriptAssembler {
    mutating func receiveAndRead(_ text: String, final: Bool) -> String { receive(text: text, isFinal: final); return displayText }
}
