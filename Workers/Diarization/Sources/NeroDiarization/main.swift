import Foundation
import AVFoundation
import MLX
import MLXAudioVAD

struct Segment: Codable { var start: Double; var end: Double; var speaker: Int }
@main enum Worker {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 4 else { throw NSError(domain: "Nero", code: 1) }
            let model = try SortformerModel.fromModelDirectory(URL(fileURLWithPath: CommandLine.arguments[1]))
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[2]))
            guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
                  file.length > 0, file.length <= 16000 * 4 * 3600 else { throw NSError(domain: "Nero", code: 2) }
            var state = model.initStreamingState(); var segments: [Segment] = []
            let block: AVAudioFrameCount = 81920
            while file.framePosition < file.length {
                let chunkStart = Double(file.framePosition) / 16000
                let frameOffset = Double(state.framesProcessed) * 0.08
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: block)!
                try file.read(into: buffer, frameCount: block)
                let audio = MLXArray(Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))))
                let (output, next) = try await model.feed(chunk: audio, state: state, minDuration: 0.2, mergeGap: 0.15)
                state = next
                for segment in output.segments {
                    let start = max(chunkStart, Double(segment.start) - frameOffset + chunkStart)
                    let end = min(Double(file.framePosition) / 16000, Double(segment.end) - frameOffset + chunkStart)
                    if end > start { segments.append(Segment(start: start, end: end, speaker: segment.speaker)) }
                }
                guard segments.count <= 100000 else { throw NSError(domain: "Nero", code: 3) }
                print("progress \(Double(file.framePosition) / Double(file.length))"); fflush(stdout)
            }
            try JSONEncoder().encode(segments).write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
        } catch { FileHandle.standardError.write(Data("Local speaker analysis failed: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
}
