import Foundation
import CryptoKit
import ModuleCore
import VoiceAudio

/// Offline authored-data probe. Never included in the plugin bundle; no model
/// preparation, recording, preference access, meeting-store writes or providers.
@main struct MeetingQualityCheck {
    struct Fixture: Decodable { let id: String; let names: [String: String]; let turns: [[String?]] }
    struct Receipt: Codable { let fixture: String; let inputSHA256: String; let seconds: Double; let notebook: MeetingNotebook?; let resolvedSources: Int; let error: String? }
    static func main() async throws {
        if Bundle.main.bundleIdentifier == "cafe.nero.review.meeting-tasks", let url = Bundle.main.resourceURL?.appendingPathComponent("MeetingReview.json") {
            let paths = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
            guard let resources = paths["resources"], let output = paths["output"] else { return }
            try await MeetingViewReview.run(resources: URL(fileURLWithPath: resources), output: URL(fileURLWithPath: output)); return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--view" {
            try await MeetingViewReview.run(resources: URL(fileURLWithPath: CommandLine.arguments[2]), output: URL(fileURLWithPath: CommandLine.arguments[3])); return
        }
        guard CommandLine.arguments.count == 3 else { print("Usage: MeetingQualityCheck frozen-gold.json output-directory"); return }
        let input = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let bytes = try Data(contentsOf: input)
        guard bytes.count <= 65_536 else { throw VoiceProblem.message("Fixture input exceeded its bound") }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: bytes)
        guard fixtures.count <= 8, Set(fixtures.map(\.id)).count == fixtures.count,
              fixtures.allSatisfy({ $0.id.range(of: "^[a-z0-9-]{1,60}$", options: .regularExpression) != nil && $0.turns.count <= 300 }) else { throw VoiceProblem.message("Invalid authored fixture") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        for (index, fixture) in fixtures.enumerated() {
            let file = output.appendingPathComponent(fixture.id + ".json")
            guard !FileManager.default.fileExists(atPath: file.path) else { throw VoiceProblem.message("Refusing to overwrite a prior result") }
            var transcript = MeetingTranscript(locale: "en-US"); transcript.names = fixture.names
            for (turn, fields) in fixture.turns.enumerated() {
                guard fields.count == 3, let track = fields[0], let text = fields[2] else { throw VoiceProblem.message("Invalid fixture turn") }
                var line = MeetingUtterance(start: Double(turn * 8), end: Double(turn * 8 + 7), track: track, text: text)
                line.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index * 1000 + turn))!; line.speaker = fields[1]
                transcript.utterances.append(line)
            }
            try transcript.validate()
            let began = ProcessInfo.processInfo.systemUptime
            let receipt: Receipt
            do {
                let notes = try await MeetingSummarizer.draft(transcript, meetingID: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", index))!) { _ in }
                var resolved = 0
                for item in notes.evidence ?? [] { _ = try item.resolve(in: transcript, digest: notes.sourceDigest); resolved += 1 }
                receipt = Receipt(fixture: fixture.id, inputSHA256: digest, seconds: ProcessInfo.processInfo.systemUptime - began, notebook: notes, resolvedSources: resolved, error: nil)
            } catch {
                receipt = Receipt(fixture: fixture.id, inputSHA256: digest, seconds: ProcessInfo.processInfo.systemUptime - began, notebook: nil, resolvedSources: 0, error: error.localizedDescription)
            }
            try encoder.encode(receipt).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            print("\(fixture.id): \(receipt.error == nil ? "generated" : "failed") · \(String(format: "%.2f", receipt.seconds)) s · \(receipt.resolvedSources) verified source links")
        }
    }
}
