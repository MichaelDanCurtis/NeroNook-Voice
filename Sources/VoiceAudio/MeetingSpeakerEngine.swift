import Foundation
import CryptoKit
import AVFoundation
import ModuleCore

public enum MeetingSpeakerEngine {
    @MainActor private static var jobs: [UUID: SavedMeetingWorker] = [:]
    @MainActor public static func stopJobs() { for job in Array(jobs.values) { job.stop() } }
    public static let revision = "59ed2dbfc1346dcea9d423c71306a3a2499c568f"
    /// Weight identity is separate from the reproducible attribution policy.
    public static let analysisRevision = revision + "+edges40ms+word-certainty-v3"
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
        try Task.checkCancellation()
        let receipt = MeetingCleanupContext.current
        let work = Task.detached {
            for (name, size, expected) in files {
                try Task.checkCancellation()
                let url = folder.appendingPathComponent(name)
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true, values.fileSize == size else { throw VoiceProblem.message("Speaker model is incomplete") }
                try Task.checkCancellation()
                let file = try FileHandle(forReadingFrom: url)
                defer { if let receipt { receipt.close(file, context: "speaker verification close failed") } else { try? file.close() } }
                var hash = SHA256()
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
        let ownedSession = MeetingOwnedSession(configuration: .ephemeral, receipt: MeetingCleanupContext.current)
        let session = ownedSession.session
        do {
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
        } catch { await ownedSession.invalidateAndWait(); throw error }
        await ownedSession.invalidateAndWait()
    }
    @MainActor public static func identify(_ url: URL, helper: URL, working: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> [MeetingSpeakerSpan] {
        try await verify(directory)
        try Task.checkCancellation()
        let output = working.appendingPathComponent("speakers-\(UUID().uuidString).json")
        let log = working.appendingPathComponent("speaker-progress.txt")
        let pcm = working.appendingPathComponent("speaker-audio-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: pcm) }
        let receipt = MeetingCleanupContext.current
        let conversion = Task.detached {
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                  file.processingFormat.commonFormat == .pcmFormatFloat32 else { throw VoiceProblem.message("Unsupported speaker audio") }
            FileManager.default.createFile(atPath: pcm.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let sink = try FileHandle(forWritingTo: pcm)
            defer { if let receipt { receipt.close(sink, context: "speaker conversion close failed") } else { try? sink.close() } }
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
        return try await identifyPreparedWorker(process: process, output: output, log: log, progress: progress)
    }
    /// Actual saved-worker path after the public model/PCM preparation. Tests
    /// provide only their authored Process and files, never model readiness.
    @MainActor static func identifyPreparedWorker(process: Process, output: URL, log: URL,
        readCheckpoint: (@Sendable (SavedMeetingReadKind) -> Void)? = nil,
        progress: @escaping @MainActor (Double) -> Void) async throws -> [MeetingSpeakerSpan] {
        let worker = SavedMeetingWorker(process: process, output: output, log: log, outputLimit: 16_000_000,
            pollInterval: .milliseconds(300), progressTimeout: 90,
            processFailure: "Local speaker analysis failed. The recording and transcript are retained.",
            limitFailure: "Speaker analysis exceeded its limit",
            timeoutFailure: "Speaker analysis stopped making progress. Your recording is retained.", readCheckpoint: readCheckpoint)
        let job = UUID(); jobs[job] = worker
        defer { jobs[job] = nil }
        let data = try await worker.run(progress: progress)
        try worker.checkActive()
        let spans = try JSONDecoder().decode([MeetingSpeakerSpan].self, from: data)
        try worker.checkActive()
        return spans
    }
}
