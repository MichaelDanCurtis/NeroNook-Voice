import Foundation
import AVFoundation
import CryptoKit
import ModuleCore

public struct QwenReference: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let transcript: String
    public let seconds: Double
    public let sha256: String
}

/// Owns normalized local references, never the user's original audio file.
public struct QwenVoiceLibrary: Sendable {
    public let root: URL
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeroVoice/QwenVoices")
    }
    public func list() throws -> [QwenReference] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { url in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let data = try? Data(contentsOf: url.appendingPathComponent("voice.json")), data.count <= 8192,
                  let p = try? JSONDecoder().decode(QwenReference.self, from: data), p.id.uuidString == url.lastPathComponent,
                  !p.name.isEmpty, p.name.utf8.count <= 80, !p.transcript.isEmpty, p.transcript.utf8.count <= 2048,
                  p.seconds.isFinite, (3...30).contains(p.seconds), p.sha256.count == 64 else { return nil }
            return p
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func audio(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString).appendingPathComponent("reference.wav") }
    public func reference(_ id: UUID) throws -> (QwenReference, URL) {
        guard let profile = try list().first(where: { $0.id == id }) else { throw VoiceProblem.message("That cloned voice is unavailable. Choose it again in Qwen Voice Studio.") }
        let url = audio(id), values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink == false, (values.fileSize ?? 0) <= 3_000_000,
              profile.transcript.utf8.count <= 2048, profile.seconds >= 3, profile.seconds <= 30 else { throw VoiceProblem.message("Invalid voice reference") }
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        guard hash == profile.sha256 else { throw VoiceProblem.message("The reference recording changed. Import it again.") }
        return (profile, url)
    }
    public func save(source: URL, name: String, transcript: String) throws -> QwenReference {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), transcript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 80, !transcript.isEmpty, transcript.utf8.count <= 2048 else { throw VoiceProblem.message("Give the voice a name and the exact words in its recording") }
        guard try list().count < 64 else { throw VoiceProblem.message("Archive a saved voice before adding more") }
        let size = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? 0) <= 64_000_000 else { throw VoiceProblem.message("Choose an audio clip smaller than 64 MB") }
        let file = try AVAudioFile(forReading: source), input = file.processingFormat
        let seconds = Double(file.length) / input.sampleRate
        guard seconds.isFinite, (3...30).contains(seconds), input.channelCount > 0, input.channelCount <= 8,
              input.sampleRate >= 8000, input.sampleRate <= 192000,
              let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(file.length)) else { throw VoiceProblem.message("Choose 3–30 seconds of clear speech") }
        try file.read(into: buffer)
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        guard let converter = AVAudioConverter(from: input, to: format), let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(seconds*24000)+4096)) else { throw VoiceProblem.message("Cannot convert this audio clip") }
        var fed = false, error: NSError?
        converter.convert(to: output, error: &error) { _, state in
            if fed { state.pointee = .endOfStream; return nil }; fed = true; state.pointee = .haveData; return buffer
        }
        if let error { throw error }
        guard output.frameLength >= 72000, output.frameLength <= 720000 else { throw VoiceProblem.message("Choose 3–30 seconds of speech") }
        let samples = UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        guard samples.allSatisfy({ $0.isFinite && abs($0) <= 4 }), samples.reduce(0.0, { $0 + Double($1*$1) }) / Double(samples.count) > 0.000001 else { throw VoiceProblem.message("The clip is silent or invalid. Record clear speech and try again.") }
        let fm = FileManager.default, id = UUID(), folder = root.appendingPathComponent(id.uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let url = audio(id)
            do { let saved = try AVAudioFile(forWriting: url, settings: format.settings); try saved.write(from: output) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            let p = QwenReference(id: id, name: name, transcript: transcript, seconds: Double(output.frameLength)/24000, sha256: hash)
            let data = try JSONEncoder().encode(p); try data.write(to: folder.appendingPathComponent("voice.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
            return p
        } catch { try? fm.removeItem(at: folder); throw error }
    }
    public func archive(_ id: UUID) throws {
        _ = try reference(id)
        let dest = root.appendingPathComponent("Archived", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.moveItem(at: root.appendingPathComponent(id.uuidString), to: dest.appendingPathComponent(id.uuidString))
    }
    public func restore(_ id: UUID) throws {
        try FileManager.default.moveItem(at: root.appendingPathComponent("Archived/"+id.uuidString), to: root.appendingPathComponent(id.uuidString))
    }
}
