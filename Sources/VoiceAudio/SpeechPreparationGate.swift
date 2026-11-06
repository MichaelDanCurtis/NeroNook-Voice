import Foundation
import ModuleCore

/// Serial preparation admission. The caller must retain its permit until the
/// original preparation has actually returned, including cancellation cleanup.
@MainActor final class SpeechPreparationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }
    private var owner: UUID?
    private var returns:[UUID:(task:Task<Void,Never>,done:AsyncStream<Void>.Continuation)]=[:]
    private func began(_ permit:UUID){
        let pair=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
        returns[permit]=(Task{for await _ in pair.stream{}},pair.continuation)
    }
    func currentReturn()->Task<Void,Never>?{owner.flatMap{returns[$0]?.task}}
    private var waiters: [Waiter] = []
    var busy: Bool { owner != nil }
    var waitingCount: Int { waiters.count }

    func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        if owner == nil {
            owner = id;began(id)
            // Cancellation may arrive concurrently with the synchronous grant.
            if Task.isCancelled { release(id); throw CancellationError() }
            return id
        }
        guard waiters.count < 4 else { throw VoiceProblem.message("Speech preparation queue is full") }
        return try await withTaskCancellationHandler {
            let permit: UUID = try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
            // A grant can race the matching cancellation callback. If this
            // task already received its permit, only it releases that permit;
            // the queued cancellation callback never touches an active owner.
            if Task.isCancelled { release(permit); throw CancellationError() }
            return permit
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id) }
        }
    }

    func release(_ permit: UUID) {
        guard owner == permit else { return }
        owner = nil
        returns.removeValue(forKey:permit)?.done.finish()
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        owner = next.id;began(next.id)
        next.continuation.resume(returning: next.id)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
