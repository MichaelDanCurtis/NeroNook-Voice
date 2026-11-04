import Foundation
import Darwin
import ModuleCore

private struct DictationStreamMessage: Decodable, Sendable { var type: String; var text: String }

/// A single isolated MLX process. Audio is memory-only and sent through a pipe;
/// its bounded transcript log is removed after original dictation work retires.
@MainActor public final class LocalDictationStream {
    private var process: Process?
    private var input: Pipe?
    private let log: URL
    private var writer: FileHandle?
    private var cleanup=MeetingCleanupReceipt()
    private var ioCloser:VoiceOriginalIOClose?
    private var escalationTimers:[Task<Void,Never>]=[]
    private var terminationRequested=false
    private func requestTermination(){
        guard processWait != nil,!terminationRequested,let process else{return}
        terminationRequested=true
        if let timer=LocalModelProcess.stop(process){escalationTimers.append(timer)}
    }
    public var resourceReturnIssue:String?{cleanup.issue}
    private var ownsLog = false
    private var processWait: Task<Void, Never>?
    private var startCompletion: Task<Void, Never>?
    private var finishCompletion: Task<Void, Never>?
    private var retirement: Task<Void, Never>?
    private var starting = false, finishing = false, prepared = false
    private var pumping: Task<Void, Never>?
    private var writing: Task<Void, Error>?
    private var reading: (id: UUID, task: Task<[DictationStreamMessage], Error>)?
    private var readCheckpoint: (@Sendable (Bool) -> Void)?
    private var sent = 0
    private var stopped = false
    private var issue: String?
    private var lastText = ""
    var transcriptLogURL: URL { log }
    var writeInProgress: Bool { writing != nil }
    var finishInProgress: Bool { finishing }

