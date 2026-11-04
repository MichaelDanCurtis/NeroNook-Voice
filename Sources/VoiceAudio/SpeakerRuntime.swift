import Foundation
import CryptoKit
import ModuleCore

// An original operation owns this receipt. Operation errors remain separate
// from failures closing the original local file/session resources.
public final class MeetingCleanupReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var first: String?
    public init() {}
    public func record(_ message: String) { lock.lock(); defer { lock.unlock() }; if first == nil { first = message } }
    public var issue: String? { lock.lock(); defer { lock.unlock() }; return first }
    public func close(_ handle: FileHandle, context: String) {
        close(handle, context: context) { try $0.close() }
    }
    func close(_ handle: FileHandle, context: String, operation: (FileHandle) throws -> Void) {
        do { try operation(handle) } catch { record(context + ": \(error)") }
    }
}
public enum MeetingCleanupContext {
    @TaskLocal public static var current: MeetingCleanupReceipt?
}
private final class MeetingSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let receipt: MeetingCleanupReceipt?
    private let lock = NSLock()
    private var returned = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ receipt: MeetingCleanupReceipt?) { self.receipt = receipt }
    func waitForReturn() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if returned { lock.unlock(); continuation.resume(); return }
            waiters.append(continuation); lock.unlock()
        }
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        if let error { receipt?.record("session invalidation failed: \(error)") }
        lock.lock(); returned = true; let pending = waiters; waiters.removeAll(); lock.unlock()
        pending.forEach { $0.resume() }
    }
}
// Owns one ephemeral session; wait only for its own actual invalidation callback.
final class MeetingOwnedSession {
    private let delegate: MeetingSessionDelegate
    let session: URLSession
    init(configuration: URLSessionConfiguration, receipt: MeetingCleanupReceipt?) {
        let delegate = MeetingSessionDelegate(receipt); self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    func invalidateAndWait() async {
        session.invalidateAndCancel()
        await delegate.waitForReturn()
    }
}

public enum SpeakerRuntime {
    private struct Receipt: Decodable { var sha256: String }
    private static var resource: URL { Bundle.main.resourceURL!.appendingPathComponent("speaker-runtime.tar.gz") }
    private static var digest: String? {
        (try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: resource.deletingPathExtension().appendingPathExtension("json"))))?.sha256
    }
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeroVoice/Runtimes/Speakers-" + (digest ?? "unavailable"))
    }
    public static var executable: URL { directory.appendingPathComponent("bin/python3.12") }
    public static var ready: Bool { digest != nil && FileManager.default.fileExists(atPath: directory.appendingPathComponent(".prepared").path) && FileManager.default.isExecutableFile(atPath: executable.path) }
    // Called only after successful launch. Retain the waiter even if the
    // child exits before the first isRunning observation.
    static func waitForOriginalChild(_ process: Process) async throws {
        let waiter = Task.detached { process.waitUntilExit() }
        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
            await waiter.value
        } catch {
            if process.isRunning { process.terminate() }
            await waiter.value
            throw error
        }
    }
    public static func prepare() async throws {
        if ready { return }
        guard let expected = digest else { throw VoiceProblem.message("The bundled speaker runtime is missing. Reinstall Nero Voice.") }
        let archive = resource; let target = directory
        let work = Task.detached {
            let fm = FileManager.default
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else { throw VoiceProblem.message("Speaker runtime verification failed.") }
            let parent = target.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staging = parent.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", staging.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            try await waitForOriginalChild(process)
            guard process.terminationStatus == 0 else { throw VoiceProblem.message("Could not prepare the bundled speaker runtime.") }
            try Task.checkCancellation()
            try Data(expected.utf8).write(to: staging.appendingPathComponent(".prepared"))
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
