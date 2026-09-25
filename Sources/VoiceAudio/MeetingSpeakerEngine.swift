import Foundation
import CryptoKit
import ModuleCore

public enum MeetingSpeakerEngine {
    @MainActor private static var jobs: [UUID: Process] = [:]
    @MainActor public static func stopJobs() { for process in jobs.values where process.isRunning { process.terminate() }; jobs = [:] }
    public static let revision = "e23e6404bd9859e93edbf94a740eb1c7fc58f12e"
    private static let files = [
        ("config.json", 1702, "17c9f943bed07b0593f2b8dca01e0be6a418053becc6148b01ecabdff9cbd84d"),
        ("model.safetensors", 236108132, "3b60b8df29e59a8abaf8061ceeeae6e9284a68fbcd2e762c68f5e058bfceebfa")
    ]
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeroVoice/Models/Sortformer-" + revision)
    }
    public static var ready: Bool { files.allSatisfy { item in
        let value = try? directory.appendingPathComponent(item.0).resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]); return value?.fileSize == item.1 && value?.isSymbolicLink == false
    } }
    public static func verify(_ folder: URL) async throws {
        let work = Task.detached {
            for (name, size, expected) in files {
                let url = folder.appendingPathComponent(name)
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.fileSize == size else { throw VoiceProblem.message("Speaker model is incomplete") }
                let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }; var hash = SHA256()
                while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw VoiceProblem.message("Speaker model verification failed") }
            }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    /// Public pinned model download only, initiated by the Prepare speakers button.
    public static func prepare() async throws {
        if ready { try await verify(directory); return }
        let manager = FileManager.default; let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try parent.resourceValues(forKeys: [.volumeAvailableCapacityKey])).volumeAvailableCapacity ?? 0 > 500_000_000 else { throw VoiceProblem.message("Speaker preparation needs 500 MB of free space") }
        let staging = parent.appendingPathComponent(UUID().uuidString); try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        for (name, size, _) in files {
            let url = URL(string: "https://huggingface.co/mlx-community/diar_streaming_sortformer_4spk-v2.1-fp16/resolve/\(revision)/\(name)")!
            var request = URLRequest(url: url); request.timeoutInterval = 300
            let (temp, response) = try await session.download(for: request); defer { try? manager.removeItem(at: temp) }
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200, (try temp.resourceValues(forKeys: [.fileSizeKey])).fileSize == size else { throw VoiceProblem.message("Speaker model download was incomplete") }
            try manager.moveItem(at: temp, to: staging.appendingPathComponent(name))
        }
        try await verify(staging); try Task.checkCancellation()
        if manager.fileExists(atPath: directory.path) { try manager.removeItem(at: directory) }
        try manager.moveItem(at: staging, to: directory)
    }
    @MainActor public static func identify(_ url: URL, helper: URL, working: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> [MeetingSpeakerSpan] {
        try await verify(directory)
        try Task.checkCancellation()
        let output = working.appendingPathComponent("speakers-\(UUID().uuidString).json")
        let log = working.appendingPathComponent("speaker-progress.txt")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let writer = try FileHandle(forWritingTo: log); defer { try? writer.close(); try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: log) }
        let process = Process(); process.executableURL = helper; process.arguments = [directory.path, url.path, output.path]
        process.standardOutput = writer; process.standardError = writer; process.standardInput = FileHandle.nullDevice
        try process.run(); let job = UUID(); jobs[job] = process
        defer { jobs[job] = nil; if process.isRunning { process.terminate() } }
        var lastProgress = -1.0; var lastAdvance = Date()
        do {
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(300))
                if let data = try? Data(contentsOf: log), data.count < 1_000_000,
                   let last = String(data: data, encoding: .utf8)?.split(separator: "\n").last(where: { $0.hasPrefix("progress ") }),
                   let value = Double(last.dropFirst(9)), value.isFinite {
                    progress(min(1, max(0, value))); if value > lastProgress { lastProgress = value; lastAdvance = Date() }
                }
                guard Date().timeIntervalSince(lastAdvance) < 90 else { throw VoiceProblem.message("Speaker analysis stopped making progress. Your recording is retained.") }
            }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw VoiceProblem.message("Local speaker analysis failed. The recording and transcript are retained.") }
            guard (try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max < 16_000_000 else { throw VoiceProblem.message("Speaker analysis exceeded its limit") }
            return try JSONDecoder().decode([MeetingSpeakerSpan].self, from: Data(contentsOf: output))
        } catch { if process.isRunning { process.terminate() }; throw error }
    }
}
