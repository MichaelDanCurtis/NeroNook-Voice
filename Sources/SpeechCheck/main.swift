import Foundation
import VoiceAudio
@main struct Check {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else { print("Usage: SpeechCheck /path/to/synthetic-speech.aiff"); return }
        do {
            if CommandLine.arguments.contains("--meeting") {
                var count = 0
                try await MeetingTranscription.transcribe(URL(fileURLWithPath: CommandLine.arguments[1]), track: "mic", locale: "en-US") { line in count += 1; print("\(line.start)-\(line.end): \(line.text)") }
                guard count > 0 else { throw NSError(domain: "Meeting fixture produced no transcript", code: 1) }; return
            }
            let text = try await SpeechPipeline.transcribeFile(URL(fileURLWithPath: CommandLine.arguments[1]), locale: "en-US", simulateCapture: CommandLine.arguments.contains("--capture-pipeline")); print(text) }
        catch { print("Speech fixture unavailable: \(error.localizedDescription)"); exit(1) }
    }
}
