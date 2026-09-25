import Foundation
import AVFoundation
import Speech
import ModuleCore

public enum MeetingTranscription {
    /// Construct a track on disk using bounded buffers, retaining gaps on the shared timeline.
    public static func assemble(_ meeting: Meeting, track: String, store: MeetingStore, to url: URL) async throws {
        let work = Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let output = try AVAudioFile(forWriting: url, settings: format.settings)
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            memset(silence.floatChannelData![0], 0, 16000 * 4)
            var position: Int64 = 0
            for chunk in meeting.chunks.filter({ $0.track == track }).sorted(by: { $0.start < $1.start }) {
                try Task.checkCancellation()
                let file = try AVAudioFile(forReading: store.audio(chunk, meeting: meeting))
                guard file.processingFormat == format, file.length <= 20 * 16000 else { throw VoiceProblem.message("Unsupported meeting audio") }
                let start = Int64((chunk.start * 16000).rounded())
                while position < start {
                    try Task.checkCancellation(); silence.frameLength = AVAudioFrameCount(min(16000, start - position)); try output.write(from: silence); position += Int64(silence.frameLength)
                }
                file.framePosition = min(file.length, max(0, position - start))
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
                while file.framePosition < file.length {
                    try Task.checkCancellation(); try file.read(into: buffer, frameCount: 16000); try output.write(from: buffer); position += Int64(buffer.frameLength)
                }
            }
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    @MainActor public static func transcribe(_ url: URL, track: String, locale: String, result: @escaping @MainActor (MeetingUtterance) throws -> Void) async throws {
        let transcriber = try await SpeechPipeline.prepare(localeIdentifier: locale, install: false)
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let task = Task { @MainActor in
            for try await value in transcriber.results where value.isFinal {
                try Task.checkCancellation(); let start = value.range.start.seconds; let end = CMTimeRangeGetEnd(value.range).seconds
                let text = String(value.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { try result(MeetingUtterance(start: start, end: end, track: track, text: text)) }
            }
        }
        try await withTaskCancellationHandler {
            do { try await analyzer.start(inputAudioFile: file, finishAfterFile: true); try await task.value; try Task.checkCancellation() }
            catch { task.cancel(); await analyzer.cancelAndFinishNow(); throw error }
        } onCancel: { task.cancel(); Task { await analyzer.cancelAndFinishNow() } }
    }
}
