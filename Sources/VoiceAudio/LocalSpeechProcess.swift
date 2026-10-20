import Darwin
import Foundation

/// One bounded, cancellable local helper. Its entire process group is retired on completion.
/// Requests use stdin; neither the environment nor argv carries conversation text.
public final class LocalVoiceProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var cancelled = false
    private var hasRun = false
    public init() {}
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let pid {
            kill(-pid, SIGKILL)
            self.pid = nil
        }
    }
    public func run(executable: String, arguments: [String], input: Data,
                    environment: [String: String], timeout: TimeInterval = 90) -> Data? {
        guard input.count <= 65_536, timeout > 0, timeout <= 90 else { return nil }
        var request = [Int32](repeating: 0, count: 2), response = request
        guard pipe(&request) == 0 else { return nil }
        guard pipe(&response) == 0 else { close(request[0]); close(request[1]); return nil }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, request[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, response[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        for fd in request + response { posix_spawn_file_actions_addclose(&actions, fd) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for value in argv + envp { if let value { free(value) } } }
        var child: pid_t = 0
        lock.lock()
        let result: Int32
        if cancelled || hasRun { result = ECANCELED }
        else {
            hasRun = true
            result = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        }
        if result == 0 { pid = child }
        lock.unlock()
        close(request[0]); close(response[1])
        guard result == 0 else { close(request[1]); close(response[0]); return nil }
        // The timer protects a stalled helper even when the caller's UI timer is not running.
        let deadline = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        // Avoid SIGPIPE if the helper exits before consuming its input.
        _ = fcntl(request[1], F_SETNOSIGPIPE, 1)
        let sent = input.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = write(request[1], raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }; offset += count
            }
            return true
        }
        close(request[1])
        var data = Data(), chunk = [UInt8](repeating: 0, count: 4096), received = true
        while true {
            let count = read(response[0], &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 { received = false; cancel(); break }
            if count == 0 { break }
            if data.count + count > 16_384 { cancel(); break }
            data.append(contentsOf: chunk.prefix(count))
        }
        close(response[0])
        var status: Int32 = 0
        let retired: Bool
        let reaped: Bool
        while true {
            // Reaping and retiring ownership must be atomic relative to cancellation;
            // otherwise a late cancel could signal a PID that has already been reused.
            lock.lock()
            let result = waitpid(child, &status, WNOHANG)
            if result == child || (result < 0 && errno != EINTR) {
                if pid == child {
                    // A trusted helper can exit while its background child has detached
                    // stdout. Retire that remaining group even after a successful exit.
                    kill(-child, SIGKILL)
                    pid = nil
                }
                retired = cancelled
                reaped = result == child
                lock.unlock()
                break
            }
            lock.unlock()
            usleep(10_000)
        }
        guard sent, received, reaped, !retired, status == 0, !data.isEmpty else { return nil }
        return data
    }
}
