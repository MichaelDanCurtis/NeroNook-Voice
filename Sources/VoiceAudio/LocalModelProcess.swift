import Foundation
import Darwin
import ModuleCore

/// Serializes MLX workers, including the short interval while a cancelled worker exits.
@MainActor enum LocalModelProcess {
    private static var active: Process?
    private static var idle: (UUID, () -> Void)?
    static func reserveIdle(_ owner: UUID, release: @escaping () -> Void) { releaseIdle(); idle = (owner, release) }
    static func claimIdle(_ owner: UUID) { if idle?.0 == owner { idle = nil } }
    static func releaseIdle() { let old = idle; idle = nil; old?.1() }
    static func waitForAvailable() async throws {
        releaseIdle()
        for _ in 0..<40 {
            try Task.checkCancellation()
            if active?.isRunning != true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw VoiceProblem.message("A local model is still running. Finish it before starting another.")
    }
    static func launch(_ process: Process) throws {
        guard active?.isRunning != true else { throw VoiceProblem.message("The previous local model is still stopping. Try again in a moment.") }
        try process.run(); active = process
    }
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
