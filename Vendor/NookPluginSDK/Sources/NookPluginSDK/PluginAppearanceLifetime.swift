import Foundation

/// The store/window retains the exact registered sources, including detached
/// surfaces, until their raw callbacks and sole original delivery pump return.
/// This is an owned-source receipt, not notification-broker quiescence.
final class PluginAppearanceLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var sealed = false
    private var sources: [UUID: PluginAppearanceSource] = [:]
    static let maximumSources = 128

    var isSealed: Bool { lock.lock(); defer { lock.unlock() }; return sealed }

    func makeSource() -> PluginAppearanceSource? {
        lock.lock()
        guard !sealed, sources.count < Self.maximumSources else { lock.unlock(); return nil }
        let id = UUID(), source = PluginAppearanceSource()
        sources[id] = source
        lock.unlock()
        // One bounded collector per source, never per event. The source is
        // pruned only after its original pump and entered callbacks returned.
        Task { [weak self, source] in
            await source.waitForOriginalReturn()
            self?.removeReturned(id, source: source)
        }
        return source
    }

    private func removeReturned(_ id: UUID, source: PluginAppearanceSource) {
        lock.lock(); defer { lock.unlock() }
        if sources[id] === source { sources[id] = nil }
    }

    func seal() {
        lock.lock()
        sealed = true
        let originals = Array(sources.values)
        lock.unlock()
        for source in originals { source.seal() }
    }

    // Internal diagnostic for authored tests of an entered public mutator.
    var enteredCallbackCount: Int { snapshot().reduce(0) { $0 + $1.enteredCallbackCount } }

    private func snapshot() -> [PluginAppearanceSource] {
        lock.lock(); defer { lock.unlock() }; return Array(sources.values)
    }

    func retirement() async -> Bool {
        seal()
        let originals = snapshot()
        for original in originals { await original.waitForOriginalReturn() }
        return true
    }
}

final class PluginAppearanceCallbackLease: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseOriginal: (@Sendable () -> Void)?
    fileprivate init(_ release: @escaping @Sendable () -> Void) { releaseOriginal = release }
    func finish() {
        lock.lock(); let release = releaseOriginal; releaseOriginal = nil; lock.unlock()
        release?()
    }
    deinit { finish() }
}

/// Each source owns exactly one latest-value pump. Raw callback leases are
/// admitted synchronously before a callback can schedule MainActor delivery.
final class PluginAppearanceSource: @unchecked Sendable {
    typealias Delivery = @MainActor @Sendable () async -> Void
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var sealed = false
        var callbacks = 0
        var submissions = 0
        var streamFinishReturned = false
        var registrationReturned = false
        var stopReturned = false
        var stop: (@Sendable () -> Void)?
        var waiters: [CheckedContinuation<Void, Never>] = []

        var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return !sealed }

        func takeWaitersIfReturned() -> [CheckedContinuation<Void, Never>] {
            guard sealed, callbacks == 0, submissions == 0, streamFinishReturned, registrationReturned, stopReturned else { return [] }
            let result = waiters; waiters.removeAll(); return result
        }
        func releaseCallback() {
            lock.lock(); callbacks -= 1; let ready = takeWaitersIfReturned(); lock.unlock()
            for waiter in ready { waiter.resume() }
        }
        func finishSubmission() {
            lock.lock(); submissions -= 1; let ready = takeWaitersIfReturned(); lock.unlock()
            for waiter in ready { waiter.resume() }
        }
        func finishStream() {
            lock.lock(); streamFinishReturned = true; let ready = takeWaitersIfReturned(); lock.unlock()
            for waiter in ready { waiter.resume() }
        }
        func finishStop() {
            lock.lock(); stopReturned = true; let ready = takeWaitersIfReturned(); lock.unlock()
            for waiter in ready { waiter.resume() }
        }
        func waitForReturn() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if sealed, callbacks == 0, submissions == 0, streamFinishReturned, registrationReturned, stopReturned {
                    lock.unlock(); continuation.resume()
                } else {
                    waiters.append(continuation); lock.unlock()
                }
            }
        }
    }
    private let state: State
    private let continuation: AsyncStream<Delivery>.Continuation
    private let pump: Task<Void, Never>
    private let completion: Task<Void, Never>

    init() {
        let state = State()
        let stream = AsyncStream<Delivery>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pump = Task { @MainActor in
            for await delivery in stream.stream {
                guard state.isOpen else { continue }
                await delivery()
            }
        }
        self.state = state
        continuation = stream.continuation
        self.pump = pump
        completion = Task { await state.waitForReturn(); await pump.value }
    }

    var enteredCallbackCount: Int {
        state.lock.lock(); defer { state.lock.unlock() }; return state.callbacks
    }

    func enter() -> PluginAppearanceCallbackLease? {
        state.lock.lock()
        guard !state.sealed else { state.lock.unlock(); return nil }
        state.callbacks += 1
        state.lock.unlock()
        let original = state
        return PluginAppearanceCallbackLease { original.releaseCallback() }
    }

    func submit(_ delivery: @escaping Delivery) {
        state.lock.lock()
        guard !state.sealed else { state.lock.unlock(); return }
        // yield may release a replaced captured closure and run arbitrary
        // deinitializers. Reserve its original return, then yield unlocked.
        state.submissions += 1
        state.lock.unlock()
        do {
            let outcome = continuation.yield(delivery)
            // Release any dropped delivery before retiring this submission.
            withExtendedLifetime(outcome) {}
        }
        state.finishSubmission()
    }

    /// Must be called once after the real registration call returns, including
    /// an inert or failed registration. If Stop won reentry, remove that exact
    /// just-returned original before reporting its return.
    func finishRegistration(stop: @escaping @Sendable () -> Void) {
        state.lock.lock()
        guard !state.registrationReturned else { state.lock.unlock(); return }
        state.registrationReturned = true
        if state.sealed {
            state.lock.unlock(); stop(); state.finishStop()
        } else {
            state.stop = stop; state.lock.unlock()
        }
    }

    func seal() {
        state.lock.lock()
        guard !state.sealed else { state.lock.unlock(); return }
        state.sealed = true
        let stop = state.stop; state.stop = nil
        state.lock.unlock()
        // finish can likewise release a buffered closure. The completion task
        // cannot return until this exact stream call has actually returned.
        continuation.finish()
        state.finishStream()
        if let stop { stop(); state.finishStop() }
    }

    fileprivate func waitForOriginalReturn() async {
        await completion.value
    }

    func retirement() async -> Bool {
        seal()
        await waitForOriginalReturn()
        return true
    }
}
