import Foundation
import ModuleCore

/// A single isolated MLX process. Audio is memory-only and sent through a pipe;
/// its bounded transcript log is removed at the end of the explicit dictation.
@MainActor public final class LocalDictationStream {
    private let process = Process()
    private let input = Pipe()
    private let log: URL
    private let writer: FileHandle
    private var pumping: Task<Void, Never>?
    private var writing: Task<Void, Error>?
    private var sent = 0
    private var stopped = false
    private var issue: String?
    private var lastText = ""
    public init() throws {
        log = FileManager.default.temporaryDirectory.appendingPathComponent("NeroVoice-Stream-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        writer = try FileHandle(forWritingTo: log)
    }
    public func start(helper: URL) async throws {
        let model = LocalASREngine(.nemotron)
        try await model.verify(model.directory); try Task.checkCancellation()
        process.executableURL = helper; process.arguments = ["--stream", model.directory.path]
        process.standardInput = input; process.standardOutput = writer; process.standardError = FileHandle.nullDevice
        try await LocalModelProcess.waitForAvailable()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        try LocalModelProcess.launch(process)
        for _ in 0..<120 {
            try Task.checkCancellation()
            if try messages().contains(where: { $0.type == "ready" }) { return }
            guard process.isRunning else { throw VoiceProblem.message("Nemotron could not start. Your Apple Speech option is unchanged.") }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw VoiceProblem.message("Nemotron took too long to load. Try again or choose Apple Speech.")
    }
    private struct Message: Decodable { var type: String; var text: String }
    private func messages() throws -> [Message] {
        guard (try log.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max < 1_000_000 else { throw VoiceProblem.message("Live transcript exceeded its limit.") }
        let data = try Data(contentsOf: log)
        return data.split(separator: 10).compactMap { try? JSONDecoder().decode(Message.self, from: Data($0)) }
    }
    private func send(_ data: Data) async throws {
        guard !stopped, data.count >= sent, data.count <= 4_096_000 else { throw CancellationError() }
        guard data.count > sent else { return }
        let payload = Data(data.dropFirst(sent)); sent = data.count
        let handle = input.fileHandleForWriting
        let task = Task.detached(priority: .userInitiated) {
            var length = UInt32(payload.count).littleEndian
            try withUnsafeBytes(of: &length) { try handle.write(contentsOf: Data($0)) }
            try handle.write(contentsOf: payload)
        }
        writing = task
        try await task.value
        writing = nil
    }
    public func observe(audio: @escaping @MainActor () -> Data?, partial: @escaping @MainActor (String) -> Void,
                        failure: @escaping @MainActor (String) -> Void) {
        pumping = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled && !stopped {
                    if let data = audio() { try await send(data) }
                    if let text = try messages().last?.text, text != lastText { try VoiceSession.validate(text, allowEmpty: true); lastText = text; partial(text) }
                    guard process.isRunning else { throw VoiceProblem.message("Nemotron stopped responding. Record again or choose Apple Speech.") }
                    try await Task.sleep(for: .milliseconds(350))
                }
            } catch {
                if !Task.isCancelled && !stopped { issue = error.localizedDescription; failure(error.localizedDescription) }
            }
        }
    }
    public func finish(_ audio: Data) async throws -> String {
        pumping?.cancel(); await pumping?.value; pumping = nil
        if let issue { throw VoiceProblem.message(issue) }
        try await send(audio)
        try input.fileHandleForWriting.write(contentsOf: Data(repeating: 0, count: 4))
        try input.fileHandleForWriting.close()
        while process.isRunning { try await Task.sleep(for: .milliseconds(100)); try Task.checkCancellation() }
        guard process.terminationStatus == 0, let final = try messages().last, final.type == "final" else { throw VoiceProblem.message("Nemotron could not finish the transcript.") }
        try VoiceSession.validate(final.text)
        cancel()
        return final.text
    }
    public func cancel() {
        guard !stopped else { return }; stopped = true
        pumping?.cancel(); pumping = nil
        if process.isRunning { LocalModelProcess.stop(process) }
        try? input.fileHandleForWriting.close(); try? writer.close()
        try? FileManager.default.removeItem(at: log)
    }
}
