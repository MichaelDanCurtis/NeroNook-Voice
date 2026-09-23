import AVFoundation
import AudioToolbox
import Speech
import Foundation
import ModuleCore

/// Audio callbacks touch only this lock-owned converter and bounded stream.
/// The capture buffer is converted synchronously, never retained after the tap.
private final class AudioBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var buffers = 0
    private var lastBuffer = Date.distantPast
    private var level = 0.0
    func signal() -> (count: Int, age: TimeInterval, level: Double) { lock.lock(); defer { lock.unlock() }; return (buffers, Date().timeIntervalSince(lastBuffer), level) }
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    init(input: AVAudioFormat, output: AVAudioFormat, continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation) throws {
        guard let converter = AVAudioConverter(from: input, to: output) else { throw VoiceProblem.message("This microphone format cannot be converted for speech.") }
        self.converter = converter; self.outputFormat = output; self.continuation = continuation
    }
    func append(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        guard input.frameLength > 0, input.frameLength <= 8192, input.format.channelCount <= 8 else { fail("Unsupported microphone buffer."); return }
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
        if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) { fail("Speech could not keep up. Recording stopped without silently dropping words.") }
    }
    private func fail(_ text: String) { active = false; continuation.finish(throwing: VoiceProblem.message(text)) }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        // Flush the resampler tail before closing the analyzer input.
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in status.pointee = .endOfStream; return nil }
            if error != nil { fail("Could not finish microphone conversion."); return }
            if output.frameLength > 0, case .dropped = continuation.yield(AnalyzerInput(buffer: output)) { fail("Speech could not keep up while finishing."); return }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
        active = false; continuation.finish()
    }
}

@MainActor public final class SpeechPipeline {
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var bridge: AudioBridge?
    private var results: Task<String, Error>?
    private var started = false
    private var cancelled = false
    private var configurationObserver: NSObjectProtocol?
    public init() {}
    public var inputSignal: (count: Int, age: TimeInterval, level: Double)? { bridge?.signal() }
    public static func prepare(localeIdentifier: String, install: Bool) async throws -> SpeechTranscriber {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else { throw VoiceProblem.message("Apple Speech does not support this language on this Mac.") }
        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        // A nil installation request is Apple's authoritative "nothing to install"
        // response. Some OS versions report .supported even for available assets.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            guard install else { throw VoiceProblem.message("Prepare this language in Settings before recording.") }
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        return transcriber
    }
    public func start(microphone: String?, locale: String, partial: @escaping @MainActor (String) -> Void, failure: @escaping @MainActor (String) -> Void) async throws {
        let transcriber = try await Self.prepare(localeIdentifier: locale, install: false)
        guard !cancelled else { throw CancellationError() }
        let engine = AVAudioEngine(); self.engine = engine
        guard let device = MicrophoneDeviceService.deviceID(for: microphone), let unit = engine.inputNode.audioUnit else { throw VoiceProblem.message("The selected microphone is unavailable.") }
        var deviceID = device
        let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout.size(ofValue: deviceID)))
        guard result == noErr else { throw VoiceProblem.message("Could not select the microphone (\(result)).") }
        // Hardware input, not the client/output format inherited from speakers.
        // On this Mac the HDMI output is 96 kHz while the microphone is 48 kHz.
        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate >= 8000, inputFormat.sampleRate <= 192000, inputFormat.channelCount > 0, inputFormat.channelCount <= 8,
              let outputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat) else { throw VoiceProblem.message("The microphone has no usable speech format.") }
        try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
        let analyzer = SpeechAnalyzer(modules: [transcriber]); self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: outputFormat)
        try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
        let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let bridge = try AudioBridge(input: inputFormat, output: outputFormat, continuation: continuation); self.bridge = bridge
        results = Task {
            var assembler = AppleSpeechTranscriptAssembler()
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let text = assembler.receiveAndRead(String(result.text.characters), final: result.isFinal)
                    try VoiceSession.validate(text, allowEmpty: true)
                    partial(text)
                }
                return assembler.finishedText
            } catch { if !Task.isCancelled { failure(error.localizedDescription) }; throw error }
        }
        try await analyzer.start(inputSequence: stream)
        try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in bridge.append(buffer) }
        started = true; engine.prepare(); try engine.start()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.started, !self.cancelled, let engine = self.engine else { return }
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
            try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
            if bridge.signal().count > 0 { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw VoiceProblem.message("The microphone is not delivering audio. Choose a microphone in Voice settings, then try again.")
    }
    private func stopCapture() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }; configurationObserver = nil
        bridge?.finish(); engine?.stop()
        if started { engine?.inputNode.removeTap(onBus: 0) }; started = false; engine = nil; bridge = nil
    }
    public func finish() async throws -> String {
        stopCapture()
        guard !cancelled, let analyzer, let results else { throw CancellationError() }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        // Drain finalized results before returning; do not cancel the last words.
        let text = try await results.value
        try Task.checkCancellation(); guard !cancelled else { throw CancellationError() }
        self.results = nil; self.analyzer = nil
        return text
    }
    public func cancel() {
        cancelled = true; stopCapture(); results?.cancel(); results = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }; analyzer = nil
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
