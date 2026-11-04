import Foundation

/// Owns real preparation/finalization tasks and their captured resource drains.
/// Logical Cancel may finish immediately; original work cannot lose its owner.
@MainActor final class DictationWorkOwner {
    private var work: [UUID: Task<Void, Never>] = [:]
    private var retiringWork: Set<UUID> = []
    private var retirement: Task<Void, Never>?
    private var retirementToken: UUID?
    private var cancellationDepth = 0
    private var publishedBusy = false
    var changed: (() -> Void)?
    var busy: Bool { !work.isEmpty || draining }
    var draining: Bool { cancellationDepth > 0 || retirement != nil }
    var retirementID: UUID? { retirementToken }
    func retirementCompletion() -> Task<Void, Never>? { retirement }

    @discardableResult func start(prepare: (@MainActor (Task<Void, Never>) -> Void)? = nil, _ body: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !draining else { return nil }
        let id = UUID()
        let original = Task { [weak self] in
            defer { self?.finished(id) }
            guard !Task.isCancelled else { return }
            await body()
        }
        work[id] = original
        publish()
        // The reservation already exists during synchronous setup and every
        // publication. Stop can cancel it before dispatch or during setup.
        if !original.isCancelled { prepare?(original) }
        return original
    }
    private func finished(_ id: UUID) {
        work.removeValue(forKey: id); retiringWork.remove(id)
        publish()
    }
    func cancel(capture: () -> [Task<Void, Never>] = { [] }) {
        // Reserve before a callback-bearing cancellation/presentation effect.
        cancellationDepth += 1
        let originals = work.filter { !retiringWork.contains($0.key) }
        retiringWork.formUnion(originals.keys)
        for task in work.values { task.cancel() }
        let resources = capture()
        // A nested cancellation may have captured additional resources. Join
        // its current tail after that callout instead of overwriting it.
        if !originals.isEmpty || !resources.isEmpty {
            let previous = retirement, id = UUID()
            retirementToken = id
            retirement = Task { [weak self] in
                await previous?.value
                for task in originals.values { await task.value }
                for task in resources { await task.value }
                guard let self, self.retirementToken == id else { return }
                self.retirement = nil; self.retirementToken = nil
                self.publish()
            }
        }
        cancellationDepth -= 1
        publish()
    }
    private func publish() {
        let value = busy
        guard value != publishedBusy else { return }
        publishedBusy = value
        changed?()
    }
}
