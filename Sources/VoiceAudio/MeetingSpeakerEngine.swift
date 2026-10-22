import Foundation
import CryptoKit
import AVFoundation
import ModuleCore

public enum MeetingSpeakerEngine {
    @MainActor private static var jobs: [UUID: Process] = [:]
    @MainActor public static func stopJobs() { for process in jobs.values where process.isRunning { LocalModelProcess.stop(process) }; jobs = [:] }
    public static let revision = "59ed2dbfc1346dcea9d423c71306a3a2499c568f"
    /// Weight identity is separate from the reproducible attribution policy.
    public static let analysisRevision = revision + "+edges40ms-v1"
    private static let files = [
        ("config.json", 1521, "f215091252bc54f8dcc7d682962a659e03a6bcb26d1c86e4728b8c6730130eb4"),
        ("model.safetensors", 198632220, "21e8427d1795c9c46c5800f56b16061734ffd0dcadd71d9bcf0b4d6ef7261da5")
    ]
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeroVoice/Models/Nemotron-3-Diarization-" + revision)
    }
    public static var ready: Bool { SpeakerRuntime.ready && files.allSatisfy { item in
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
        try await SpeakerRuntime.prepare()
        if ready { try await verify(directory); return }
        let manager = FileManager.default; let parent = directory.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try parent.resourceValues(forKeys: [.volumeAvailableCapacityKey])).volumeAvailableCapacity ?? 0 > 500_000_000 else { throw VoiceProblem.message("Speaker preparation needs 500 MB of free space") }
        let staging = parent.appendingPathComponent(UUID().uuidString); try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        for (name, size, _) in files {
            let url = URL(string: "https://huggingface.co/mlx-community/Nemotron-3-Diarization/resolve/\(revision)/\(name)")!
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
        let pcm = working.appendingPathComponent("speaker-audio-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: pcm) }
        let conversion = Task.detached {
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                  file.processingFormat.commonFormat == .pcmFormatFloat32 else { throw VoiceProblem.message("Unsupported speaker audio") }
            FileManager.default.createFile(atPath: pcm.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let sink = try FileHandle(forWritingTo: pcm); defer { try? sink.close() }
            while file.framePosition < file.length {
                try Task.checkCancellation()
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 81920)!
                try file.read(into: buffer)
                if let channel = buffer.floatChannelData?[0] { try sink.write(contentsOf: Data(bytes: channel, count: Int(buffer.frameLength) * 4)) }
            }
        }
        try await withTaskCancellationHandler { try await conversion.value } onCancel: { conversion.cancel() }
        try Task.checkCancellation()
        guard SpeakerRuntime.ready else { throw VoiceProblem.message("Prepare speakers first.") }
        let process = Process(); process.executableURL = SpeakerRuntime.executable
        process.arguments = ["-I", "-B", Bundle.main.resourceURL!.appendingPathComponent("NemotronSpeakers/worker.py").path, directory.path, pcm.path, output.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PYTHONDONTWRITEBYTECODE": "1"]
        process.standardOutput = writer; process.standardError = writer; process.standardInput = FileHandle.nullDevice
        try await LocalModelProcess.waitForAvailable()
        try LocalModelProcess.launch(process); let job = UUID(); jobs[job] = process
        defer { jobs[job] = nil; if process.isRunning { LocalModelProcess.stop(process) } }
        var lastProgress = -1.0; var lastAdvance = Date()
        do {
            while process.isRunning {
                try Task.checkCancellation()
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
        } catch { if process.isRunning { LocalModelProcess.stop(process) }; throw error }
    }
}
