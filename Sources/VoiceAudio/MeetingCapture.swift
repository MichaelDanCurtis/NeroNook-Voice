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

// Tracks callbacks admitted before stop. Closing the gate before native stop
// prevents a late callback from touching the writer; drain joins callbacks
// which were already in flight. It makes no claim about Apple broker state.
private final class MeetingCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private let pending = DispatchGroup()
    private var closed = false
    func enter() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        pending.enter(); return true
    }
    func leave() { pending.leave() }
    func close() { lock.lock(); closed = true; lock.unlock() }
    func drain() async {
        await withCheckedContinuation { continuation in
            pending.notify(queue: .global()) { continuation.resume() }
        }
    }
}

public struct MeetingCaptureStopResult: Sendable {
    public let systemStatuses: [Int32]
    // This records our stop/removeTap calls returning, not broker silence.
    public let microphoneStopReturned: Bool
    // A reentrant Stop inside native start cannot be promoted to a proven
    // stop result solely from the earlier call's return.
    public let stoppedDuringStart: Bool
}

private final class MeetingSystemTap: @unchecked Sendable {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var stoppedStatuses: [Int32]?
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
            func requireCurrent() throws { if stoppedStatuses != nil { throw CancellationError() } }
            try requireCurrent()
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
            var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout.size(ofValue: asbd))
            result = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
            guard result == noErr, let format = AVAudioFormat(streamDescription: &asbd), format.sampleRate >= 8000, format.sampleRate <= 192000, format.channelCount <= 8 else { throw VoiceProblem.message("System audio format unavailable") }
            try requireCurrent()
            let config: [String: Any] = [kAudioAggregateDeviceNameKey: "Nero Voice private recording", kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]], kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
            result = AudioHardwareCreateAggregateDevice(config as CFDictionary, &device)
            guard result == noErr else { throw VoiceProblem.message("Cannot start system-audio recorder (\(result))") }
            try requireCurrent()
            result = AudioDeviceCreateIOProcIDWithBlock(&io, device, callbackQueue) { _, input, timestamp, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                let time = timestamp.pointee.mHostTime > 0 ? AVAudioTime.seconds(forHostTime: timestamp.pointee.mHostTime) : ProcessInfo.processInfo.systemUptime
                receive(buffer, time)
            }
            guard result == noErr, let io else { throw VoiceProblem.message("Cannot read system-audio buffers") }
            try requireCurrent()
            result = AudioDeviceStart(device, io)
            guard result == noErr else { throw VoiceProblem.message("System audio could not start (\(result)). Check its macOS recording permission.") }
            try requireCurrent()
        } catch { stop(); throw error }
    }
    @discardableResult func stop() -> [Int32] {
        // A reentrant stop can precede a native setup call returning a new
        // object. Revisit any late IDs without forgetting earlier statuses.
        var statuses = stoppedStatuses ?? []
        if let io, device != 0 {
            statuses.append(AudioDeviceStop(device, io))
            statuses.append(AudioDeviceDestroyIOProcID(device, io))
        }; io = nil
        if device != 0 { statuses.append(AudioHardwareDestroyAggregateDevice(device)) }; device = 0
        if tap != 0 { statuses.append(AudioHardwareDestroyProcessTap(tap)) }; tap = 0
        stoppedStatuses = statuses
        return statuses
    }
    deinit { stop() }
}