    public init() throws {
        // This inert name is not a file or process allocation. Actual resources
        // are created only after start observes the prior global retirement.
        log = FileManager.default.temporaryDirectory.appendingPathComponent("NeroVoice-Stream-\(UUID().uuidString).jsonl")
    }
    /// Actual opened-reader checkpoint for authored transport tests only. The
    /// normal initializer installs no hook and keeps its public interface.
    convenience init(readCheckpoint: @escaping @Sendable (Bool) -> Void) throws {
        try self.init()
        self.readCheckpoint = readCheckpoint
    }
    public func start(helper: URL) async throws {
        let end = try beginStart()
        defer { starting = false; end.finish() }
        LocalModelProcess.releaseIdle()
        let previous = VoiceRecognitionRetirement.pending()
        do {
            try await withTaskCancellationHandler {
                try requireActive()
                await previous?.value
                try requireActive()
                let model = LocalASREngine(.nemotron)
                try await model.verify(model.directory)
                try requireActive()
                try await configureWorker(executable: helper, arguments: ["--stream", model.directory.path])
                try requireActive(); prepared = true
            } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        } catch { cancel(); throw error }
    }
    /// The same transport with an authored executable, without model discovery,
    /// validation, permissions or capture. Production start retains its checks.
    func startPreparedWorker(executable: URL, arguments: [String]) async throws {
        let end = try beginStart()
        defer { starting = false; end.finish() }
        LocalModelProcess.releaseIdle()
        let previous = VoiceRecognitionRetirement.pending()
        do {
            try await withTaskCancellationHandler {
                try requireActive()
                await previous?.value
                try requireActive()
                try await configureWorker(executable: executable, arguments: arguments)
                try requireActive(); prepared = true
            } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        } catch { cancel(); throw error }
    }
    private func beginStart() throws -> AsyncStream<Void>.Continuation {
        try requireActive()
        guard !starting, !prepared else { throw CancellationError() }
        starting = true
        cleanup=MeetingCleanupContext.current ?? cleanup;ioCloser=VoiceOriginalIOClose(cleanup)
        let pair = AsyncStream<Void>.makeStream()
        startCompletion = Task { for await _ in pair.stream {} }
        return pair.continuation
    }
    private func requireActive() throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
    }
    private func configureWorker(executable: URL, arguments: [String]) async throws {
        try requireActive()
        let process = Process(), input = Pipe()
        self.process = process; self.input = input
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw VoiceProblem.message("The private dictation transcript could not be created.")
        }
        ownsLog = true
        let writer = try FileHandle(forWritingTo: log); self.writer = writer
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = input; process.standardOutput = writer; process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try await LocalModelProcess.waitForAvailable()
        try requireActive()
        try LocalModelProcess.launch(process)
        processWait = Task.detached { process.waitUntilExit() }
        for _ in 0..<120 {
            try requireActive()
            if try await messages().contains(where: { $0.type == "ready" }) { return }
            guard process.isRunning else { throw VoiceProblem.message("Nemotron could not start. Your Apple Speech option is unchanged.") }
            try await Task.sleep(for: .milliseconds(200))
        }
        try requireActive()
        throw VoiceProblem.message("Nemotron took too long to load. Try again or choose Apple Speech.")
    }
    private func messages(requireFinal: Bool = false) async throws -> [DictationStreamMessage] {
        try requireActive()
        guard reading == nil else { throw CancellationError() }
        let id = UUID(), log = self.log, checkpoint = readCheckpoint,cleanup=self.cleanup
        let task = Task.detached(priority: .userInitiated) {
            try Self.readMessages(log: log, requireFinal: requireFinal, checkpoint: checkpoint,cleanup:cleanup)
        }
        reading = (id, task)
        defer { if reading?.id == id { reading = nil } }
        // Cancellation does not discard a synchronous FileHandle operation.
        // Recheck the original caller on both the success and error paths.
        let result = await task.result
        try requireActive()
        return try result.get()
    }
    private nonisolated static func readMessages(log: URL, requireFinal: Bool,
        checkpoint: (@Sendable (Bool) -> Void)?,cleanup:MeetingCleanupReceipt) throws -> [DictationStreamMessage] {
        // Read at most the existing total cap, even if the writer appends after
        // a filesystem size observation. A live final fragment is not a record:
        // the real helper writes JSON and its newline separately.
        let input:FileHandle
        do{input=try FileHandle(forReadingFrom:log)}catch{cleanup.record("dictation log open failed: \(error)");throw error}
        defer{cleanup.close(input,context:"dictation log reader close failed")}
        checkpoint?(requireFinal)
        var data = Data()
        while data.count < 1_000_000 {
            do{
                guard let chunk=try input.read(upToCount:1_000_000-data.count),!chunk.isEmpty else{break}
                data.append(chunk)
            }catch{cleanup.record("dictation log read failed: \(error)");throw error}
        }
        guard data.count < 1_000_000 else { throw VoiceProblem.message("Live transcript exceeded its limit.") }
        let invalid = VoiceProblem.message("The local speech helper returned invalid or incomplete output. Review the partial text, then record again.")
        var records: [DictationStreamMessage] = [], ready = false, final = false
        var start = data.startIndex
        while let end = data[start...].firstIndex(of: 10) {
            guard !final else { throw invalid }
            let line = Data(data[start..<end])
            // 2 KB text can expand to at most six JSON bytes per byte. This
            // bound leaves room for the actual type/text envelope before decode.
            guard !line.isEmpty, line.count <= 16_384,
                  let message = try? JSONDecoder().decode(DictationStreamMessage.self, from: line) else { throw invalid }
            switch message.type {
            case "ready":
                guard !ready else { throw invalid }; ready = true
            case "partial":
                guard ready else { throw invalid }
            case "final":
                // Only finish reads a final, after writing the zero header and
                // joining the original child. An unsolicited final is not ready.
                guard ready, requireFinal else { throw invalid }; final = true
            default: throw invalid
            }
            try VoiceSession.validate(message.text, allowEmpty: message.type != "final")
            records.append(message)
            start = data.index(after: end)
        }
        // During live polling an unfinished suffix remains pending. At actual
        // process EOF it cannot be silently discarded or decoded without LF.
        guard !requireFinal || (ready && final && start == data.endIndex) else { throw invalid }
        return records
    }
    private func send(_ data: Data) async throws {
        try requireActive()
        guard data.count >= sent, data.count <= 4_096_000 else { throw CancellationError() }
        guard data.count > sent else { return }
        let payload = Data(data.dropFirst(sent)); sent = data.count
        var length = UInt32(payload.count).littleEndian
        let framed = withUnsafeBytes(of: &length) { Data($0) } + payload
        try await write(framed)
    }
    private func write(_ payload: Data, closing: Bool = false) async throws {
        try requireActive()
        guard writing == nil, let input else { throw CancellationError() }
        let handle=input.fileHandleForWriting,cleanup=self.cleanup,closer=ioCloser
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            do{try handle.write(contentsOf:payload)}catch{cleanup.record("dictation input write failed: \(error)");throw error}
            if closing{try Task.checkCancellation();try closer?.closeThrowing(handle,context:"dictation input EOF close") }
        }
        writing = task
        // No second writer is admitted until this exact physical write returns.
        defer { writing = nil }
        try await task.value
        try requireActive()
    }
    public func observe(audio: @escaping @MainActor () -> Data?, partial: @escaping @MainActor (String) -> Void,
                        failure: @escaping @MainActor (String) -> Void) {
        guard !stopped, prepared, !finishing, pumping == nil else { return }
        pumping = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled && !stopped {
                    if let data = audio() { try await send(data) }
                    try requireActive()
                    if let text = try await messages().last(where: { $0.type == "partial" })?.text, text != lastText { try VoiceSession.validate(text, allowEmpty: true); lastText = text; partial(text) }
                    try requireActive()
                    guard process?.isRunning == true else { throw VoiceProblem.message("Nemotron stopped responding. Record again or choose Apple Speech.") }
                    try await Task.sleep(for: .milliseconds(350))
                }
            } catch {
                if !Task.isCancelled && !stopped {
                    issue = error.localizedDescription
                    cancel() // Register physical retirement before a reentrant failure callback.
                    failure(error.localizedDescription)
                }
            }
        }
    }
    public func finish(_ audio: Data) async throws -> String {
        try requireActive()
        guard prepared, !starting, !finishing else { throw CancellationError() }
        finishing = true
        let pair = AsyncStream<Void>.makeStream()
        finishCompletion = Task { for await _ in pair.stream {} }
        defer { finishing = false; pair.continuation.finish() }
        do {
            return try await withTaskCancellationHandler {
                let originalPump = pumping
                originalPump?.cancel(); await originalPump?.value
                try requireActive()
                if let issue { throw VoiceProblem.message(issue) }
                try await send(audio)
                try requireActive()
                // Reject any already-observed unsolicited final before the
                // explicit end-of-input handoff; it cannot satisfy this finish.
                _ = try await messages()
                try await write(Data(repeating: 0, count: 4), closing: true)
                try requireActive()
                guard let process, let processWait else { throw CancellationError() }
                await processWait.value
                try requireActive()
                guard process.terminationStatus == 0, let final = try await messages(requireFinal: true).last, final.type == "final" else { throw VoiceProblem.message("Nemotron could not finish the transcript.") }
                try VoiceSession.validate(final.text)
                cancel()
                return final.text
            } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        } catch { cancel(); throw error }
    }
    public func retirementCompletion() -> Task<Void, Never>? { retirement }
    public func cancelAndWait() async { cancel(); await retirement?.value }
    public func cancel() {
        guard !stopped else{return};stopped=true
        let originalStart=startCompletion,originalFinish=finishCompletion
        let drain=Task<Void,Never>{[self] in
            // Reentrant launch Stop may publish its waiter only as setup
            // returns. No FD/log snapshot may precede that actual return.
            await originalStart?.value
            let originalPump=pumping,originalWrite=writing,originalRead=reading?.task,originalWait=processWait
            let originalInput=input,originalWriter=writer,originalLog=ownsLog ? log:nil,closer=ioCloser,cleanup=cleanup
            originalPump?.cancel();originalWrite?.cancel();originalRead?.cancel()
            requestTermination()
            await originalPump?.value
            _=try? await originalWrite?.value;_=try? await originalRead?.value
            await originalWait?.value
            let timers=escalationTimers;timers.forEach{$0.cancel()};for original in timers{await original.value}
            await originalFinish?.value
            await Task.detached{
                if let originalInput{
                    closer?.close(originalInput.fileHandleForWriting,context:"dictation input close")
                    if originalWait == nil{closer?.close(originalInput.fileHandleForReading,context:"unlaunched dictation input reader close")}
                }
                if let originalWriter{closer?.close(originalWriter,context:"dictation log writer close")}
                if let originalLog{
                    do{try FileManager.default.removeItem(at:originalLog)}catch{cleanup.record("dictation private log cleanup failed: \(error)")}
                }
            }.value
        }
        retirement=drain;VoiceRecognitionRetirement.retain(drain)
        pumping?.cancel();writing?.cancel();reading?.task.cancel()
        requestTermination()
    }
}
