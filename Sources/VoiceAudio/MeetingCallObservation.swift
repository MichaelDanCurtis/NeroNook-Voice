import AppKit
import ApplicationServices
import Foundation
import ModuleCore

/// A narrow observer: public audio activity plus call button metadata inside
/// Teams. It never reads messages, form values, participants, or audio samples.
public enum MeetingCallObservation {
    private struct App: Sendable { var pid: pid_t; var source: String; var name: String; var browser: Bool; var dedicated: Bool }
    private static let teams = Set(["com.microsoft.teams2", "com.microsoft.teams"])
    private static let browsers = Set(["com.google.Chrome", "com.microsoft.edgemac", "com.apple.Safari", "org.mozilla.firefox", "company.thebrowser.Browser"])
    @MainActor public static func sample() async -> MeetingCallSignal? {
        guard !Task.isCancelled else { return nil }
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> App? in
            guard let id = app.bundleIdentifier else { return nil }
            if teams.contains(id) { return .init(pid: app.processIdentifier, source: id, name: "Microsoft Teams", browser: false, dedicated: true) }
            if browsers.contains(id) { return .init(pid: app.processIdentifier, source: id, name: app.localizedName ?? "Browser", browser: true, dedicated: false) }
            // Chrome app shims share the browser's audio engine. Never describe
            // their Core Audio source as an isolated tab/application recording.
            if id.hasPrefix("com.google.Chrome.app."), app.localizedName?.localizedCaseInsensitiveContains("Microsoft Teams") == true {
                return .init(pid: app.processIdentifier, source: "com.google.Chrome", name: "Teams in Chrome", browser: true, dedicated: true)
            }
            return nil
        }
        guard !Task.isCancelled, !apps.isEmpty else { return nil }
        let work = Task.detached(priority: .utility) { () -> MeetingCallSignal? in
            guard !Task.isCancelled else { return nil }
            let audio = MeetingProcessActivities.snapshot()
            var possible: MeetingCallSignal?
            for app in apps.sorted(by: { !$0.browser && $1.browser }) {
                if Task.isCancelled { return nil }
                let input = audio.contains { $0.appBundle == app.source && $0.input }
                let buttons = inspect(app)
                if buttons.inCall { return .init(source: app.source, appName: app.name, browserWide: app.browser, evidence: .callControls) }
                // A native microphone-use fallback is explicitly lower confidence.
                // Browser microphone activity alone is never attributed to Teams.
                if !app.browser, input, !buttons.available {
                    possible = .init(source: app.source, appName: app.name, evidence: .microphoneActivity)
                }
            }
            return possible
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
    private static func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
    }
    private static func elements(_ value: CFTypeRef?) -> [AXUIElement] { value as? [AXUIElement] ?? [] }
    private static func inspect(_ app: App) -> (available: Bool, inCall: Bool) {
        guard AXIsProcessTrusted() else { return (false, false) }
        let root = AXUIElementCreateApplication(app.pid); AXUIElementSetMessagingTimeout(root, 0.1)
        let windows = elements(attribute(root, kAXWindowsAttribute))
        guard !windows.isEmpty else { return (false, false) }
        // Absolute per-app deadline bounds slow/unresponsive third-party trees.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        for window in windows.prefix(6) {
            var stack: [(AXUIElement, Bool)] = [(window, app.dedicated)], count = 0
            var endCall = false, microphone = false, strongEnd = false
            while let (node, inherited) = stack.popLast(), count < 600 {
                guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return (false, false) }
                count += 1
                let role = attribute(node, kAXRoleAttribute) as? String ?? ""
                var context = inherited
                if role == "AXWebArea", app.browser {
                    let raw = attribute(node, kAXURLAttribute)
                    let url = raw as? URL ?? (raw as? String).flatMap(URL.init(string:))
                    if let host = url?.host?.lowercased(), url?.scheme == "https" {
                        context = ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"].contains(host)
                    }
                    guard context else { continue }
                }
                if role == kAXButtonRole && context {
                    let id = (attribute(node, kAXIdentifierAttribute) as? String ?? "").lowercased()
                    let label = ((attribute(node, kAXTitleAttribute) as? String) ?? (attribute(node, kAXDescriptionAttribute) as? String) ?? "").lowercased()
                    strongEnd = strongEnd || id.contains("hangup") || id.contains("hang-up") || id.contains("leave-call") || id.contains("end-call")
                    endCall = endCall || ["leave", "hang up", "end call", "leave call"].contains(label)
                    microphone = microphone || id.contains("microphone") || id.contains("call-mute") || ["mute", "unmute", "turn microphone on", "turn microphone off"].contains(label)
                }
                for child in elements(attribute(node, kAXChildrenAttribute)).prefix(100) { stack.append((child, context)) }
            }
            if strongEnd || (endCall && microphone) { return (true, true) }
        }
        return (true, false)
    }
}
