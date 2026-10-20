import XCTest
import AVFoundation
import CryptoKit
import ModuleCore
@testable import VoiceAudio

final class MeetingImportTests: XCTestCase {
    func setup() throws -> (URL, MeetingStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try MeetingStore(root: root.appendingPathComponent("library")))
    }
    func audio(_ url: URL, seconds: Double = 32, compressed: Bool = false) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let settings: [String: Any] = compressed ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000] : format.settings
        let writer = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        var done = 0
        while done < Int(seconds * 48000) {
            buffer.frameLength = AVAudioFrameCount(min(4800, Int(seconds * 48000) - done))
            for channel in 0..<2 { for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][i] = Float(sin(Double(done + i) * 0.05) * 0.2) } }
            try writer.write(from: buffer); done += Int(buffer.frameLength)
        }
    }
    func testPCMImportNormalizesAudioRotatesChunksAndOwnsItAfterSourceRemoval() async throws {
        let (root, store) = try setup(), source = root.appendingPathComponent("Existing meeting.wav")
        try audio(source); let original = try Data(contentsOf: source)
        let m = try await MeetingRecordingImport.run(source: source, store: store)
        XCTAssertEqual(m.state, "saved"); XCTAssertEqual(m.source, "import"); XCTAssertFalse(m.microphone); XCTAssertEqual(m.title, "Existing meeting")
        XCTAssertEqual(m.chunks.count, 3); XCTAssertEqual(m.duration, 32, accuracy: 0.01); XCTAssertEqual(m.chunks.map(\.start), [0, 15, 30])
        XCTAssertEqual(try Data(contentsOf: source), original); XCTAssertEqual(try store.load(m.id), m)
        let origin = try XCTUnwrap(store.importOrigin(m.id)); XCTAssertEqual(origin.filename, source.lastPathComponent)
        XCTAssertEqual(origin.sha256, SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
        XCTAssertFalse(try String(contentsOf: store.folder(m.id).appendingPathComponent("import-v1.json"), encoding: .utf8).contains(root.path))
        try FileManager.default.removeItem(at: source)
        var frames: Int64 = 0
        for chunk in m.chunks {
            let file = try AVAudioFile(forReading: store.audio(chunk, meeting: m)); frames += file.length
            XCTAssertEqual(file.processingFormat.sampleRate, 16000); XCTAssertEqual(file.processingFormat.channelCount, 1)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!; try file.read(into: buffer)
            XCTAssertGreaterThan((0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max()!, 0.1)
        }
        // AVAssetReader's native sample-rate conversion rounds this tail by
        // three samples. Detect material loss without asserting invented audio.
        XCTAssertLessThanOrEqual(abs(frames - 512000), 4); XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.root.path).contains { $0.hasPrefix(".import-") })
    }
    func testAACImportAndDuplicateSelectionDoNotCreateAnotherMeeting() async throws {
        let (root, store) = try setup(), source = root.appendingPathComponent("Call.m4a")
        try audio(source, seconds: 2, compressed: true)
        let first = try await MeetingRecordingImport.run(source: source, store: store)
        XCTAssertEqual(first.duration, 2, accuracy: 0.05)
        let renamed = root.appendingPathComponent("Renamed.m4a"); try FileManager.default.moveItem(at: source, to: renamed)
        let second = try await MeetingRecordingImport.run(source: renamed, store: store)
        XCTAssertEqual(second.id, first.id); XCTAssertEqual(store.list().count, 1)
    }
    func testCancelledDecodeAndCorruptOrLinkedSourcesNeverPublishPartialMeetings() async throws {
        let (root, store) = try setup(), source = root.appendingPathComponent("Cancel.caf")
        try audio(source)
        let task = Task.detached {
            try await MeetingRecordingImport.run(source: source, store: store) { progress in
                if progress > 0.2 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must fail") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(store.list().isEmpty); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
        let bad = root.appendingPathComponent("Damaged.m4a"); try Data("Not audio".utf8).write(to: bad)
        do { _ = try await MeetingRecordingImport.run(source: bad, store: store); XCTFail("Corrupt audio must fail") } catch {}
        let linked = root.appendingPathComponent("Link.caf"); try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
        do { _ = try await MeetingRecordingImport.run(source: linked, store: store); XCTFail("Linked source must fail") } catch {}
        XCTAssertTrue(store.list().isEmpty); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testVideoRecordingImportsOnlyItsOwnedAudio() async throws {
        let (root, store) = try setup(), source = root.appendingPathComponent("Video meeting.mp4"), wave = root.appendingPathComponent("audio.m4a")
        try audio(wave, seconds: 2, compressed: true)
        let asset = AVURLAsset(url: wave), tracks = try await asset.loadTracks(withMediaType: .audio), reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        let firstSample = try XCTUnwrap(output.copyNextSampleBuffer())
        let writer = try AVAssetWriter(outputURL: source, fileType: .mp4)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: CMSampleBufferGetFormatDescription(firstSample))
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(audioInput); writer.add(videoInput); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?; XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(pixel!, []); memset(CVPixelBufferGetBaseAddress(pixel!)!, 96, CVPixelBufferGetDataSize(pixel!)); CVPixelBufferUnlockBaseAddress(pixel!, [])
        for i in 0..<2 {
            for _ in 0..<5000 where !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(i), timescale: 1)))
        }
        videoInput.markAsFinished()
        var currentSample: CMSampleBuffer? = firstSample
        while let sample = currentSample {
            for _ in 0..<5000 where !audioInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(audioInput.append(sample), writer.error?.localizedDescription ?? "Audio append"); currentSample = output.copyNextSampleBuffer()
        }
        audioInput.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
        let videoTracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .video); XCTAssertEqual(videoTracks.count, 1)
        let original = try Data(contentsOf: source), imported = try await MeetingRecordingImport.run(source: source, store: store)
        XCTAssertEqual(imported.duration, 2, accuracy: 0.05); XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: store.folder(imported.id).path)), Set(["meeting.json", "import-v1.json"] + imported.chunks.map(\.file)))
    }
}
