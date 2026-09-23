import Foundation
import VoiceAudio
@main struct Check {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else { print("Usage: SpeechCheck /path/to/synthetic-speech.aiff"); return }
        do { let text = try await SpeechPipeline.transcribeFile(URL(fileURLWithPath: CommandLine.arguments[1]), locale: "en-US", simulateCapture: CommandLine.arguments.contains("--capture-pipeline")); print(text) }
        catch { print("Speech fixture unavailable: \(error.localizedDescription)"); exit(1) }
    }
}
