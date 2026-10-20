import Foundation
import AVFoundation
import MLX
import MLXAudioSTT
import MLXAudioCore

private struct Word: Encodable { let text: String; let start: Double; let end: Double }
private struct Utterance: Encodable {
    let id = UUID()
    let start: Double
    let end: Double
    let track: String
    let text: String
    let reviewed = false
    var words: [Word]? = nil
}

@main enum Worker {
    /// Two track sessions share one resident model. Short settled turns bound
    /// caches/text over a four-hour meeting; no whole-meeting PCM accumulation.
    static func meetingStream(parakeet: Bool, directory: String) throws {
        let nemo = parakeet ? nil : try NemotronASRModel.fromDirectory(URL(fileURLWithPath: directory))
        let para = parakeet ? try ParakeetModel.fromDirectory(URL(fileURLWithPath: directory)) : nil
        let input = FileHandle.standardInput
        func read(_ count: Int) throws -> Data {
            var result = Data()
            while result.count < count {
                guard let data = try input.read(upToCount: count - result.count), !data.isEmpty else { throw NSError(domain: "NeroMeetingStream", code: 1) }
                result.append(data)
            }
            return result
        }
        func emit(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value)
            guard data.count <= 32768 else { throw NSError(domain: "NeroMeetingStream", code: 2) }
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
        }
        var sessions: [String: NemotronASRStreamSession] = [:]
        var samples: [String: [Float]] = [:]
        var starts: [String: Double] = [:], ends: [String: Double] = [:], quiet: [String: Double] = [:]
        var processedThrough = 0.0
        var lastPartial: [String: String] = [:]
        func settle(_ track: String) throws {
            guard let start = starts[track], let end = ends[track] else { return }
            let text: String
            let segments: [[String: Any]]
            if let session = sessions[track] { _ = session.finish(); text = session.text; segments = session.segments }
            else if let para, let pcm = samples[track], !pcm.isEmpty {
                let result = para.generate(audio: MLXArray(pcm)); text = result.text; segments = result.segments ?? []
            } else { text = ""; segments = [] }
            guard text.utf8.count <= 16000 else { throw NSError(domain: "NeroMeetingStream", code: 3) }
            var payload: [String: Any] = ["type": "final", "track": track, "start": start, "end": end, "text": text]
            let words: [[String: Any]] = segments.flatMap { ($0["words"] as? [[String: Any]]) ?? [] }.compactMap { word in
                guard let value = word["text"] as? String, let lower = word["start"] as? Double, let upper = word["end"] as? Double,
                      lower.isFinite, upper.isFinite, upper >= lower else { return nil }
                let a = max(start, start + lower), b = min(end, start + upper)
                return b >= a ? ["text": value, "start": a, "end": b] : nil
            }
            // Speech alignment can omit whitespace-only tokenizer tokens.
            // The receiver reconciles exact source spacing before splitting turns.
            if !words.isEmpty { payload["words"] = words }
            try emit(payload)
            sessions[track] = nil; samples[track] = nil; starts[track] = nil; ends[track] = nil; quiet[track] = nil; lastPartial[track] = nil
        }
        try emit(["type": "ready", "version": 2])
        while true {
            let headerSize = try read(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
            if headerSize == 0 { break }
            guard headerSize <= 1024, let header = try JSONSerialization.jsonObject(with: read(headerSize)) as? [String: Any] else { throw NSError(domain: "NeroMeetingStream", code: 4) }
            if let command = header["command"] as? String {
                guard command == "commit", header.count == 2, let id = header["id"] as? String,
                      UUID(uuidString: id) != nil else { throw NSError(domain: "NeroMeetingStream", code: 7) }
                for track in ["mic", "system"] { try settle(track) }
                // Final text precedes the acknowledgement; every later partial
                // starts in a fresh model session on the next audio frame.
                try emit(["type": "committed", "id": id, "through": processedThrough])
                continue
            }
            guard
                  let track = header["track"] as? String, ["mic", "system"].contains(track),
                  let start = header["start"] as? Double, start.isFinite, start >= 0,
                  let count = header["length"] as? Int, count > 0, count <= 65536, count.isMultiple(of: 4),
                  start + Double(count / 4) / 16000 <= 14430 else { throw NSError(domain: "NeroMeetingStream", code: 4) }
            let data = try read(count)
            let pcm: [Float] = data.withUnsafeBytes { raw in (0..<(count / 4)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
            guard pcm.allSatisfy(\.isFinite) else { throw NSError(domain: "NeroMeetingStream", code: 5) }
            let duration = Double(pcm.count) / 16000, end = start + duration
            processedThrough = max(processedThrough, end)
            if let previous = ends[track], start - previous > 0.25 { try settle(track) }
            let energy = pcm.reduce(Float(0)) { $0 + $1 * $1 } / Float(pcm.count)
            let silent = energy < 0.00004
            if starts[track] == nil && silent { try emit(["type": "ack"]); continue }
            if starts[track] == nil {
                starts[track] = start
                if let nemo { sessions[track] = nemo.makeStreamSession(language: "auto", chunkMs: 560) }
            }
            ends[track] = end; quiet[track] = silent ? (quiet[track] ?? 0) + duration : 0
            if let session = sessions[track] {
                _ = session.step(pcm)
                let text = session.text
                guard text.utf8.count <= 16000 else { throw NSError(domain: "NeroMeetingStream", code: 6) }
                if !text.isEmpty, lastPartial[track] != text {
                    lastPartial[track] = text
                    try emit(["type": "partial", "track": track, "start": starts[track]!, "end": end, "text": text])
                }
            } else { samples[track, default: []].append(contentsOf: pcm) }
            let elapsed = end - starts[track]!
            if (quiet[track] ?? 0) >= 0.7 && elapsed >= 1 || elapsed >= (parakeet ? 10 : 20) { try settle(track) }
            try emit(["type": "ack"])
        }
        for track in ["mic", "system"] { try settle(track) }
        try emit(["type": "closed"])
    }
    static func stream() throws {
        let model = try NemotronASRModel.fromDirectory(URL(fileURLWithPath: CommandLine.arguments[2]))
        let session = model.makeStreamSession(language: "auto", chunkMs: 560)
        let input = FileHandle.standardInput
        func read(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let next = try input.read(upToCount: count - data.count), !next.isEmpty else { throw NSError(domain: "NeroStream", code: 1) }
                data.append(next)
            }
            return data
        }
        func emit(_ type: String) throws {
            guard session.text.utf8.count <= 2048 else { throw NSError(domain: "NeroStream", code: 2) }
            let data = try JSONSerialization.data(withJSONObject: ["type": type, "text": session.text])
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
        try emit("ready")
        var total = 0
        while true {
            let header = try read(4)
            let size = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
            if size == 0 { break }
            guard size <= 4_096_000, size.isMultiple(of: 4), total + size <= 4_096_000 else { throw NSError(domain: "NeroStream", code: 3) }
            let data = try read(size); total += size
            let samples: [Float] = data.withUnsafeBytes { raw in (0..<(size / 4)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
            _ = session.step(samples); try emit("partial")
        }
        _ = session.finish(); try emit("final")
    }

    static func main() async {
        if CommandLine.arguments.dropFirst().first == "--tts" { await QwenWorker.main(); return }
        do {
            let parakeet = CommandLine.arguments.contains("--parakeet")
            let arguments = CommandLine.arguments.filter { $0 != "--parakeet" }
            if arguments.count == 3, arguments[1] == "--stream" { try stream(); return }
            if arguments.count == 3, arguments[1] == "--meeting-stream" { try meetingStream(parakeet: parakeet, directory: arguments[2]); return }
            guard arguments.count == 5, ["mic", "system"].contains(arguments[4]) else {
                throw NSError(domain: "NeroNemotron", code: 1)
            }
            let model: any STTGenerationModel = parakeet
                ? try ParakeetModel.fromDirectory(URL(fileURLWithPath: arguments[1]))
                : try NemotronASRModel.fromDirectory(URL(fileURLWithPath: arguments[1]))
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[2]))
            guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                  file.processingFormat.commonFormat == .pcmFormatFloat32,
                  file.length > 0, file.length <= 16_000 * 4 * 3600 else {
                throw NSError(domain: "NeroNemotron", code: 2)
            }
            let track = arguments[4]
            var utterances: [Utterance] = []
            let block: AVAudioFrameCount = 60 * 16_000
            while file.framePosition < file.length {
                let offset = file.framePosition
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block)!
                try file.read(into: buffer, frameCount: block)
                let count = Int(buffer.frameLength)
                guard count > 0, let channel = buffer.floatChannelData?[0] else { break }
                // End a long chunk at the quietest 100 ms in its final ten seconds.
                // This keeps audio contiguous while reducing words cut at boundaries.
                var used = count
                if file.framePosition < file.length && count >= 20 * 16_000 {
                    let window = 1_600
                    var best = Float.greatestFiniteMagnitude
                    for end in stride(from: 51 * 16_000, through: count - window, by: 1_600) {
                        var energy: Float = 0
                        for sample in end..<(end + window) { energy += channel[sample] * channel[sample] }
                        if energy < best { best = energy; used = end + window / 2 }
                    }
                    file.framePosition = offset + Int64(used)
                }
                let samples = MLXArray(Array(UnsafeBufferPointer(start: channel, count: used)))
                let output = model.generate(audio: samples, generationParameters: model.defaultGenerationParameters)
                let chunkStart = Double(offset) / 16_000
                let chunkEnd = Double(offset + Int64(used)) / 16_000
                if let segments = output.segments, !segments.isEmpty {
                    for item in segments {
                        guard let text = item["text"] as? String,
                              let start = item["start"] as? Double,
                              let end = item["end"] as? Double else { continue }
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let lower = max(chunkStart, chunkStart + start)
                        let upper = min(chunkEnd, chunkStart + end)
                        if !trimmed.isEmpty && upper > lower && trimmed.utf8.count <= 16_000 {
                            let words = (item["words"] as? [[String: Any]])?.compactMap { word -> Word? in
                                guard let text = word["text"] as? String, let start = word["start"] as? Double, let end = word["end"] as? Double else { return nil }
                                let a = max(lower, chunkStart + start), b = min(upper, chunkStart + end)
                                return b > a ? Word(text: text, start: a, end: b) : nil
                            }
                            utterances.append(Utterance(start: lower, end: upper, track: track, text: trimmed, words: words))
                        }
                    }
                } else {
                    let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty && text.utf8.count <= 16_000 {
                        utterances.append(Utterance(start: chunkStart, end: chunkEnd, track: track, text: text))
                    }
                }
                guard utterances.count <= 40_000 else { throw NSError(domain: "NeroNemotron", code: 3) }
                print("progress \(Double(file.framePosition) / Double(file.length))"); fflush(stdout)
            }
            try JSONEncoder().encode(utterances).write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Local Parakeet transcription failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
