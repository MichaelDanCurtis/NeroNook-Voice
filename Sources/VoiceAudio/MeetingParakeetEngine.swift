import Foundation
import CryptoKit
import AVFoundation
import ModuleCore

/// Optional, independently downloaded meeting ASR. Dictation keeps Apple Speech.
public struct LocalASREngine {
    public let provider: VoiceASRProvider
    public init(_ provider: VoiceASRProvider) { precondition(provider != .apple); self.provider = provider }
    public var name: String { provider == .parakeet ? "Parakeet" : "Nemotron" }
    public var helperName: String { "NeroASR" }
    public var revision: String { provider == .parakeet ? "b58cb0ec089186177382a49ffd2109ae1a7664b5" : "7279359e4481b5e9e185a318bd618e429c6d86cd" }
    public let runtimeRevision = "01dec7c9bdce3088a6b6b7ab9f2e403458195efb+preroll350ms+adaptive-energy-v2"
    public var downloadBytes: Int { files.reduce(0) { $0 + $1.size } }
    private var repository: String { provider == .parakeet ? "beshkenadze/parakeet-tdt-0.6b-v3-mlx-encoder-int8" : "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit" }
    private var files: [(name: String, size: Int, sha256: String)] { provider == .parakeet ? [
        ("config.json", 318_476, "ba6a78e8f6335051b28a495524b47598a95350a58ab072c10e692ff7bc4ad6fe"),
        ("model.safetensors", 754_850_057, "72545483758dd40c038acc9afbc9e466ee5bb9819cb93efcc07dbe9015893d2b"),
        ("vocab.txt", 46_772, "3cde1409fd78783a79b29ed4d32da57c746993856f7c8263bcb905d2e5839db7")
    ] : [
        ("config.json", 159605, "f30c7bc469fc01fd5483172b4d7c75075030ddb60f347589c44e216b0a5ea9b6"),
        ("model.safetensors", 755598923, "a64a4da048e7d28dde4cd4ff61ce59308a63314bb5563e73e06c24aae50ea941"),
        ("tokenizer.model", 406554, "ce3895e40806f02a26c3a225161b96ef682d6c0054bae32a245dec4258d7d291"),
        ("vocab.txt", 78294, "d74b60edd1cad792cfce25dcb7e1048d78d717cf4f29acaae2854262d5189f4f")
    ] }

