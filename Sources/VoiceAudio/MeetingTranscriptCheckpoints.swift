import Foundation
import ModuleCore

/// At most the in-flight write and one newest snapshot are retained. Encoding,
/// validation and atomic replacement never run on the recorder's main actor.
public final class MeetingTranscriptCheckpoints: @unchecked Sendable {
    private struct Pending { let transcript: MeetingTranscript; let id: UUID; let provider: MeetingASRProvider }
    private let queue = DispatchQueue(label: "cafe.nero.voice.transcript-checkpoints", qos: .utility)
    private let lock = NSLock()
    private var pending: Pending?
    private var draining = false
    private var lastError: Error?
    private let persist: @Sendable (MeetingTranscript, UUID, MeetingASRProvider) throws -> Void
    private let failure: @Sendable (UUID, String) -> Void
    public convenience init(store: MeetingStore, failure: @escaping @Sendable (UUID, String) -> Void = { _, _ in }) {
        self.init(persist: { try store.saveLiveTranscript($0, id: $1, provider: $2) }, failure: failure)
    }
    init(persist: @escaping @Sendable (MeetingTranscript, UUID, MeetingASRProvider) throws -> Void,
         failure: @escaping @Sendable (UUID, String) -> Void = { _, _ in }) {
        self.persist = persist; self.failure = failure
    }
    public func save(_ transcript: MeetingTranscript, id: UUID, provider: MeetingASRProvider) {
        lock.lock(); defer { lock.unlock() }
        pending = Pending(transcript: transcript, id: id, provider: provider)
        guard !draining else { return }
        draining = true
        // Scheduling under the lock also orders a concurrent flush after all
        // saves that were accepted before it.
        queue.async { self.drain() }
    }
    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else { draining = false; lock.unlock(); return }
            pending = nil; lock.unlock()
            do { try persist(next.transcript, next.id, next.provider); lastError = nil }
            catch { lastError = error; failure(next.id, error.localizedDescription) }
        }
    }
    public func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock(); defer { lock.unlock() }
            queue.async {
                if let error = self.lastError { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    /// Termination cannot leave a Task running after process exit. Normal Stop
    /// and Pause use the asynchronous flush and leave the UI responsive.
    public func flushSynchronously() { queue.sync {} }
}
