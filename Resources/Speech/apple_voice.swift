// Run with /usr/bin/swift. Native-owned requests; no microphone or playback.
import AVFoundation
import CoreFoundation
import Darwin
import Foundation

private let reviewedVoices = ["com.apple.siri.natural.Simone": "en-US", "com.apple.siri.natural.Martha": "en-GB"]
private let maximumRequestBytes = 131_072
private let maximumTextUTF16Length = 10_000
private let maximumAudioSeconds = 600.0
private let maximumOutputBytes: off_t = 60_000_000
private var startedAt = ProcessInfo.processInfo.systemUptime
private var preparedVoices: [String: AVSpeechSynthesisVoice] = [:]

// Also bounds a stalled stdin reader or framework callback. The native owner
// enforces its own whole-process deadline and removes a partial private file.
signal(SIGALRM) { _ in _exit(124) }
alarm(90)
umask(0o077)

private struct SpeechRequest {
    let id: String
    let text: String
    let rate: Double
    let pitchMultiplier: Double
    let voiceIdentifier: String
    let volume: Double
    let sentencePause: Double
    let output: URL
    let parentDevice: dev_t
    let parentInode: ino_t
}

private struct HelperFailure: Error { let reason: String }
private func reject(_ reason: String) throws -> Never { throw HelperFailure(reason: reason) }
private func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { _exit(70) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}
private func metadata(_ path: String) -> stat? {
    var value = stat()
    return path.withCString { lstat($0, &value) } == 0 ? value : nil
}
private func parentMatches(_ request: SpeechRequest) -> Bool {
    guard let value = metadata(request.output.deletingLastPathComponent().path) else { return false }
    return value.st_dev == request.parentDevice && value.st_ino == request.parentInode &&
        value.st_uid == getuid() && value.st_mode & S_IFMT == S_IFDIR && value.st_mode & 0o777 == 0o700
}
private func boundedNumber(_ value: Any?, within range: ClosedRange<Double>) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let result = number.doubleValue
    return result.isFinite && range.contains(result) ? result : nil
}
private func readRequest(_ input: Data) throws -> SpeechRequest {
    guard input.count <= maximumRequestBytes else { try reject("request_too_large") }
    let legacyKeys: Set<String> = ["id", "text", "outputPath", "rate", "pitchMultiplier"]
    guard let value = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
          Set(value.keys) == legacyKeys || Set(value.keys) == legacyKeys.union(["voiceIdentifier", "volume", "sentencePause"]),
          let id = value["id"] as? String, id.utf8.count == 36, UUID(uuidString: id) != nil,
          let text = value["text"] as? String,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.utf16.count <= maximumTextUTF16Length,
          !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }),
          let rate = boundedNumber(value["rate"], within: 0.35...0.60),
          let pitchMultiplier = boundedNumber(value["pitchMultiplier"], within: 0.85...1.15),
          let path = value["outputPath"] as? String, path.hasPrefix("/"), path.utf8.count <= 4_096,
          !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { try reject("invalid_request") }
    let rich = value.keys.contains("voiceIdentifier")
    guard let voiceIdentifier = rich ? value["voiceIdentifier"] as? String : "com.apple.siri.natural.Simone",
          reviewedVoices[voiceIdentifier] != nil,
          let volume = rich ? boundedNumber(value["volume"], within: 0.1...1.0) : 1.0,
          let sentencePause = rich ? boundedNumber(value["sentencePause"], within: 0.0...1.0) : 0.0
    else { try reject("invalid_request") }
    let candidate = URL(fileURLWithPath: path)
    let name = candidate.lastPathComponent
    guard candidate.pathExtension == "wav", name.utf8.count <= 128,
          name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*\\.wav$", options: .regularExpression) != nil,
          let parent = metadata(candidate.deletingLastPathComponent().path),
          parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == getuid(), parent.st_mode & 0o777 == 0o700
    else { try reject("invalid_output") }
    let output = candidate.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(name)
    guard metadata(output.path) == nil else { try reject("output_exists") }
    return SpeechRequest(id: id, text: text, rate: rate, pitchMultiplier: pitchMultiplier,
                         voiceIdentifier: voiceIdentifier, volume: volume, sentencePause: sentencePause,
                         output: output, parentDevice: parent.st_dev, parentInode: parent.st_ino)
}

