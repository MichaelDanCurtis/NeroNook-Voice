import XCTest
import AVFoundation
import ModuleCore
@testable import VoiceAudio

final class QwenVoiceLibraryTests: XCTestCase {
    private func fixture(_ root: URL, seconds: Double = 4, silent: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString+".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds*48000))!
        buffer.frameLength = buffer.frameCapacity
        for c in 0..<2 { for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![c][i] = silent ? 0 : Float(sin(Double(i)*0.05))*0.1 } }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        return url
    }
    func testNormalizePersistVerifyArchiveRestoreAndOriginalPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(root), original = try Data(contentsOf: source), store = QwenVoiceLibrary(root: root.appendingPathComponent("Voices"))
        let profile = try store.save(source: source, name: "Test", transcript: "These are the reference words.")
        XCTAssertEqual(try QwenVoiceLibrary(root: store.root).list(), [profile])
        let (_, audio) = try store.reference(profile.id), file = try AVAudioFile(forReading: audio)
        XCTAssertEqual(file.processingFormat.sampleRate, 24000); XCTAssertEqual(file.processingFormat.channelCount, 1)
        try store.archive(profile.id); XCTAssertTrue(try store.list().isEmpty)
        XCTAssertThrowsError(try store.reference(profile.id)); try store.restore(profile.id)
        XCTAssertEqual(try store.reference(profile.id).0, profile)
        XCTAssertEqual(try Data(contentsOf: source), original)
        var bytes = try Data(contentsOf: audio); bytes[bytes.count-1] ^= 1; try bytes.write(to: audio)
        XCTAssertThrowsError(try store.reference(profile.id))
    }
    func testRejectSilentShortAndMissingTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let store = QwenVoiceLibrary(root: root.appendingPathComponent("Voices")), silent = try fixture(root, silent: true), short = try fixture(root, seconds: 1)
        XCTAssertThrowsError(try store.save(source: silent, name: "Silent", transcript: "Words"))
        XCTAssertThrowsError(try store.save(source: short, name: "Short", transcript: "Words"))
        XCTAssertThrowsError(try store.save(source: short, name: "Short", transcript: ""))
        XCTAssertTrue(try store.list().isEmpty)
    }
}
