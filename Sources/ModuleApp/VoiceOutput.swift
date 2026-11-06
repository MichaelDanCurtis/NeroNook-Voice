import Foundation
import ModuleCore
import NookPluginSDK

/// Serializes plugin messages from the UI and a small liveness timer. The
/// timer tolerates a short Core Audio or local-model stall, but stops after
/// 30 seconds without a main-thread publish so the host can still detect a
/// genuinely stuck plugin.
final class VoiceOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let pluginID: String
    private let channel: PluginApplicationChannel?
    private let test: Bool
    private let sharedSink: (@MainActor @Sendable (PluginMessage) throws -> Task<Bool, Never>)?
    private var originalWrites: [UUID: Task<Void, Never>] = [:]
    private var firstWriteIssue: String?
    private var heartbeatReturned: Task<Void, Never>?
    var writeIssue: String? { lock.lock();defer{lock.unlock()};return firstWriteIssue }
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var lastMainProgress = Date()
    private var stopped = false
    private var heartbeat: DispatchSourceTimer?

    init(pluginID: String, channel: PluginApplicationChannel?, test: Bool, sharedSink: (@MainActor @Sendable (PluginMessage) throws -> Task<Bool, Never>)? = nil) {
        self.pluginID = pluginID
        self.channel = channel
        self.test = test
        self.sharedSink = sharedSink
    }

    func begin(_ session: UUID) {
        lock.lock()
        guard self.session == nil,!stopped else {
            if firstWriteIssue == nil{firstWriteIssue="session-rebind-refused"}
            lock.unlock();stop();return
        }
        self.session = session
        sequence = 0
        lastMainProgress = Date()
        lock.unlock()
        // P1 shared output is synchronously reserved on MainActor in the
        // context's one bounded FIFO. Its native context owns both heartbeats;
        // a separate background task must not reorder inner ready/snapshots.
        guard sharedSink == nil, channel != nil || test else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "NeroVoice.heartbeat"))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.heartbeatIfResponsive() }
        let (stream, done)=AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
        timer.setCancelHandler{done.finish()}
        let returned=Task{for await _ in stream{}}
        lock.lock()
        heartbeatReturned=returned
        if stopped { lock.unlock(); timer.resume(); timer.cancel(); return }
        heartbeat = timer
        lock.unlock()
        timer.resume()
    }

    func noteMainProgress() {
        lock.lock()
        lastMainProgress = Date()
        lock.unlock()
    }

    private func heartbeatIfResponsive() {
        lock.lock()
        let recent = !stopped && Date().timeIntervalSince(lastMainProgress) < 30
        lock.unlock()
        if recent { try? emit("heartbeat") }
    }

    func emit(_ type: String, features: [String]? = nil, snapshot: PluginSnapshot? = nil,
              bus: PluginBusMessage? = nil, caption: PluginTransientCaption? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let session else { throw VoiceProblem.message("Voice plugin connection ended.") }
        if type != "ready" { sequence += 1 }
        let message = PluginMessage(type: type, pluginID: pluginID, session: session,
                                    sequence: sequence, snapshot: snapshot,
                                    features: features, bus: bus, caption: caption)
        if let sharedSink {
            guard Thread.isMainThread else { throw VoiceProblem.message("Shared Voice output requires its native actor") }
            // Reserve exact outer bytes/sequence in the actual context before
            // returning. No second unbounded deferred module-frame queue.
            let wire = try MainActor.assumeIsolated { try sharedSink(message) }
            let id=UUID()
            let original=Task{[self] in
                let delivered=await wire.value
                completeOriginalWrite(id,delivered:delivered)
            }
            originalWrites[id]=original
        } else {
            do {
                if let channel{try channel.send(message)}
                else if test{try FileHandle.standardOutput.write(contentsOf:message.encoded())}
            } catch {
                if firstWriteIssue == nil{firstWriteIssue="output-write-failed"}
                throw error
            }
        }
    }

    // Lock scopes never cross a suspension and are synchronous even when their
    // callers are async. Each receipt still belongs to this original output.
    private func completeOriginalWrite(_ id:UUID,delivered:Bool){
        lock.lock();defer{lock.unlock()}
        if !delivered && firstWriteIssue == nil{firstWriteIssue="output-write-failed"}
        originalWrites[id]=nil
    }
    private func originalHeartbeatReturn()->Task<Void,Never>?{
        lock.lock();defer{lock.unlock()};return heartbeatReturned
    }
    func writeBarrier() -> Task<Void,Never> {
        lock.lock();let originals=Array(originalWrites.values);lock.unlock()
        return Task{for original in originals{await original.value}}
    }
    func retirement() async {
        stop()
        let barrier=writeBarrier()
        let timer=originalHeartbeatReturn()
        await barrier.value;await timer?.value
    }

    func stop() {
        lock.lock()
        stopped = true
        let timer = heartbeat
        heartbeat = nil
        lock.unlock()
        timer?.cancel()
    }
}