private func sentences(_ request: SpeechRequest) throws -> [String] {
    // Preserve the accepted renderer's single utterance unless the human adds
    // a pause. AVSpeech queue delays do not promise silence in write buffers.
    guard request.sentencePause > 0 else { return [request.text] }
    var chunks: [String] = []
    request.text.enumerateSubstrings(in: request.text.startIndex..<request.text.endIndex, options: .bySentences) { text, _, _, stop in
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(text) }
        if chunks.count > 256 { stop = true }
    }
    guard !chunks.isEmpty, chunks.count <= 256 else { try reject("sentence_capacity") }
    return chunks
}

private func synthesize(_ request: SpeechRequest) throws -> [String: Any] {
    guard let voice = preparedVoices[request.voiceIdentifier] ?? AVSpeechSynthesisVoice(identifier: request.voiceIdentifier),
          voice.identifier == request.voiceIdentifier, voice.language == reviewedVoices[request.voiceIdentifier], voice.quality == .enhanced,
          !voice.voiceTraits.contains(.isPersonalVoice), !voice.voiceTraits.contains(.isNoveltyVoice)
    else { try reject("exact_voice_unavailable") }
    let chunks = try sentences(request)
    guard parentMatches(request) else { try reject("invalid_output") }
    let descriptor = request.output.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
    guard descriptor >= 0 else { try reject("output_unavailable") }
    close(descriptor)
    var succeeded = false
    defer {
        if !succeeded, parentMatches(request), let file = metadata(request.output.path),
           file.st_uid == getuid(), file.st_mode & S_IFMT == S_IFREG {
            try? FileManager.default.removeItem(at: request.output)
        }
    }

    let lock = NSLock()
    var failure: String?
    var writer: AVAudioFile?
    var frameCount: Int64 = 0
    var sampleRate = 0.0
    var channels: AVAudioChannelCount = 0
    var pauseFrames: Int64 = 0
    for (index, text) in chunks.enumerated() {
        if index > 0 {
            let count = Int64((sampleRate * request.sentencePause).rounded())
            guard count > 0, Double(frameCount + count) / sampleRate <= maximumAudioSeconds,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
                  let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let samples = silence.floatChannelData?[0], let writer else { try reject("invalid_pause_audio") }
            silence.frameLength = AVAudioFrameCount(count)
            for frame in 0..<Int(count) { samples[frame] = 0 }
            try writer.write(from: silence)
            frameCount += count; pauseFrames += count
        }
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Float(request.rate)
        utterance.pitchMultiplier = Float(request.pitchMultiplier)
        var done = false
        synthesizer.write(utterance) { buffer in
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer else { failure = "invalid_audio"; done = true; return }
            if pcm.frameLength == 0 { done = true; return }
            let rate = pcm.format.sampleRate, count = pcm.format.channelCount
            guard rate.isFinite, (rate == 24_000 || rate == 48_000), count == 1,
                  pcm.format.commonFormat == .pcmFormatFloat32, !pcm.format.isInterleaved,
                  let samples = pcm.floatChannelData,
                  Double(frameCount + Int64(pcm.frameLength)) / rate <= maximumAudioSeconds,
                  frameCount == 0 || (sampleRate == rate && channels == count)
            else { failure = "invalid_audio"; done = true; return }
            for channel in 0..<Int(count) {
                for frame in 0..<Int(pcm.frameLength) where !samples[channel][frame].isFinite {
                    failure = "invalid_audio"; done = true; return
                }
            }
            // Apply output volume to the actual PCM, independently of whether the
            // selected voice's write renderer honors its utterance volume setting.
            if request.volume != 1 {
                for channel in 0..<Int(count) {
                    for frame in 0..<Int(pcm.frameLength) { samples[channel][frame] *= Float(request.volume) }
                }
            }
            do {
                if writer == nil {
                    sampleRate = rate; channels = count
                    writer = try AVAudioFile(forWriting: request.output, settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: count,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                    ], commonFormat: .pcmFormatFloat32, interleaved: false)
                }
                try writer?.write(from: pcm)
                frameCount += Int64(pcm.frameLength)
            } catch { failure = "output_write_failed"; done = true }
        }
        while true {
            lock.lock()
            let finished = done
            lock.unlock()
            if finished { break }
            if ProcessInfo.processInfo.systemUptime - startedAt >= 85 {
                lock.lock(); failure = "synthesis_timeout"; done = true; lock.unlock()
                break
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        synthesizer.stopSpeaking(at: .immediate)
        if failure != nil { break }
    }
    lock.lock()
    writer = nil // Finalize the WAV header before reporting success.
    let resultFailure = failure
    lock.unlock()
    if let resultFailure { try reject(resultFailure) }
    guard frameCount > 0, sampleRate > 0, parentMatches(request),
          let file = metadata(request.output.path), file.st_uid == getuid(), file.st_mode & S_IFMT == S_IFREG,
          file.st_mode & 0o777 == 0o600, file.st_size > 44, file.st_size <= maximumOutputBytes,
          let readable = try? AVAudioFile(forReading: request.output), readable.length == frameCount,
          readable.fileFormat.sampleRate == sampleRate, readable.fileFormat.channelCount == channels
    else { try reject("invalid_output_audio") }
    succeeded = true
    return ["ok": true, "id": request.id, "provider": "apple-interpreter",
            "voiceIdentifier": voice.identifier, "voiceName": voice.name, "language": voice.language,
            "quality": voice.quality.rawValue, "rate": request.rate, "pitchMultiplier": request.pitchMultiplier,
            "volume": request.volume, "sentencePause": request.sentencePause,
            "sentenceCount": chunks.count, "pauseFrames": pauseFrames,
            "sampleRate": sampleRate, "channels": channels, "frameCount": frameCount,
            "durationSeconds": Double(frameCount) / sampleRate, "format": "wav"]
}

private func respond(_ input: Data) -> Bool {
    var requestID: String?
    startedAt = ProcessInfo.processInfo.systemUptime; alarm(90)
    do {
        let request = try readRequest(input); requestID = request.id
        emit(try synthesize(request)); return true
    } catch {
        var result: [String: Any] = ["ok": false, "reason": (error as? HelperFailure)?.reason ?? "helper_failed"]
        if let requestID { result["id"] = requestID }
        emit(result); return false
    }
}

if CommandLine.arguments.contains("--session") {
    // Interpretation is paid once per explicitly opened playback/Talk session.
    // Nothing is synthesized until the owner supplies a bounded frame. The
    // owner closes this process on Stop/shutdown and after 30 idle seconds.
    // Enumerate the chosen installed voice now, without rendering any audio.
    // Talk can overlap this one-time setup with local recognizer preparation.
    if let voice = AVSpeechSynthesisVoice(identifier: "com.apple.siri.natural.Simone") {
        preparedVoices[voice.identifier] = voice
    }
    emit(["ready": true, "version": 1])
    var buffered = Data(), requests = 0
    var bytes = [UInt8](repeating: 0, count: 4096)
    while requests < 10_000 {
        alarm(120)
        let count = read(STDIN_FILENO, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        buffered.append(contentsOf: bytes.prefix(count))
        guard buffered.count <= maximumRequestBytes else { _exit(65) }
        while let end = buffered.firstIndex(of: 10) {
            let frame = Data(buffered[..<end]); buffered.removeSubrange(...end)
            requests += 1
            guard requests <= 10_000, respond(frame) else { _exit(1) }
        }
    }
} else {
    var input = Data()
    while let chunk = try? FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
        guard input.count + chunk.count <= maximumRequestBytes else { _exit(65) }
        input.append(chunk)
    }
    if !respond(input) { _exit(1) }
}
alarm(0)
