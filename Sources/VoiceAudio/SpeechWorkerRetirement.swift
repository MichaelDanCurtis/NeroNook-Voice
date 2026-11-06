import Foundation

/// Holds original worker-reader/reap completions through renderer replacement.
/// This is not an ASR/analyzer drain, audio-device lease or process-wide broker.
@MainActor final class SpeechWorkerRetirement {
    private var original: Task<Void, Never>?
    private var identity: UUID?
    var changed: (() -> Void)?
    var busy: Bool { original != nil }
    func completion() -> Task<Void, Never>? { original }

    func retain(_ workerCompletion: Task<Void, Never>?) {
        guard let workerCompletion else { return }
        let prior = original, id = UUID()
        identity = id
        original = Task { [weak self] in
            await prior?.value
            await workerCompletion.value
            guard let self, self.identity == id else { return }
            self.original = nil; self.identity = nil
            self.changed?()
        }
    }
}
