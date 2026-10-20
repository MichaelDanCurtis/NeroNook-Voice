import AVFoundation
import Foundation
import ModuleCore
import Darwin

/// Uses the same fixed Apple renderer as Ember. No model, microphone or network.
@MainActor final class AppleVoice2Renderer: NSObject, AVAudioPlayerDelegate {
    static let identifier = "com.apple.siri.natural.Simone"
    var engineOutput: ConversationAudio?
    var started: (() -> Void)?
    var finished: ((String?) -> Void)?
    private var token: UUID?
    private var session: LocalSpeechSession?
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var folder: URL?
    func prepare() throws {
        if session?.usable == true { return }
        guard let helper = Bundle.main.url(forResource: "apple_voice", withExtension: "swift", subdirectory: "Speech"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/swift"),
              FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw VoiceProblem.message("Apple Voice 2 needs the installed voice and Apple developer tools on this Mac. Choose another Apple voice if unavailable.")
        }
        let environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin", "TMPDIR": FileManager.default.temporaryDirectory.path, "LANG": "en_US.UTF-8"]
        session = try LocalSpeechSession(executable: "/usr/bin/sandbox-exec", arguments: ["-p", "(version 1) (allow default) (deny network*)", "/usr/bin/swift", helper.path, "--session"], environment: environment)
    }
    func speak(_ text: String, delivery: SpeechDelivery) throws {
        stop()
        let id = UUID(), directory = FileManager.default.temporaryDirectory.appendingPathComponent("nero-speech-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let output = directory.appendingPathComponent("voice.wav")
        let input = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "text": text, "outputPath": output.path,
            "rate": Double(delivery.rate), "pitchMultiplier": Double(delivery.pitch), "voiceIdentifier": Self.identifier, "volume": 1.0, "sentencePause": 0.0])
        do { try prepare() } catch { try? FileManager.default.removeItem(at: directory); throw error }
        guard let session else { throw VoiceProblem.message("Local speech renderer unavailable") }
        token = id; folder = directory
        task = Task { [weak self] in
            let receipt = try? await session.render(input, id: id)
            guard let self, self.token == id, !Task.isCancelled else { try? FileManager.default.removeItem(at: directory); return }
            self.task = nil
            guard let receipt, let value = try? JSONSerialization.jsonObject(with: receipt) as? [String: Any],
                  value["ok"] as? Bool == true, value["id"] as? String == id.uuidString,
                  value["voiceIdentifier"] as? String == Self.identifier, value["language"] as? String == "en-US", value["quality"] as? Int == 2,
                  value["rate"] as? Double == Double(delivery.rate), value["pitchMultiplier"] as? Double == Double(delivery.pitch),
                  value["channels"] as? Int == 1, value["format"] as? String == "wav",
                  let frames = value["frameCount"] as? Int, frames > 0,
                  let rate = value["sampleRate"] as? Double, [24_000, 48_000].contains(rate), Double(frames) / rate <= 180,
                  let attributes = try? output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? Int.max) <= 18_000_000,
                  let audio = try? AVAudioFile(forReading: output), audio.length == frames, audio.fileFormat.sampleRate == rate, audio.fileFormat.channelCount == 1,
                  let bytes = try? Data(contentsOf: output) else {
                self.stop(); self.finished?("Apple Voice 2 could not render. Check that the voice and Apple developer tools are installed. No other voice was substituted."); return
            }
            if let engine=self.engineOutput {
                do {
                    try engine.playFile(output) { [weak self] in guard let self,self.token == id else{return};self.stop();self.finished?(nil) }
                    try? FileManager.default.removeItem(at:directory);self.folder=nil;self.started?()
                } catch {self.stop();self.finished?(error.localizedDescription)}
                return
            }
            guard let player=try? AVAudioPlayer(data:bytes) else {self.stop();self.finished?("Audio playback unavailable");return}
            try? FileManager.default.removeItem(at: directory); self.folder = nil
            self.player = player; player.delegate = self; player.prepareToPlay()
            guard player.play() else { self.stop(); self.finished?("Audio playback unavailable."); return }
            self.started?()
        }
    }
    func stop() {
        token = nil; task?.cancel(); task = nil; session?.cancelPending()
        engineOutput?.stopPlayback(); player?.delegate = nil; player?.stop(); player = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }; folder = nil
    }
    func shutdown() { stop(); session?.stop(); session = nil }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, player] in
            guard let self, self.player === player else { return }
            self.stop(); self.finished?(flag ? nil : "Audio playback failed.")
        }
    }
}
