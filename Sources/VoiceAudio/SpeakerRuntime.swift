import Foundation
import CryptoKit
import ModuleCore

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
            defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
            while process.isRunning {
                if Task.isCancelled { process.terminate(); process.waitUntilExit(); throw CancellationError() }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard process.terminationStatus == 0 else { throw VoiceProblem.message("Could not prepare the bundled speaker runtime.") }
            try Task.checkCancellation()
            try Data(expected.utf8).write(to: staging.appendingPathComponent(".prepared"))
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: staging, to: target)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
