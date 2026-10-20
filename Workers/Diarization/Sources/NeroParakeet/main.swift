import Foundation
import AVFoundation
import MLX
import MLXAudioSTT

private struct Utterance: Encodable {
    let id = UUID()
    let start: Double
    let end: Double
    let track: String
    let text: String
    let reviewed = false
}

@main enum Worker {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 5, ["mic", "system"].contains(CommandLine.arguments[4]) else {
                throw NSError(domain: "NeroParakeet", code: 1)
            }
            let model = try ParakeetModel.fromDirectory(URL(fileURLWithPath: CommandLine.arguments[1]))
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
            guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                  file.processingFormat.commonFormat == .pcmFormatFloat32,
                  file.length > 0, file.length <= 16_000 * 4 * 3600 else {
                throw NSError(domain: "NeroParakeet", code: 2)
            }
            let track = CommandLine.arguments[4]
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
                let output = model.generate(audio: samples)
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
                            utterances.append(Utterance(start: lower, end: upper, track: track, text: trimmed))
                        }
                    }
                } else {
                    let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty && text.utf8.count <= 16_000 {
                        utterances.append(Utterance(start: chunkStart, end: chunkEnd, track: track, text: text))
                    }
                }
                guard utterances.count <= 40_000 else { throw NSError(domain: "NeroParakeet", code: 3) }
                print("progress \(Double(file.framePosition) / Double(file.length))"); fflush(stdout)
            }
            try JSONEncoder().encode(utterances).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Local Parakeet transcription failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
