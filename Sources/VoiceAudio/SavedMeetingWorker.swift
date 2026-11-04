import Foundation
import ModuleCore

enum SavedMeetingReadKind: Sendable { case progress, output }
private enum SavedMeetingRead: Sendable { case progress(Double?), output(Data) }

/// One saved-file job. Requesting Stop is distinct from the original process
/// wait and file reads returning; callers retain their own inputs until run exits.
@MainActor final class SavedMeetingWorker {
    private let process: Process
    private let output: URL, log: URL
    private let outputLimit: Int
    private let pollInterval: Duration
    private let progressTimeout: TimeInterval
    private let processFailure: String, limitFailure: String, timeoutFailure: String
    private let readCheckpoint: (@Sendable (SavedMeetingReadKind) -> Void)?
    private var started = false, stopped = false
    private var waiter: Task<Void, Never>?
    private var reader: Task<SavedMeetingRead, Error>?
    private var writer: FileHandle?
    private var cleanup=MeetingCleanupReceipt()
    private var escalationTimers:[Task<Void,Never>]=[]
    var resourceReturnIssue:String?{cleanup.issue}
    var processCompletion: Task<Void, Never>? { waiter }

    init(process: Process, output: URL, log: URL, outputLimit: Int, pollInterval: Duration,
         progressTimeout: TimeInterval, processFailure: String, limitFailure: String,
         timeoutFailure: String, readCheckpoint: (@Sendable (SavedMeetingReadKind) -> Void)? = nil) {
        self.process = process; self.output = output; self.log = log; self.outputLimit = outputLimit
        self.pollInterval = pollInterval; self.progressTimeout = progressTimeout
        self.processFailure = processFailure; self.limitFailure = limitFailure; self.timeoutFailure = timeoutFailure
        self.readCheckpoint = readCheckpoint
    }
    func checkActive() throws {
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        reader?.cancel()
        requestTermination()
    }
    private func requestTermination() {
        if waiter != nil,let original=LocalModelProcess.stop(process){escalationTimers.append(original)}
    }
    func run(progress: @escaping @MainActor (Double) -> Void) async throws -> Data {
        guard !started else { throw CancellationError() }; started = true
        cleanup=MeetingCleanupContext.current ?? cleanup
        let outcome: Result<Data, Error>
        do {
            outcome = .success(try await withTaskCancellationHandler {
                try checkActive()
                FileManager.default.createFile(atPath: log.path, contents: nil)
                let writer = try FileHandle(forWritingTo: log); self.writer = writer
                process.standardOutput = writer; process.standardError = writer; process.standardInput = FileHandle.nullDevice
                try await LocalModelProcess.waitForAvailable()
                try checkActive()
                try LocalModelProcess.launch(process)
                let original = process
                waiter = Task.detached { original.waitUntilExit() }
                var lastFraction = -1.0, lastAdvance = Date()
                while process.isRunning {
                    try checkActive()
                    try await Task.sleep(for: pollInterval)
                    try checkActive()
                    if case .progress(let fraction) = try await read(.progress), let fraction {
                        progress(min(1, max(0, fraction)))
                        try checkActive() // A progress callback can synchronously request Stop.
                        if fraction > lastFraction { lastFraction = fraction; lastAdvance = Date() }
                    }
                    guard Date().timeIntervalSince(lastAdvance) < progressTimeout else { throw VoiceProblem.message(timeoutFailure) }
                }
                await waiter?.value
                try checkActive()
                guard process.terminationStatus == 0 else { throw VoiceProblem.message(processFailure) }
                guard case .output(let data) = try await read(.output) else { throw CancellationError() }
                try checkActive()
                return data
            } onCancel: { Task { @MainActor [weak self] in self?.stop() } })
        } catch {
            requestTermination()
            outcome = .failure(error)
        }
        // No deferred caller cleanup can run before these exact original tasks.
        let originalRead = reader, originalWait = waiter, originalWriter = writer
        _ = try? await originalRead?.value
        await originalWait?.value
        let timers=escalationTimers
        timers.forEach{$0.cancel()};for original in timers{await original.value}
        let cleanup=self.cleanup
        let log = self.log, output = self.output
        await Task.detached {
            if let originalWriter{cleanup.close(originalWriter,context:"saved worker log writer close")}
            for file in [output,log] where FileManager.default.fileExists(atPath:file.path){
                do{try FileManager.default.removeItem(at:file)}catch{cleanup.record("saved worker temp cleanup failed: \(error)")}
            }
        }.value
        writer = nil
        try checkActive() // Stop during exit/final read/cleanup cannot become success.
        return try outcome.get()
    }
    private func read(_ kind: SavedMeetingReadKind) async throws -> SavedMeetingRead {
        try checkActive()
        guard reader == nil else { throw CancellationError() }
        let log = self.log, output = self.output, limit = outputLimit
        let checkpoint = readCheckpoint, limitFailure = self.limitFailure,cleanup=self.cleanup
        let task = Task.detached(priority: .userInitiated) {
            try Self.readSnapshot(kind, log: log, output: output, limit: limit,
                                  limitFailure: limitFailure, checkpoint: checkpoint,cleanup:cleanup)
        }
        reader = task
        defer { reader = nil }
        let result = await task.result
        try checkActive() // Check both a successful and a failed original read.
        return try result.get()
    }
    private nonisolated static func readSnapshot(_ kind: SavedMeetingReadKind, log: URL, output: URL,
        limit: Int, limitFailure: String, checkpoint: (@Sendable (SavedMeetingReadKind) -> Void)?,cleanup:MeetingCleanupReceipt) throws -> SavedMeetingRead {
        let cap: Int, url: URL
        switch kind {
        case .progress: cap = 1_000_000; url = log
        case .output: cap = limit; url = output
        }
        let data: Data
        do {
            let file = try FileHandle(forReadingFrom: url)
            defer {cleanup.close(file,context:"saved worker original read close")}
            checkpoint?(kind)
            var bytes = Data()
            while bytes.count < cap {
                guard let chunk = try file.read(upToCount: cap - bytes.count), !chunk.isEmpty else { break }
                bytes.append(chunk)
            }
            data = bytes
        } catch {
            cleanup.record("saved worker original read failed: \(error)")
            if case .progress = kind { return .progress(nil) }
            throw error
        }
        switch kind {
        case .progress:
            // Existing missing/unreadable/at-cap progress stays ignored until
            // the caller's unchanged progress timeout; no partial-cap parse.
            guard data.count < cap, let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last(where: { $0.hasPrefix("progress ") }),
                  let fraction = Double(line.dropFirst(9)), fraction.isFinite else { return .progress(nil) }
            return .progress(fraction)
        case .output:
            guard data.count < cap else { throw VoiceProblem.message(limitFailure) }
            return .output(data)
        }
    }
}
