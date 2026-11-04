import Darwin
import Foundation
import ModuleCore

/// One local, network-denied renderer. Only timing/control receipts use stdout;
/// speech requests use stdin. One in-flight request and bounded frames prevent
/// an unbounded synthesis queue. Cancellation retires the whole process group.
@MainActor final class LocalSpeechSession {
    private let worker = SpeechSessionProcess()
    private var ready = false, closed = false
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var pending: (UUID, CheckedContinuation<Data, Error>)?
    private var timer: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    var usable: Bool { !closed }

    init(executable: String, arguments: [String], environment: [String: String]) throws {
        let descriptor = try worker.start(executable: executable, arguments: arguments, environment: environment)
        let worker = self.worker
        reader = Task.detached { [weak self] in
            defer { close(descriptor); worker.reap() }
            var buffer = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while !Task.isCancelled {
                let count = read(descriptor, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 32_768 else { break }
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                    guard line.count <= 16_384 else { await self?.stop(); worker.stop(); return }
                    await self?.receive(line)
                }
            }
            await self?.stop()
        }
        arm(seconds: 15)
    }
    deinit { timer?.cancel(); reader?.cancel(); worker.stop() }

    func prepare() async throws {
        try Task.checkCancellation()
        guard !closed, waiters.count < 4 else { throw VoiceProblem.message("Local speech renderer is unavailable") }
        if ready { return }
        try await withCheckedThrowingContinuation { waiters.append($0) }
        try Task.checkCancellation()
    }
    func render(_ data: Data, id: UUID) async throws -> Data {
        try await prepare(); try Task.checkCancellation()
        guard !closed, pending == nil, data.count <= 8192, !data.contains(10) else {
            throw VoiceProblem.message("Local speech renderer is busy or the request is too large")
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (id, continuation); arm(seconds: 90)
                let worker = self.worker
                Task { [weak self] in
                    let sent = await Task.detached { worker.write(data + Data([10])) }.value
                    if !sent { self?.stop() }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelPending(id: id) } }
    }
    private func cancelPending(id: UUID) { if pending?.0 == id { stop() } }
    func cancelPending() { if pending != nil || !waiters.isEmpty { stop() } }
    private func receive(_ line: Data) {
        guard !closed, let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { stop(); return }
        if !ready {
            guard value["ready"] as? Bool == true, value["version"] as? Int == 1, Set(value.keys) == ["ready", "version"] else { stop(); return }
            ready = true; let old = waiters; waiters = []; arm(seconds: 30)
            old.forEach { $0.resume() }; return
        }
        guard let (id, continuation) = pending, value["id"] as? String == id.uuidString else { stop(); return }
        pending = nil; arm(seconds: 30); continuation.resume(returning: line)
    }
    private func arm(seconds: Int) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }; self?.stop()
        }
    }
    func stop() {
        guard !closed else { return }; closed = true; ready = false
        timer?.cancel(); timer = nil; reader?.cancel(); worker.stop()
        let old = waiters; waiters = []; old.forEach { $0.resume(throwing: CancellationError()) }
        let request = pending; pending = nil; request?.1.resume(throwing: CancellationError())
    }
    /// The exact original reader completes only after closing its descriptor and
    /// reaping its actual worker. Stop remains immediate; owners may join this
    /// separately before releasing a retired session or admitting a successor.
    /// Never await this from receive/stop, which are called by that same reader.
    func retirementCompletion() -> Task<Void, Never>? { reader }
    func stopAndWait() async {
        let original = reader
        stop()
        await original?.value
    }
}

final class SpeechSessionProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?, writer: Int32?
    deinit { stop() }
    func start(executable: String, arguments: [String], environment: [String: String]) throws -> Int32 {
        var input = [Int32](repeating: 0, count: 2), output = input
        guard pipe(&input) == 0 else { throw VoiceProblem.message("Speech pipe unavailable") }
        guard pipe(&output) == 0 else { close(input[0]); close(input[1]); throw VoiceProblem.message("Speech pipe unavailable") }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        for fd in input + output { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv + env { if let p { free(p) } } }
        var child: pid_t = 0
        let result = posix_spawn(&child, executable, &actions, &attributes, argv, env)
        close(input[0]); close(output[1])
        guard result == 0 else { close(input[1]); close(output[0]); throw VoiceProblem.message("Local speech helper could not start") }
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        lock.lock(); pid = child; writer = input[1]; lock.unlock()
        return output[0]
    }
    func write(_ data: Data) -> Bool {
        lock.lock(); let fd = writer.map { dup($0) } ?? -1; lock.unlock()
        guard fd >= 0 else { return false }; defer { close(fd) }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }; offset += count
            }
            return true
        }
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let writer { close(writer); self.writer = nil }
        if let pid { kill(-pid, SIGKILL) }
        // Keep ownership until reaped, preventing PID reuse races.
    }
    func reap() {
        stop()
        while true {
            lock.lock()
            guard let pid else { lock.unlock(); return }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno != EINTR) { self.pid = nil; lock.unlock(); return }
            lock.unlock(); usleep(10_000)
        }
    }
}
