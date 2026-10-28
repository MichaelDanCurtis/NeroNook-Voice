import Foundation
import Darwin
import ModuleCore

/// Optional attribution observes the durable writer. Failure never stops audio.
/// Apple ASR can share this one MLX speaker model; an MLX ASR uses a later pass.
@MainActor public final class MeetingLiveSpeakerAnalyzer {
    public let feed: MeetingLiveAudioFeed
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var pump: Task<Void, Error>?
    private var watchdog: Task<Void, Never>?
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
        try Task.checkCancellation(); guard active else { throw CancellationError() }
        self.update = update; self.failure = failure
        let token = epoch, child = Process(), input = Pipe(), output = Pipe()
        self.process = child; self.input = input; self.output = output
        child.executableURL = executable
        child.arguments = arguments
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PYTHONDONTWRITEBYTECODE": "1"]
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.active, self.epoch == token else { return }
                if data.isEmpty { handle.readabilityHandler = nil; return }
                do { try self.receive(data) } catch { self.fail(error.localizedDescription) }
            }
        }
        try await waitForAvailable()
        // Stop can retire the service while another model exits. Recheck after
        // that suspension, before any child is launched or audio is consumed.
        try Task.checkCancellation()
        guard active, epoch == token else { throw CancellationError() }
        try LocalModelProcess.launch(child)
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
                try await write(nil); try? input.fileHandleForWriting.close()
            } catch { if !Task.isCancelled { fail(error.localizedDescription) }; throw error }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.active else { return }
                if self.process?.isRunning != true && !self.closed { self.fail("Live speaker worker stopped. Recording continues; identify speakers afterward."); return }
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
        defer { deadline.cancel() }
        try await pump?.value
        while process?.isRunning == true { try Task.checkCancellation(); if let issue { throw VoiceProblem.message(issue) }; try await Task.sleep(for: .milliseconds(50)) }
        for _ in 0..<20 where !closed { try await Task.sleep(for: .milliseconds(25)) }
        guard closed, process?.terminationStatus == 0 else { throw VoiceProblem.message(issue ?? "Live speaker analysis could not finish") }
        cancel()
    }
    private func fail(_ text: String) { guard active, issue == nil else { return }; issue = String(text.prefix(300)); failure?(issue!); cancel() }
    public func cancel() {
        guard active else { return }; active = false; epoch = UUID(); feed.finish(); pump?.cancel(); watchdog?.cancel()
        output?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { LocalModelProcess.stop(process) }
        try? input?.fileHandleForWriting.close(); try? output?.fileHandleForReading.close()
    }
}
