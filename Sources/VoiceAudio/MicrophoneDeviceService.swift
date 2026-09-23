// Adapted from the owner's OmniVoice d3b5940; see PROVENANCE.md.
import AudioToolbox
import CoreAudio
import Foundation

public struct MicrophoneDevice: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let isDefault: Bool

    public var displayName: String {
        isDefault ? "\(name) (Default)" : name
    }
}

public enum MicrophoneDeviceService {
    public static func inputDevices() -> [MicrophoneDevice] {
        let defaultDeviceID = defaultInputDeviceID()
        return allDeviceIDs()
            .filter(hasInputChannels)
            .compactMap { deviceID in
                guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                      let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) else {
                    return nil
                }

                return MicrophoneDevice(id: uid, name: name, isDefault: deviceID == defaultDeviceID)
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public static func deviceID(for uid: String?) -> AudioDeviceID? {
        guard let uid else { return defaultInputDeviceID() }
        return allDeviceIDs().first { deviceID in
            stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }

    public static func nominalSampleRate(for uid: String?) -> Double? {
        guard let deviceID = deviceID(for: uid) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard status == noErr, sampleRate > 0 else { return nil }
        return sampleRate
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        )
        guard status == noErr else { return [] }
        return deviceIDs
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawPointer.deallocate()
        }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }

        return UnsafeMutableAudioBufferListPointer(bufferList).contains { buffer in
            buffer.mNumberChannels > 0
        }
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