@MainActor public final class MeetingCapture {
    private var engine: AVAudioEngine?
    private var installedTap = false
    private var system: MeetingSystemTap?
    private var observer: NSObjectProtocol?
    private var callbackGate = MeetingCallbackGate()
    private let observerCallbacks = VoiceAudioCallbackAdmission()
    private var stoppedResult: MeetingCaptureStopResult?
    private var starting = false
    private var stopping = false
    private var startAttempted = false
    private var interruptedStart = false
    private var handlingStartFailure = false
    public init() {}
    public func start(microphone: String?, includeMicrophone: Bool, systemSource: String, writer: MeetingAudioWriter, offset: Double, failure: @escaping @MainActor (String) -> Void) throws {
        guard stoppedResult == nil, !stopping, !starting, !startAttempted else { throw CancellationError() }
        startAttempted = true; starting = true; defer { starting = false }
        let epoch = ProcessInfo.processInfo.systemUptime
        let gate = callbackGate
        func requireCurrent() throws { if stoppedResult != nil || stopping { throw CancellationError() } }
        do {
            if systemSource != "none" {
                let tap = MeetingSystemTap(); system = tap
                do {
                    try tap.start(source: systemSource) { buffer, time in
                        guard gate.enter() else { return }; defer { gate.leave() }
                        writer.append(buffer, track: "system", start: offset + max(0, time - epoch))
                    }
                    try requireCurrent()
                } catch {
                    let finalStatuses = tap.stop()
                    if let prior = stoppedResult {
                        stoppedResult = MeetingCaptureStopResult(systemStatuses: finalStatuses,
                            microphoneStopReturned: prior.microphoneStopReturned, stoppedDuringStart: prior.stoppedDuringStart)
                    }
                    throw error
                }
            }
            try requireCurrent()
            if includeMicrophone {
                let engine = AVAudioEngine(); self.engine = engine
                guard var device = MicrophoneDeviceService.deviceID(for: microphone), let unit = engine.inputNode.audioUnit else { throw VoiceProblem.message("Selected microphone is unavailable") }
                var current = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
                let read = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &size)
                if read != noErr || current != device {
                    let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout.size(ofValue: device)))
                    guard result == noErr else { throw VoiceProblem.message("Cannot select microphone") }
                }
                try requireCurrent()
                let format = engine.inputNode.inputFormat(forBus: 0)
                guard format.sampleRate >= 8000, format.sampleRate <= 192000, format.channelCount > 0, format.channelCount <= 8 else { throw VoiceProblem.message("Microphone format unavailable") }
                try requireCurrent()
                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
                    guard gate.enter() else { return }; defer { gate.leave() }
                    let stamp = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : ProcessInfo.processInfo.systemUptime
                    writer.append(buffer, track: "mic", start: offset + max(0, stamp - epoch))
                }
                installedTap = true
                if stoppedResult != nil { engine.stop(); engine.inputNode.removeTap(onBus: 0); installedTap = false; throw CancellationError() }
                try requireCurrent(); engine.prepare(); try requireCurrent(); try engine.start()
                if stoppedResult != nil {
                    // A stop that reentered the start call cannot rely on its
                    // earlier stop. Issue our late stop as well; the result
                    // remains explicitly uncertain for this attempt.
                    engine.stop(); engine.inputNode.removeTap(onBus: 0)
                    throw CancellationError()
                }
                let callbacks = observerCallbacks
                let registered = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                    guard let entered = callbacks.enter() else { return }
                    Task { @MainActor in
                        defer { entered.finish() }
                        guard let self, let engine = self.engine else { return }
                        if engine.isRunning && engine.inputNode.inputFormat(forBus: 0) == format { return }
                        self.stop(); failure("Microphone changed. The partial recording is saved.")
                    }
                }
                if stoppedResult != nil || stopping {
                    NotificationCenter.default.removeObserver(registered)
                    throw CancellationError()
                }
                observer = registered
            }
        } catch {
            handlingStartFailure = true; stop(); handlingStartFailure = false
            throw error
        }
    }
    public func stop() {
        guard stoppedResult == nil, !stopping else { return }
        stopping = true
        if starting && !handlingStartFailure { interruptedStart = true }
        callbackGate.close(); observerCallbacks.seal()
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        engine?.stop(); if installedTap { engine?.inputNode.removeTap(onBus: 0) }; installedTap = false; engine = nil
        let statuses = system?.stop() ?? []; system = nil
        stoppedResult = MeetingCaptureStopResult(systemStatuses: statuses, microphoneStopReturned: true, stoppedDuringStart: interruptedStart)
        stopping = false; observerCallbacks.nativeStopReturned()
    }
    // Join the actual writer callbacks admitted before stop. The explicit result
    // remains conservative about AVAudioEngine and failed Core Audio operations.
    public func stopAndDrain() async -> MeetingCaptureStopResult {
        stop()
        await callbackGate.drain(); await observerCallbacks.waitForReturn()
        return stoppedResult!
    }
}
