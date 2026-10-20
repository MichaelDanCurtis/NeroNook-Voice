import SwiftUI
import NookPluginSDK
import AppKit
import Darwin

@MainActor final class BridgeSetupModel: ObservableObject {
    @Published var status = "Checking audio driver…"
    @Published var installed = false // Both devices currently enumerated by Core Audio.
    @Published var driverPresent = false
    @Published var busy = false
    private var process: Process?
    private var deadline: Task<Void,Never>?
    private var token = UUID()
    let root: URL
    init(root: URL) {
        self.root = root
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
    }
    func stop() {
        token = UUID(); deadline?.cancel(); if let process, process.isRunning { process.terminate() }
        process = nil; busy = false
    }
    func run(test: Bool = false) {
        guard !busy else { return }
        refreshDriverPresence()
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NeroBridgeCheck")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { status = "Rebuild the preview with its audio bridge helper."; return }
        busy = true; token = UUID(); let current = token
        status = test ? "Testing both virtual routes · no physical microphone or speakers used…" : "Checking audio driver…"
        let task = Process(), pipe = Pipe(); task.executableURL = helper; task.arguments = [test ? "--self-test" : "--list"]
        task.standardInput = FileHandle.nullDevice; task.standardOutput = pipe; task.standardError = pipe
        do {
            try task.run(); process = task
            deadline = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled && self.token == current && task.isRunning { kill(task.processIdentifier, SIGKILL) } }
            Task.detached { [weak self] in
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
                let text = String(decoding: data.prefix(16384), as: UTF8.self)
                await self?.finish(current, test: test, code: task.terminationStatus, text: text)
            }
        } catch { busy = false; status = error.localizedDescription }
    }
    private func finish(_ current: UUID, test: Bool, code: Int32, text: String) {
        guard token == current else { return }
        deadline?.cancel(); process = nil; busy = false
        guard code == 0 else { status = text.isEmpty ? "Bridge check stopped or timed out." : text; return }
        if test { status = "Passed: both audio routes, isolation, Stop, heartbeat expiry and restart. Translation-to-Teams is the next integration step." }
        else {
            guard let result = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String:Any], let loaded = result["installed"] as? Bool else {
                installed = false; status = "Could not read the audio device status. Refresh to retry."; return
            }
            installed = loaded
            if loaded { status = "Driver loaded · run the isolated audio check before using Teams." }
            else if driverPresent { status = "Driver installed, but not loaded by macOS yet. Restart your Mac when convenient, then Refresh. No need to reinstall." }
            else { status = "Audio driver not installed. Install it once, then Refresh." }
        }
    }
    private func refreshDriverPresence() {
        // Presence and HAL enumeration are different states. A pending restart must
        // never send the user through the first-install package again.
        let path = "/Library/Audio/Plug-Ins/HAL/NeroInterpreterAudio.driver"
        driverPresent = (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }
    func installer() {
        refreshDriverPresence()
        guard !driverPresent else { run(); return }
        let package = root.appendingPathComponent("build/interpreter-audio/NeroInterpreterAudio-0.1.0.pkg")
        if !NSWorkspace.shared.open(package) { status = "The installer package is unavailable. Rebuild the audio driver package." }
    }
}

struct BridgeSetupView: View {
    @StateObject private var model: BridgeSetupModel
    init(root: URL) { _model = StateObject(wrappedValue: BridgeSetupModel(root: root)) }
    var body: some View {
        GroupBox("Teams audio bridge · preview setup") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.status).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                HStack {
                    if !model.installed && !model.driverPresent { Button("Install audio driver…") { model.installer() } }
                    Button("Refresh") { model.run() }
                    Button("Check audio bridge") { model.run(test: true) }.disabled(!model.installed)
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer()
                }.disabled(model.busy)
            }.padding(6).frame(maxWidth:.infinity,alignment:.leading)
        }.task { model.run() }
    }
}
