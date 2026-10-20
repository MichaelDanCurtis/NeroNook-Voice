import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import ModuleCore

/// Streaming Apple media decoding; no microphone, upload or model invocation.
public enum MeetingRecordingImport {
    public static func run(source: URL, store: MeetingStore, progress: @Sendable (Double) -> Void = { _ in }) async throws -> Meeting {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let attrs = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, let size = attrs.fileSize, size > 0, size <= 2_000_000_000 else { throw VoiceProblem.message("Choose a regular audio or video file of up to 2 GB") }
        let parent = try store.root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parent.isDirectory == true, parent.isSymbolicLink != true else { throw VoiceProblem.message("Meeting library unavailable") }
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let length = try await asset.load(.duration).seconds
        try Task.checkCancellation()
        guard !tracks.isEmpty, tracks.count <= 8 else { throw VoiceProblem.message("This recording has no usable audio, or too many audio tracks") }
        guard length.isFinite, length > 0, length <= 14400 else { throw VoiceProblem.message("Import a recording shorter than four hours") }
        try capacity(store.root, needed: Int64(length * 16000 * 4) + 100_000_000)
        var hash = SHA256(), hashed = 0
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data); hashed += data.count
            guard hashed <= size else { throw VoiceProblem.message("The source recording changed during import") }
            progress(0.15 * Double(hashed) / Double(size))
        }
        guard hashed == size else { throw VoiceProblem.message("The source recording changed during import") }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        // A repeated selection is a no-op, including after the source was renamed.
        for meeting in store.list().prefix(10000) where meeting.source == "import" {
            try Task.checkCancellation()
            if let origin = try? store.importOrigin(meeting.id), origin.sha256 == digest, origin.bytes == size { progress(1); return meeting }
        }
        var meeting = Meeting(title: source.deletingPathExtension().lastPathComponent, source: "import", microphone: false)
        let staging = store.root.appendingPathComponent(".import-" + meeting.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedStore = try MeetingStore(root: staging); try stagedStore.save(meeting)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        guard reader.canAdd(output) else { throw VoiceProblem.message("This recording’s audio format is not supported") }
        reader.add(output); guard reader.startReading() else { throw VoiceProblem.message(reader.error?.localizedDescription ?? "Cannot decode this recording") }
        defer { reader.cancelReading() }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        var writer: AVAudioFile?, chunkFrames = 0, totalFrames = 0, serial = 0, chunkName = ""
        func closeChunk() throws {
            guard chunkFrames > 0 else { return }; writer = nil
            meeting.chunks.append(.init(file: chunkName, track: "system", start: Double(totalFrames - chunkFrames) / 16000, duration: Double(chunkFrames) / 16000))
            chunkFrames = 0
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let description = CMSampleBufferGetFormatDescription(sample), let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  basic.pointee.mSampleRate == 16000, basic.pointee.mChannelsPerFrame == 1, basic.pointee.mBitsPerChannel == 32,
                  basic.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  let block = CMSampleBufferGetDataBuffer(sample) else { throw VoiceProblem.message("The decoded recording is not readable PCM audio") }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0, frames <= 524288, CMBlockBufferGetDataLength(block) == frames * 4, totalFrames + frames <= 14400 * 16000 else { throw VoiceProblem.message("Decoded audio exceeds the import limit") }
            var offset = 0
            while offset < frames {
                try Task.checkCancellation()
                if writer == nil {
                    try capacity(store.root, needed: 100_000_000)
                    serial += 1; chunkName = "system-\(serial)-\(Int(Double(totalFrames) / 16)).caf"
                    let url = stagedStore.folder(meeting.id).appendingPathComponent(chunkName)
                    writer = try AVAudioFile(forWriting: url, settings: format.settings)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
                let count = min(frames - offset, 240000 - chunkFrames)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let pointer = buffer.floatChannelData?[0] else { throw VoiceProblem.message("Cannot allocate an import audio buffer") }
                buffer.frameLength = AVAudioFrameCount(count)
                guard CMBlockBufferCopyDataBytes(block, atOffset: offset * 4, dataLength: count * 4, destination: pointer) == kCMBlockBufferNoErr else { throw VoiceProblem.message("Cannot read decoded recording audio") }
                try writer!.write(from: buffer); totalFrames += count; chunkFrames += count; offset += count
                if chunkFrames == 240000 { try closeChunk() }
            }
            progress(min(0.98, 0.15 + 0.83 * Double(totalFrames) / (16000 * length)))
        }
        guard reader.status == .completed, totalFrames > 0 else { throw VoiceProblem.message(reader.error?.localizedDescription ?? "Recording import did not finish") }
        try closeChunk(); try Task.checkCancellation()
        let finalAttrs = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard finalAttrs.fileSize == size, finalAttrs.contentModificationDate == attrs.contentModificationDate else { throw VoiceProblem.message("The source recording changed during import") }
        meeting.state = "saved"; try stagedStore.save(meeting)
        let origin = MeetingImportOrigin(meetingID: meeting.id, filename: source.lastPathComponent, bytes: size, sha256: digest); try origin.validate()
        let originURL = stagedStore.folder(meeting.id).appendingPathComponent("import-v1.json")
        try JSONEncoder().encode(origin).write(to: originURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: originURL.path)
        for chunk in meeting.chunks { _ = try stagedStore.audio(chunk, meeting: meeting) }
        try Task.checkCancellation()
        // Only complete, owned recordings become visible in the library.
        try FileManager.default.moveItem(at: stagedStore.folder(meeting.id), to: store.folder(meeting.id))
        progress(1); return meeting
    }
    private static func capacity(_ root: URL, needed: Int64) throws {
        let free = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        guard let free, free >= needed else { throw VoiceProblem.message("Not enough free disk space to import this recording") }
    }
}
