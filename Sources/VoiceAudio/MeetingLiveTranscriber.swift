import Foundation
import AVFoundation
import Speech
import Darwin
import ModuleCore

/// No capture API: consumes the durable recorder's bounded normalized feed.
/// Apple streams independently per track; MLX uses one resident worker/model.
@MainActor public final class MeetingLiveTranscriber {
    public let feed: MeetingLiveAudioFeed
    private var analyzers: [String: SpeechAnalyzer] = [:]
    private var bridges: [String: AudioBridge] = [:]
    private var results: [Task<Void, Error>] = []
    private var pump: Task<Void, Error>?
    private var watchdog: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var epoch = UUID()
    private var active = true
    private var ready = false
    private var closed = false
    private var issue: String?
    private var prepared = false
    private var dormant = false
    private var observedEnds: [String: Double] = [:]
    private var lastReply = Date()
    private struct Boundary {
        var continuation: CheckedContinuation<Void, Error>?
        var handoff: ((Double) throws -> Void)?
        var through: Double?
        var deadline: Task<Void, Never>?
    }
    private var boundaries: [UUID: Boundary] = [:]
    private var update: ((MeetingLiveUpdate) throws -> Void)?
    private var failure: ((String) -> Void)?
    public init(feed: MeetingLiveAudioFeed = MeetingLiveAudioFeed()) { self.feed = feed }
    public func start(provider: MeetingASRProvider, tracks: Set<String>, locale: String, helper: URL,
                      update: @escaping @MainActor (MeetingLiveUpdate) throws -> Void,
                      failure: @escaping @MainActor (String) -> Void) async throws {
        guard active, !prepared, tracks.isSubset(of: ["mic", "system"]), !tracks.isEmpty else { throw VoiceProblem.message("Invalid live audio source") }
        LocalModelProcess.releaseIdle()
        self.update = update; self.failure = failure
        let token = epoch
        if provider == .apple {
            let incoming = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            for track in tracks.sorted() {
                let transcriber = try await SpeechPipeline.prepare(localeIdentifier: locale, install: false, wordTiming: true)
                try Task.checkCancellation(); guard active, epoch == token else { throw CancellationError() }
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: incoming) else { throw VoiceProblem.message("No live speech format is available") }
                let pair = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                analyzers[track] = analyzer; bridges[track] = try AudioBridge(input: incoming, output: format, continuation: pair.continuation)
                try await analyzer.prepareToAnalyze(in: format)
                results.append(Task { [weak self] in
                    do {
                        for try await value in transcriber.results {
                            try Task.checkCancellation(); guard let self, self.active, self.epoch == token else { throw CancellationError() }
                            let start = value.range.start.seconds, end = CMTimeRangeGetEnd(value.range).seconds
                            let event = MeetingLiveUpdate(track: track, start: start, end: end, text: String(value.text.characters), final: value.isFinal, words: value.isFinal ? MeetingTimedText.words(value.text, start: start, end: end) : nil)
                            try self.accept(event)
                        }
                    } catch { if !Task.isCancelled { self?.fail(error.localizedDescription) }; throw error }
                })
                try await analyzer.start(inputSequence: pair.stream)
            }
        } else {
            let model = LocalASREngine(provider); try await model.verify(model.directory)
            try Task.checkCancellation(); guard active, epoch == token else { throw CancellationError() }
            try await configureWorker(executable: helper,
                arguments: (provider == .parakeet ? ["--parakeet"] : []) + ["--meeting-stream", model.directory.path])
        }
        startPump(provider: provider)
        prepared = true
    }
    /// Prepared executable entry is separated from model preparation so the
    /// framed transport can be qualified with authored, audio-free workers.
    func startPreparedWorker(executable: URL, arguments: [String],
                             update: @escaping (MeetingLiveUpdate) throws -> Void,
                             failure: @escaping (String) -> Void) async throws {
        guard active, !prepared else { throw CancellationError() }
        self.update = update; self.failure = failure
        try await configureWorker(executable: executable, arguments: arguments)
        startPump(provider: .nemotron)
        prepared = true
    }
    /// A prepared, never-fed recognizer can be transferred exactly once before
    /// capture. No old PCM, timestamps, results or boundary may cross a lease.
    func transfer(update: @escaping (MeetingLiveUpdate) throws -> Void,
                  failure: @escaping (String) -> Void, dormant: Bool) -> Bool {
        guard active, prepared, issue == nil, observedEnds.isEmpty, boundaries.isEmpty,
              process?.isRunning != false else { return false }
        self.update = update; self.failure = failure; self.dormant = dormant
        lastReply = Date()
        return true
    }
    private func configureWorker(executable: URL, arguments: [String]) async throws {
        let token = epoch
        let child = Process(), input = Pipe(), output = Pipe(); self.process = child; self.input = input; self.output = output
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reads = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        output.fileHandleForReading.readabilityHandler = { file in
            let data = file.availableData
            if data.isEmpty { file.readabilityHandler = nil; reads.continuation.finish() }
            else if case .dropped = reads.continuation.yield(data) {
                reads.continuation.finish(throwing: VoiceProblem.message("Live speech output could not keep up"))
            }
        }
        reader = Task { [weak self] in
            do {
                for try await data in reads.stream {
                    try Task.checkCancellation()
                    guard let self, self.active, self.epoch == token else { return }
                    try self.receive(data)
                }
                guard let self, self.active, self.epoch == token, !self.closed else { return }
                self.fail("Live speech worker stopped. Audio recording continues.")
            } catch { if !Task.isCancelled { self?.fail(error.localizedDescription) } }
        }
        try await LocalModelProcess.waitForAvailable()
        try Task.checkCancellation()
        guard active, epoch == token else { throw CancellationError() }
        try LocalModelProcess.launch(child)
        for _ in 0..<120 {
            try Task.checkCancellation(); guard active, child.isRunning else { throw VoiceProblem.message(issue ?? "The live speech model could not start") }
            if ready { break }; try await Task.sleep(for: .milliseconds(200))
        }
        guard ready else { cancel(); throw VoiceProblem.message("Live speech model took too long to load. Audio-only recording remains available.") }
    }
    private func startPump(provider: MeetingASRProvider) {
        let token = epoch
        pump = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in feed.stream {
                    feed.consumed(event); try Task.checkCancellation()
                    guard active, epoch == token else { throw CancellationError() }
                    if case .boundary(let id) = event {
                        let through = observedEnds.values.max() ?? 0
                        guard boundaries[id] != nil else { throw VoiceProblem.message("Unknown speech boundary") }
                        boundaries[id]?.through = through
                        if provider == .apple {
                            for analyzer in analyzers.values {
                                try await analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: 16000))
                            }
                            // Keep later PCM queued while Apple's final result
                            // stream drains; it has no explicit worker ack.
                            try await Task.sleep(for: .milliseconds(250))
                            try completeBoundary(id, through: through)
                        } else { try await writeBoundary(id) }
                        continue
                    }
                    guard case .audio(let packet) = event else { continue }
                    observedEnds[packet.track] = max(observedEnds[packet.track] ?? 0, packet.end)
                    if provider == .apple {
                        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(packet.pcm.count / 4))!
                        pcm.frameLength = pcm.frameCapacity
                        _ = packet.pcm.withUnsafeBytes { memcpy(pcm.floatChannelData![0], $0.baseAddress!, packet.pcm.count) }
                        bridges[packet.track]?.append(pcm, startTime: packet.start)
                        if let message = bridges[packet.track]?.error() { throw VoiceProblem.message(message) }
                    } else { try await write(packet) }
                }
                if provider == .apple { bridges.values.forEach { $0.finish() } }
                else { try await write(nil); try? input?.fileHandleForWriting.close() }
            } catch { if !Task.isCancelled { fail(error.localizedDescription) }; throw error }
        }
        if provider != .apple {
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, self.active else { return }
                    if !self.dormant, !self.closed, Date().timeIntervalSince(self.lastReply) > 12 {
                        self.fail("Live transcription stopped responding. Audio recording continues; transcribe it afterward."); return
                    }
                }
            }
        }
    }
    private func accept(_ value: MeetingLiveUpdate) throws {
        guard active, ["mic", "system"].contains(value.track),
              value.start.isFinite, value.end.isFinite, value.start >= 0, value.end >= value.start,
              value.end <= (observedEnds[value.track] ?? 0) + 1, value.text.utf8.count <= 16000 else { throw VoiceProblem.message("Live speech returned an invalid timestamp or text") }
        try update?(value)
    }
    private struct WorkerMessage: Decodable { var type: String; var track: String?; var start: Double?; var end: Double?; var text: String?; var words: [MeetingWord]?; var id: UUID?; var through: Double?; var version: Int? }
    private func receive(_ data: Data) throws {
        buffer.append(data); guard buffer.count <= 131072 else { throw VoiceProblem.message("Live speech output exceeded its limit") }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            let message = try JSONDecoder().decode(WorkerMessage.self, from: line); lastReply = Date()
            switch message.type {
            case "ready":
                guard message.version == 2 else { throw VoiceProblem.message("The local speech helper needs to be updated with Nero Voice") }
                ready = true
            case "ack": break
            case "closed": closed = true
            case "committed":
                guard let id = message.id, let through = message.through else { throw VoiceProblem.message("Incomplete speech boundary") }
                // Complete inline, not in a resumed caller task: another line
                // in this very stdout read may belong to the next segment.
                try completeBoundary(id, through: through)
            case "partial", "final":
                guard let track = message.track, let start = message.start, let end = message.end, let text = message.text else { throw VoiceProblem.message("Live speech output is incomplete") }
                try accept(.init(track: track, start: start, end: end, text: text, final: message.type == "final", words: message.words))
            default: throw VoiceProblem.message("Unknown live speech response")
            }
        }
    }
    private func write(_ packet: MeetingAudioPacket?) async throws {
        guard let handle = input?.fileHandleForWriting else { throw CancellationError() }
        let payload: Data
        if let packet {
            let header = try JSONSerialization.data(withJSONObject: ["track": packet.track, "start": packet.start, "length": packet.pcm.count])
            var count = UInt32(header.count).littleEndian
            payload = withUnsafeBytes(of: &count) { Data($0) } + header + packet.pcm
        } else { payload = Data(repeating: 0, count: 4) }
        let work = Task.detached { try handle.write(contentsOf: payload) }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private func writeBoundary(_ id: UUID) async throws {
        let header = try JSONSerialization.data(withJSONObject: ["command": "commit", "id": id.uuidString])
        var count = UInt32(header.count).littleEndian
        let payload = withUnsafeBytes(of: &count) { Data($0) } + header
        guard let handle = input?.fileHandleForWriting else { throw CancellationError() }
        // Only the input pump writes PCM and controls, never two concurrent writers.
        let work = Task.detached { try handle.write(contentsOf: payload) }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private func completeBoundary(_ id: UUID, through: Double) throws {
        guard through.isFinite, let expected = boundaries[id]?.through,
              abs(expected - through) <= 0.001, let boundary = boundaries.removeValue(forKey: id) else {
            throw VoiceProblem.message("Speech worker acknowledged an invalid boundary")
        }
        boundary.deadline?.cancel()
        guard let continuation = boundary.continuation else { return } // cancelled request, worker still reset
        do { try boundary.handoff?(through); continuation.resume() }
        catch { continuation.resume(throwing: error); throw error }
    }
    /// Ordered finalization. Handoff executes synchronously at the processed
    /// boundary before any later worker output can enter the next turn.
    public func commit(handoff: @escaping (Double) throws -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        guard active, boundaries.count < 4 else { throw VoiceProblem.message("Speech is still finishing the previous turn") }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                boundaries[id] = Boundary(continuation: continuation, handoff: handoff)
                boundaries[id]?.deadline = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled, let self, self.boundaries[id] != nil else { return }
                    self.fail("Speech could not finish this turn in time. Press Talk to reconnect.")
                }
                if !feed.boundary(id) { fail("Speech input closed before this turn could finish") }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelBoundary(id) } }
    }
    private func cancelBoundary(_ id: UUID) {
        guard var boundary = boundaries[id] else { return }
        let continuation = boundary.continuation
        boundary.continuation = nil; boundary.handoff = nil
        boundaries[id] = boundary
        continuation?.resume(throwing: CancellationError())
    }
    public func finish() async throws {
        guard active else { throw VoiceProblem.message(issue ?? "Live transcription stopped; saved audio is retained") }
        feed.finish()
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { self?.fail("Final live words timed out; saved audio is retained.") }
        }
        defer { deadline.cancel() }
        try await pump?.value
        for analyzer in analyzers.values { try await analyzer.finalizeAndFinishThroughEndOfInput() }
        for result in results { try await result.value }
        if let process {
            while process.isRunning { try await Task.sleep(for: .milliseconds(50)); try Task.checkCancellation(); if let issue { throw VoiceProblem.message(issue) } }
            // stdout callbacks may follow the process exit; wait for explicit close.
            for _ in 0..<20 where !closed { try await Task.sleep(for: .milliseconds(25)) }
            guard closed, process.terminationStatus == 0 else { throw VoiceProblem.message(issue ?? "Live speech could not finish; saved audio is retained") }
        }
        if let issue { throw VoiceProblem.message(issue) }; cancel()
    }
    private func fail(_ text: String) {
        guard issue == nil, active else { return }; issue = String(text.prefix(350)); failure?(issue!); cancel()
    }
    public func cancel() {
        guard active else { return }; active = false; epoch = UUID(); feed.finish(); pump?.cancel(); watchdog?.cancel(); reader?.cancel()
        let pending = boundaries; boundaries = [:]
        for boundary in pending.values { boundary.deadline?.cancel(); boundary.continuation?.resume(throwing: CancellationError()) }
        results.forEach { $0.cancel() }; bridges.values.forEach { $0.finish() }
        for analyzer in analyzers.values { Task { await analyzer.cancelAndFinishNow() } }
        analyzers = [:]; bridges = [:]
        output?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { LocalModelProcess.stop(process) }
        try? input?.fileHandleForWriting.close(); try? output?.fileHandleForReading.close()
    }
}