    public var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeroVoice/Models/" + (provider == .parakeet ? "Parakeet-v3-int8-" : "Nemotron-3.5-8bit-") + revision, isDirectory: true)
    }
    public var ready: Bool {
        files.allSatisfy { item in
            let values = try? directory.appendingPathComponent(item.name).resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            return values?.fileSize == item.size && values?.isSymbolicLink == false
        }
    }
    public func verify(_ folder: URL) async throws {
        try Task.checkCancellation()
        let receipt = MeetingCleanupContext.current
        let work = Task.detached {
            for item in files {
                try Task.checkCancellation()
                let url = folder.appendingPathComponent(item.name)
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink == false, values.fileSize == item.size else { throw VoiceProblem.message("Local speech model is incomplete") }
                try Task.checkCancellation()
                let file = try FileHandle(forReadingFrom: url)
                defer { if let receipt { receipt.close(file, context: "ASR verification close failed") } else { try? file.close() } }
                var hash = SHA256()
                while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                    try Task.checkCancellation(); hash.update(data: data)
                }
                guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == item.sha256 else {
                    throw VoiceProblem.message("Local speech model verification failed")
                }
            }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    /// Called only from Prepare Parakeet. No model or audio is sent to a server during inference.
    public func prepare() async throws {
        if ready { try await verify(directory); return }
        let fm = FileManager.default; let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try parent.resourceValues(forKeys: [.volumeAvailableCapacityKey])).volumeAvailableCapacity ?? 0 > 1_600_000_000 else {
            throw VoiceProblem.message("Preparing the speech model needs 1.6 GB of free space")
        }
        let staging = parent.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 3600
        let ownedSession = MeetingOwnedSession(configuration: config, receipt: MeetingCleanupContext.current)
        let session = ownedSession.session
        do {
        for item in files {
            try Task.checkCancellation()
            let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(item.name)")!
            let (temporary, response) = try await session.download(from: url)
            defer { try? fm.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == item.size else {
                throw VoiceProblem.message("Local model download was incomplete")
            }
            try fm.moveItem(at: temporary, to: staging.appendingPathComponent(item.name))
        }
        try await verify(staging); try Task.checkCancellation()
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: staging, to: directory)
        } catch { await ownedSession.invalidateAndWait(); throw error }
        await ownedSession.invalidateAndWait()
    }

    @MainActor private static var jobs: [UUID: SavedMeetingWorker] = [:]
    @MainActor public static func stopJobs() { for job in Array(jobs.values) { job.stop() } }

    /// A dictation uses the same pinned worker as Meetings. Its PCM is held
    /// in memory during recording, then written only to this private temporary
    /// folder and removed after inference or cancellation.
    @MainActor public func transcribeDictation(_ pcm: Data, helper: URL) async throws -> String {
        guard !pcm.isEmpty, pcm.count <= 4_096_000, pcm.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw VoiceProblem.message("Local dictation audio is incomplete.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NeroVoice-Dictation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("dictation.caf")
        let writing = Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let frames = AVAudioFrameCount(pcm.count / MemoryLayout<Float>.size)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let destination = buffer.floatChannelData?[0] else { throw VoiceProblem.message("Could not prepare local dictation audio.") }
            buffer.frameLength = frames
            _ = pcm.withUnsafeBytes { source in memcpy(destination, source.baseAddress!, pcm.count) }
            try AVAudioFile(forWriting: audio, settings: format.settings).write(from: buffer)
        }
        try await withTaskCancellationHandler { try await writing.value } onCancel: { writing.cancel() }
        try Task.checkCancellation()
        let lines = try await transcribe(audio, track: "mic", helper: helper, working: folder) { _ in }
        let result = lines.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        try VoiceSession.validate(result)
        return result
    }

    @MainActor public func transcribe(_ audio: URL, track: String, helper: URL, working: URL,
                                             progress: @escaping @MainActor (Double) -> Void) async throws -> [MeetingUtterance] {
        try await verify(directory)
        try Task.checkCancellation()
        let output = working.appendingPathComponent("parakeet-\(UUID().uuidString).json")
        let log = working.appendingPathComponent("parakeet-progress-\(UUID().uuidString).txt")
        let process = Process(); process.executableURL = helper
        process.arguments = (provider == .parakeet ? ["--parakeet"] : []) + [directory.path, audio.path, output.path, track]
        return try await Self.transcribePreparedWorker(process: process, output: output, log: log, track: track, progress: progress)
    }
    /// The same post-verification worker/registry/decoder path, with an authored
    /// Process for no-model transport tests. Public entry keeps verification.
    @MainActor static func transcribePreparedWorker(process: Process, output: URL, log: URL, track: String,
        readCheckpoint: (@Sendable (SavedMeetingReadKind) -> Void)? = nil,
        progress: @escaping @MainActor (Double) -> Void) async throws -> [MeetingUtterance] {
        let worker = SavedMeetingWorker(process: process, output: output, log: log, outputLimit: 32_000_000,
            pollInterval: .milliseconds(350), progressTimeout: 180,
            processFailure: "Local speech transcription failed. Your recording is retained.",
            limitFailure: "Local transcript exceeded its limit",
            timeoutFailure: "Speech recognition stopped making progress. Your recording is retained.", readCheckpoint: readCheckpoint)
        let job = UUID(); Self.jobs[job] = worker
        defer { Self.jobs[job] = nil }
        let data = try await worker.run(progress: progress)
        try Task.checkCancellation()
        try worker.checkActive()
        let lines = try JSONDecoder().decode([MeetingUtterance].self, from: data)
        guard lines.count <= 40_000, lines.allSatisfy({ $0.track == track && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= 4 * 3600 + 30 && $0.text.utf8.count <= 16_000 }) else {
            throw VoiceProblem.message("Speech recognition returned an invalid transcript")
        }
        try worker.checkActive()
        return lines
    }
}
