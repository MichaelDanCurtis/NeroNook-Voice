// Core Audio tap lifecycle adapted from owner's OmniVoice d3b5940.
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import ModuleCore

public struct MeetingAudioSource: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public enum MeetingSources {
    public static func available() -> [MeetingAudioSource] {
        var owners: [String: String] = [:]
        for process in MeetingProcessActivities.snapshot() where !process.appBundle.isEmpty && process.appBundle != "cafe.nero.plugin.voice" {
            owners[process.appBundle] = process.appName
        }
        return owners.map { MeetingAudioSource(id: $0.key, name: $0.value) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func processIDs(_ source: String) -> [AudioObjectID] {
        MeetingProcessActivities.snapshot().filter { $0.appBundle == source || $0.bundle == source }.map(\.object)
    }

}

private final class MeetingSystemTap: @unchecked Sendable {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private let callbackQueue = DispatchQueue(label: "cafe.nero.voice.system-audio")
    func start(source: String, receive: @escaping @Sendable (AVAudioPCMBuffer, Double) -> Void) throws {
        let description: CATapDescription
        if source == "all" { description = CATapDescription(stereoGlobalTapButExcludeProcesses: MeetingSources.processIDs("cafe.nero.plugin.voice")) }
        else {
            let ids = MeetingSources.processIDs(source)
            guard !ids.isEmpty else { throw VoiceProblem.message("The selected audio source is unavailable. Start audio in that app, then refresh sources.") }
            description = CATapDescription(stereoMixdownOfProcesses: ids)
        }
        description.name = "Nero Voice meeting"; description.isPrivate = true; description.muteBehavior = .unmuted
        var result = AudioHardwareCreateProcessTap(description, &tap)
        guard result == noErr else { throw VoiceProblem.message("Allow Nero Voice in Screen & System Audio Recording, then try again (\(result)).") }
        do {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout.size(ofValue: asbd))
            result = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
            guard result == noErr, let format = AVAudioFormat(streamDescription: &asbd), format.sampleRate >= 8000, format.sampleRate <= 192000, format.channelCount <= 8 else { throw VoiceProblem.message("System audio format unavailable") }
            let config: [String: Any] = [kAudioAggregateDeviceNameKey: "Nero Voice private recording", kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]], kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
            result = AudioHardwareCreateAggregateDevice(config as CFDictionary, &device)
            guard result == noErr else { throw VoiceProblem.message("Cannot start system-audio recorder (\(result))") }
            result = AudioDeviceCreateIOProcIDWithBlock(&io, device, callbackQueue) { _, input, timestamp, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                let time = timestamp.pointee.mHostTime > 0 ? AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime) : ProcessInfo.processInfo.systemUptime
                receive(buffer, time)
            }
            guard result == noErr, let io else { throw VoiceProblem.message("Cannot read system-audio buffers") }
            result = AudioDeviceStart(device, io)
            guard result == noErr else { throw VoiceProblem.message("System audio could not start (\(result)). Check its macOS recording permission.") }
        } catch { stop(); throw error }
    }
    func stop() {
        if let io, device != 0 { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }; io = nil
        if device != 0 { AudioHardwareDestroyAggregateDevice(device) }; device = 0
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }; tap = 0
    }
    deinit { stop() }
}

@MainActor public final class MeetingCapture {
    private var engine: AVAudioEngine?
    private var installedTap = false
    private var system: MeetingSystemTap?
    private var observer: NSObjectProtocol?
    public init() {}
    public func start(microphone: String?, includeMicrophone: Bool, systemSource: String, writer: MeetingAudioWriter, offset: Double, failure: @escaping @MainActor (String) -> Void) throws {
        let epoch = ProcessInfo.processInfo.systemUptime
        do {
            if systemSource != "none" {
                let tap = MeetingSystemTap(); system = tap
                try tap.start(source: systemSource) { buffer, time in writer.append(buffer, track: "system", start: offset + max(0, time - epoch)) }
            }
            if includeMicrophone {
                let engine = AVAudioEngine(); self.engine = engine
                guard var device = MicrophoneDeviceService.deviceID(for: microphone), let unit = engine.inputNode.audioUnit else { throw VoiceProblem.message("Selected microphone is unavailable") }
                var current = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
                let read = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
                if read != noErr || current != device {
                    let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device)))
                    guard result == noErr else { throw VoiceProblem.message("Cannot select microphone") }
                }
                let format = engine.inputNode.inputFormat(forBus: 0)
                guard format.sampleRate >= 8000, format.sampleRate <= 192000, format.channelCount > 0, format.channelCount <= 8 else { throw VoiceProblem.message("Microphone format unavailable") }
                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
                    let stamp = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime
                    writer.append(buffer, track: "mic", start: offset + max(0, stamp - epoch))
                }
                installedTap = true; engine.prepare(); try engine.start()
                observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in Task { @MainActor in
                    guard let self, let engine = self.engine else { return }
                    if engine.isRunning && engine.inputNode.inputFormat(forBus: 0) == format { return }
                    self.stop(); failure("Microphone changed. The partial recording is saved.")
                } }
            }
        } catch { stop(); throw error }
    }
    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        engine?.stop(); if installedTap { engine?.inputNode.removeTap(onBus: 0) }; installedTap = false; engine = nil
        system?.stop(); system = nil
    }
}
