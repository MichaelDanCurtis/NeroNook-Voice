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
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var lastMainProgress = Date()
    private var stopped = false
    private var heartbeat: DispatchSourceTimer?

    init(pluginID: String, channel: PluginApplicationChannel?, test: Bool) {
        self.pluginID = pluginID
        self.channel = channel
        self.test = test
    }

    func begin(_ session: UUID) {
        lock.lock()
        self.session = session
        sequence = 0
        lastMainProgress = Date()
        lock.unlock()
        guard channel != nil || test else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "NeroVoice.heartbeat"))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.heartbeatIfResponsive() }
        lock.lock()
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
        if let channel { try channel.send(message) }
        else if test { try FileHandle.standardOutput.write(contentsOf: message.encoded()) }
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
