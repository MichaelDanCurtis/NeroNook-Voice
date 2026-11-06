import Foundation
import Darwin
import ModuleCore

private final class MeetingSpeakerIOIssue: @unchecked Sendable {
    private let lock = NSLock()
    private var first: String?
    func record(_ message: String) { lock.lock(); defer { lock.unlock() }; if first == nil { first = message } }
    var value: String? { lock.lock(); defer { lock.unlock() }; return first }
}

/// Optional attribution observes the durable writer. Failure never stops audio.
/// Apple ASR can share this one MLX speaker model; an MLX ASR uses a later pass.
@MainActor public final class MeetingLiveSpeakerAnalyzer {
    public let feed: MeetingLiveAudioFeed
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var pump: Task<Void, Error>?
    private var reader: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var finishDeadline: Task<Void, Never>?
    private let readCallbacks = VoiceAudioCallbackAdmission()
    private let ioIssue = MeetingSpeakerIOIssue()
    private var inputClosed = false
    public var resourceReturnIssue: String? { ioIssue.value }
    private var processWait: Task<Void, Never>?
    private var escalationTimers: [Task<Void, Never>] = []
    private var startCompletion: Task<Void, Never>?
    private var retirement: Task<Void, Never>?
    private var buffer = Data()
    private var active = true
    private var ready = false
    private var closed = false
    private var issue: String?
    private var epoch = UUID()
    private var observed: [String: Double] = [:]
    private var lastReply = Date()
    private var lastWriteStarted: Date?
    private var update: ((String, [MeetingSpeakerSpan], Double) throws -> Void)?
    private var failure: ((String) -> Void)?
    /// Observation only, default nil. Authored transport checks can suspend the
    /// genuine reader after ready; this supplies no bytes, labels or readiness.
    var outputReaderReady: (@MainActor () async -> Void)?
    public init(feed: MeetingLiveAudioFeed = MeetingLiveAudioFeed()) { self.feed = feed }
    /// Selection used before capture starts. Resume never replaces a preparing
    /// or failed session with a second consumer; failed sessions use saved audio.
    public static func recordingFeed(existing: MeetingLiveSpeakerAnalyzer?, continuingMeeting: Bool,
        separation: Bool, modelReady: Bool, live: Bool, provider: MeetingASRProvider) -> MeetingLiveAudioFeed? {
        if continuingMeeting { return existing?.feed }
        guard separation, modelReady, live, provider == .apple else { return nil }
        return MeetingLiveAudioFeed(bufferingLimit: 512)
    }
    public func start(update: @escaping (String, [MeetingSpeakerSpan], Double) throws -> Void, failure: @escaping (String) -> Void) async throws {
        guard MeetingSpeakerEngine.ready else { throw VoiceProblem.message("Prepare speakers before live attribution.") }
        try await MeetingSpeakerEngine.verify(MeetingSpeakerEngine.directory)
        try await startPreparedWorker(executable: SpeakerRuntime.executable,
            arguments: ["-I", "-B", Bundle.main.resourceURL!.appendingPathComponent("NemotronSpeakers/stream.py").path, MeetingSpeakerEngine.directory.path],
            update: update, failure: failure)
    }
    /// Shared production transport entry; local fixtures supply an authored
    /// worker without model loading, capture or network access.
    func startPreparedWorker(executable: URL, arguments: [String],
        waitForAvailable: () async throws -> Void = { try await LocalModelProcess.waitForAvailable() },
        update: @escaping (String, [MeetingSpeakerSpan], Double) throws -> Void,
        failure: @escaping (String) -> Void) async throws {
        try Task.checkCancellation(); guard active, startCompletion == nil else { throw CancellationError() }
        let (startStream, startEnd) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        startCompletion = Task { for await _ in startStream {} }
        defer { startEnd.finish() }
        self.update = update; self.failure = failure
        let token = epoch, child = Process(), input = Pipe(), output = Pipe()
        self.process = child; self.input = input; self.output = output
        child.executableURL = executable
        child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PYTHONDONTWRITEBYTECODE": "1"]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // One ordered consumer owns decoding. Bound the queue BEFORE hopping
        // to MainActor, including when UI work temporarily prevents delivery.
        // At most64 chunks of16KiB are buffered; this is not an RSS bound.
        let reads = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let callbacks = readCallbacks, ioIssue = ioIssue
        output.fileHandleForReading.readabilityHandler = { handle in
            guard let entered = callbacks.enter() else { return }; defer { entered.finish() }
            // availableData preserves short ready/ack replies on an open pipe.
            // Split its bounded accepted result before enqueueing; read(upToCount:)
            // can wait for a requested batch and must not gate worker readiness.
            var bytes = [UInt8](repeating: 0, count: 262_144)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0 {
                let code = errno; ioIssue.record("speaker stdout read failed: \(code)")
                handle.readabilityHandler = nil
                reads.continuation.finish(throwing: VoiceProblem.message("Live speaker output read failed (\(code))")); return
            }
            let data = Data(bytes.prefix(count))
            if data.isEmpty { handle.readabilityHandler = nil; reads.continuation.finish(); return }
            guard data.count <= 262_144 else {
                handle.readabilityHandler = nil
                reads.continuation.finish(throwing: VoiceProblem.message("Live speaker output limit reached"))
                return
            }
            for offset in stride(from: 0, to: data.count, by: 16_384) {
                let chunk = data.subdata(in: offset..<min(offset + 16_384, data.count))
                switch reads.continuation.yield(chunk) {
                case .dropped:
                    handle.readabilityHandler = nil
                    reads.continuation.finish(throwing: VoiceProblem.message("Live speaker output could not keep up. Recording continues; identify speakers afterward."))
                    return
                case .terminated: handle.readabilityHandler = nil; return
                case .enqueued: break
                @unknown default:
                    handle.readabilityHandler = nil
                    reads.continuation.finish(throwing: VoiceProblem.message("Live speaker output is unavailable. Recording continues."))
                    return
                }
            }
        }
        reader = Task { [weak self] in
            var observedReady = false
            do {
                for try await data in reads.stream {
                    try Task.checkCancellation()
                    guard let self, self.active, self.epoch == token else { return }
                    try self.receive(data)
                    if self.ready && !observedReady {
                        observedReady = true
                        if let observe = self.outputReaderReady { await observe() }
                    }
                    await Task.yield() // allow Stop between bounded decode batches
                }
                guard let self, self.active, self.epoch == token else { return }
                guard self.buffer.isEmpty else {
                    self.fail("Live speaker output ended with incomplete trailing data. Recording continues; identify speakers afterward.")
                    return
                }
                guard self.closed else {
                    self.fail("Live speaker output ended before final labels were confirmed. Recording continues; identify speakers afterward.")
                    return
                }
            } catch { if !Task.isCancelled { self?.fail(error.localizedDescription) } }
        }
        try await waitForAvailable()
        // Stop can retire the service while another model exits. Recheck after
        // that suspension, before any child is launched or audio is consumed.
        try Task.checkCancellation()
        guard active, epoch == token else { throw CancellationError() }
        try LocalModelProcess.launch(child)
        processWait = Task.detached { child.waitUntilExit() }
        // Native launch may reenter Stop before the original waiter is set.
        // Retain that waiter, issue the late Stop and let original-start drain
        // capture it after this setup call returns.
        if !active {
            if let timer = LocalModelProcess.stop(child) { escalationTimers.append(timer) }
            throw CancellationError()
        }
        for _ in 0..<150 {
            try Task.checkCancellation(); guard active, child.isRunning else { throw VoiceProblem.message(issue ?? "Live speaker model could not start") }
            if ready { break }; try await Task.sleep(for: .milliseconds(200))
        }
        guard ready else { throw VoiceProblem.message("Live speaker model took too long to load") }
        pump = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in feed.stream {
                    feed.consumed(event); try Task.checkCancellation(); guard active else { throw CancellationError() }
                    guard case .audio(let packet) = event else { throw VoiceProblem.message("Unexpected speaker stream control") }
                    observed[packet.track] = max(observed[packet.track] ?? 0, packet.end)
                    try await write(packet)
                }
                try await write(nil)
                if !inputClosed {
                    inputClosed = true
                    do { try input.fileHandleForWriting.close() } catch { ioIssue.record("speaker stdin close failed: \(error)"); throw error }
                }
            } catch { if !Task.isCancelled { fail(error.localizedDescription) }; throw error }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.active else { return }
                // Process exit can precede queued final stdout. The retained
                // reader owns EOF/closed validation, not this liveness timer.
                if let sent = self.lastWriteStarted, sent > self.lastReply, Date().timeIntervalSince(self.lastReply) > 15 {
                    self.fail("Live speaker analysis stopped responding. Recording continues; identify speakers afterward."); return
                }
                // Paused recordings legitimately have no input or replies.
            }
        }
    }
    private struct Message: Decodable { var type: String; var track: String?; var through: Double?; var spans: [MeetingSpeakerSpan]? }
    private func receive(_ data: Data) throws {
        buffer.append(data); guard buffer.count <= 262144 else { throw VoiceProblem.message("Live speaker output limit reached") }
        while let end = buffer.firstIndex(of: 10) {
            guard active else { return } // a callback may synchronously Stop
            guard !closed else { throw VoiceProblem.message("Live speaker output continued after closing. Recording continues; identify speakers afterward.") }
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            let message = try JSONDecoder().decode(Message.self, from: line); lastReply = Date()
            switch message.type {
            case "ready": ready = true
            case "ack": break
            case "closed": closed = true
            case "spans":
                guard let track = message.track, let end = message.through, end.isFinite, end >= 0,
                      end <= (observed[track] ?? 0) + 0.1, let spans = message.spans else { throw VoiceProblem.message("Invalid live speaker clock") }
                try update?(track, spans, end)
            default: throw VoiceProblem.message("Unknown live speaker response")
            }
        }
    }
    private func write(_ packet: MeetingAudioPacket?) async throws {
        guard let handle = input?.fileHandleForWriting else { throw CancellationError() }
        let payload: Data
        if let packet {
            let header = try JSONSerialization.data(withJSONObject: ["track": packet.track, "start": packet.start, "length": packet.pcm.count])
            var size = UInt32(header.count).littleEndian
            payload = withUnsafeBytes(of: &size) { Data($0) } + header + packet.pcm
        } else { payload = Data(repeating: 0, count: 4) }
        lastWriteStarted = Date()
        let work = Task.detached { try handle.write(contentsOf: payload) }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    public func finish() async throws {
        guard active else { throw VoiceProblem.message(issue ?? "Live speaker analysis unavailable") }
        feed.finish()
        let deadline = Task { [weak self] in try? await Task.sleep(for: .seconds(20)); if !Task.isCancelled { self?.fail("Final speaker labels timed out; saved audio is retained.") } }
        finishDeadline = deadline
        defer { deadline.cancel() }
        try await pump?.value
        await processWait?.value
        // EOF may arrive after process exit. Join the actual ordered reader,
        // rather than guessing that500ms is enough for final span delivery.
        await reader?.value
        try Task.checkCancellation()
        if let issue { throw VoiceProblem.message(issue) }
        guard active, closed, buffer.isEmpty, process?.terminationStatus == 0 else { throw VoiceProblem.message(issue ?? "Live speaker analysis could not finish") }
        cancel()
    }
    // Retain the original writer, reader, watchdog and the waiter created only
    // after a successful launch. Cancellation is an operation outcome; the
    // returned task joins actual process wait and local work instead of polling.
    public func cancelAndWait() async {
        if let retirement { await retirement.value; return }
        let originalStart = startCompletion, callbacks = readCallbacks
        let drain = Task { @MainActor [self] in
            // Start can return after a reentrant Stop with a just-launched
            // child/waiter. Capture that exact late resource only after the
            // original setup has returned; never substitute isRunning for wait.
            await originalStart?.value
            let originalPump = pump, originalReader = reader, originalWatchdog = watchdog
            let originalWait = processWait, originalDeadline = finishDeadline
            _ = try? await originalPump?.value
            // The pump awaits its exact detached write before returning. Only
            // then close its handle, so an entered write cannot hit a reused fd.
            if !inputClosed, let input {
                inputClosed = true
                do { try input.fileHandleForWriting.close() } catch { ioIssue.record("speaker stdin close failed: \(error)") }
            }
            await originalReader?.value
            await originalWatchdog?.value; await originalDeadline?.value
            await originalWait?.value
            let timers = escalationTimers
            for timer in timers { timer.cancel(); await timer.value }
            await callbacks.waitForReturn()
            if let output {
                do { try output.fileHandleForReading.close() } catch { ioIssue.record("speaker stdout close failed: \(error)") }
                self.output = nil
            }
        }
        retirement = drain
        cancel()
        await drain.value
    }
    private func fail(_ text: String) { guard active, issue == nil else { return }; issue = String(text.prefix(300)); failure?(issue!); cancel() }
    public func cancel() {
        guard active else { return }; active = false; epoch = UUID(); readCallbacks.seal()
        feed.finish(); pump?.cancel(); watchdog?.cancel(); finishDeadline?.cancel(); reader?.cancel()
        output?.fileHandleForReading.readabilityHandler = nil
        if processWait != nil, let process, process.isRunning,
           let timer = LocalModelProcess.stop(process) { escalationTimers.append(timer) }
        // The retained drain closes input after the actual pump/write return.
        // No new reads enter after seal; retain the original handle until all
        // already-entered readability handlers return in cancelAndWait.
        readCallbacks.nativeStopReturned()
    }
}
