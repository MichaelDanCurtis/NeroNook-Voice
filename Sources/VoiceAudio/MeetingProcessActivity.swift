import AppKit
import CoreAudio
import Darwin
import Foundation

public struct MeetingProcessActivity: Sendable {
    public var object: AudioObjectID
    public var pid: pid_t
    public var bundle: String
    public var input: Bool
    public var output: Bool
    public var appBundle: String
    public var appName: String
}

/// Public Core Audio metadata only. No tap, recording permission prompt or audio
/// samples are needed to tell whether an app currently owns an input/output.
public enum MeetingProcessActivities {
    static func objects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size <= 65536, size % 4 == 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size / 4))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &values) == noErr else { return [] }
        return values
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var value: CFString?; var size = UInt32(MemoryLayout<CFString?>.size)
        let result = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        return result == noErr ? value as String? ?? "" : ""
    }
    static func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var value: UInt32 = 0; var size: UInt32 = 4
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }
    static func application(_ pid: pid_t) -> Bundle? {
        var path = [CChar](repeating: 0, count: 4096 /* libproc maximum path buffer */)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let url = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
        // The outer application owns nested helper apps; no prefix-only bundle
        // match can pull unrelated applications into an audio selection.
        var candidate = URL(fileURLWithPath: "/")
        for part in url.pathComponents.dropFirst() {
            candidate.appendPathComponent(part)
            if part.hasSuffix(".app"), let bundle = Bundle(url: candidate) { return bundle }
        }
        return nil
    }
    public static func snapshot() -> [MeetingProcessActivity] {
        objects().compactMap { object in
            let pid = pid_t(bitPattern: number(object, kAudioProcessPropertyPID))
            guard pid > 0 else { return nil }
            let bundle = string(object, kAudioProcessPropertyBundleID), owner = application(pid)
            let appBundle = owner?.bundleIdentifier ?? bundle
            return .init(object: object, pid: pid, bundle: bundle,
                input: number(object, kAudioProcessPropertyIsRunningInput) != 0,
                output: number(object, kAudioProcessPropertyIsRunningOutput) != 0,
                appBundle: appBundle, appName: owner?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? owner?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? appBundle)
        }
    }
}
