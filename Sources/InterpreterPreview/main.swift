import SwiftUI
import NookPluginSDK
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Darwin

@MainActor final class InterpreterPreviewModel: ObservableObject {
    @Published var status = "Prepare the local interpreter to begin."
    @Published var ready = false
    @Published var busy = false
    @Published var preparing = false
    @Published var recording = false
    @Published var target = "es"
    @Published var source: URL?
    @Published var original = ""
    @Published var translated = ""
    @Published var timing = ""
    @Published var output: URL?
    @Published var folder: URL?
    @Published var playing = false
    private var engine: Process?
    private var input: FileHandle?
    private var session = UUID()
    private var request: String?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var captureURL: URL?
    private var captureTimer: Task<Void,Never>?
    private var playbackTimer: Task<Void,Never>?
    private var deadline: Task<Void,Never>?
    let root: URL

    init() {
        let path = Bundle.main.url(forResource: "preview-root", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        root = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        sample()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
    }
    func sample() {
        source = root.appendingPathComponent("build/interpreter-fixtures/\(target == "es" ? "english" : "spanish").aiff")
        stopPlayback(); output = nil; folder = nil; original = ""; translated = ""; timing = ""
        if ready { status = "Sample selected · press Translate" }
    }
    func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { stopPlayback(); source = panel.url; output = nil; folder = nil; original = ""; translated = ""; timing = ""; status = ready ? "Audio selected · press Translate" : "Prepare the local interpreter to begin." }
    }
    func prepare() {
        guard engine == nil else { return }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Workers/Interpreter/engine.py").path) else { status = "The preview workspace is unavailable."; return }
        preparing = true; status = "Preparing local runtime…"; session = UUID(); let token = session
        let process = Process(); let stdin = Pipe(); let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", "(version 1)(allow default)(deny network*)", root.appendingPathComponent("build/interpreter-venv/bin/python").path, root.appendingPathComponent("Workers/Interpreter/engine.py").path]
        process.standardInput = stdin; process.standardOutput = stdout
        let logURL = root.appendingPathComponent("build/interpreter-preview.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        process.standardError = try? FileHandle(forWritingTo: logURL)
        var env = ProcessInfo.processInfo.environment.filter { key,_ in !["TOKEN","SECRET","API_KEY"].contains(where: key.uppercased().contains) }
        env["HF_HUB_OFFLINE"] = "1"; env["TRANSFORMERS_OFFLINE"] = "1"; env["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
        process.environment = env
        process.terminationHandler = { [weak self] _ in Task { @MainActor in
            guard let self, self.session == token else { return }
            self.engine = nil; self.input = nil; self.ready = false; self.preparing = false; self.busy = false
            self.deadline?.cancel(); self.status = "Interpreter stopped. Prepare again to retry."
        }}
        do {
            try process.run(); engine = process; input = stdin.fileHandleForWriting
            deadline?.cancel(); deadline = Task { try? await Task.sleep(for: .seconds(45)); if !Task.isCancelled && self.preparing { self.stop(); self.status = "Runtime preparation timed out." } }
            Task.detached { [weak self] in
                var pending = Data()
                while true {
                    let data = stdout.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    if pending.count > 65536 { await self?.stop(); break }
                    while let end = pending.firstIndex(of: 10) {
                        let line = pending[..<end]; pending.removeSubrange(...end)
                        guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String:Any] else { continue }
                        await self?.receive(event, token: token)
                    }
                }
            }
        } catch { preparing = false; status = error.localizedDescription }
    }
    func receive(_ event: [String:Any], token: UUID) {
        guard token == session else { return }
        let type = event["type"] as? String
        if type == "ready" { deadline?.cancel(); ready = true; preparing = false; status = "Ready · all processing stays on this Mac"; return }
        guard event["id"] as? String == request else { return }
        if type == "progress" { status = event["stage"] as? String ?? "Processing…" }
        if type == "error" { deadline?.cancel(); busy = false; status = event["error"] as? String ?? "Translation failed"; request = nil }
        if type == "result", let result = event["result"] as? [String:Any], let path = event["folder"] as? String {
            deadline?.cancel(); busy = false; request = nil
            original = result["sourceText"] as? String ?? ""; translated = result["translatedText"] as? String ?? ""
            folder = URL(fileURLWithPath: path); output = folder!.appendingPathComponent("translated.wav")
            let seconds = result["processingSeconds"] as? Double ?? 0
            timing = String(format: "%.1f s processing after the clip ended", seconds)
            status = "Translation ready · press Play to hear it"
        }
    }
    func translate() {
        guard ready, !busy, !recording, let source else { return }
        stopPlayback(); busy = true; output = nil; folder = nil; original = ""; translated = ""; timing = ""
        let id = UUID().uuidString.lowercased(); request = id
        do {
            let data = try JSONSerialization.data(withJSONObject: ["id":id,"source":source.path,"target":target]) + Data([10])
            try input?.write(contentsOf: data)
            status = "Recognizing speech…"
            deadline?.cancel(); deadline = Task { try? await Task.sleep(for: .seconds(95)); if !Task.isCancelled && self.request == id { self.stop(); self.status = "This phrase timed out. Its result was not played." } }
        } catch { busy = false; request = nil; status = error.localizedDescription }
    }
    func startRecording() {
        guard ready, !busy, !recording else { return }
        let token = session
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard token == self.session, self.ready, !self.busy else { return }
            guard granted else { self.status = "Allow microphone access to record a phrase."; return }
            do {
                self.stopPlayback()
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NeroInterpreterPreview", isDirectory:true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes:[.posixPermissions:0o700])
                let url = dir.appendingPathComponent(UUID().uuidString + ".caf")
                let recorder = try AVAudioRecorder(url:url, settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:16000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:32,AVLinearPCMIsFloatKey:true,AVLinearPCMIsBigEndianKey:false])
                guard recorder.record(forDuration:29) else { throw NSError(domain:"Microphone could not start",code:1) }
                self.recorder = recorder; self.captureURL = url; self.recording = true; self.status = "Recording a phrase · up to 29 seconds"
                self.captureTimer = Task { try? await Task.sleep(for:.seconds(29)); if !Task.isCancelled { self.finishRecording() } }
            } catch { self.status = error.localizedDescription }
        }
    }
    func finishRecording() {
        guard recording else { return }
        captureTimer?.cancel(); recorder?.stop(); recorder = nil; recording = false
        source = captureURL; status = "Phrase captured · press Translate"; output = nil
    }
    func play() {
        if playing { stopPlayback(); return }
        guard let output else { return }
        do {
            player = try AVAudioPlayer(contentsOf: output); playing = player?.play() == true
            playbackTimer = Task { while !Task.isCancelled && self.player?.isPlaying == true { try? await Task.sleep(for:.milliseconds(150)) }; if !Task.isCancelled { self.playing = false } }
        } catch { status = error.localizedDescription }
    }
    func stopPlayback() { playbackTimer?.cancel(); player?.stop(); player = nil; playing = false }
    func stop() {
        session = UUID(); request = nil; ready = false; busy = false; preparing = false
        deadline?.cancel(); captureTimer?.cancel(); recorder?.stop(); recorder = nil; recording = false; stopPlayback()
        let previous = engine; engine = nil; input?.closeFile(); input = nil
        if let previous, previous.isRunning {
            let pid = previous.processIdentifier
            // Terminate the entire private worker group, including an active ASR child.
            if kill(-pid,SIGTERM) != 0 { previous.terminate() }
            Task { try? await Task.sleep(for:.seconds(1)); if previous.isRunning { kill(-pid,SIGKILL); kill(pid,SIGKILL) } }
        }
        status = "Stopped · nothing is being sent to a meeting"
    }
}

final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct InterpreterPreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewAppDelegate.self) var delegate
    @StateObject var model = InterpreterPreviewModel()
    var body: some Scene {
        WindowGroup("Nero Interpreter Preview") {
            VStack(alignment:.leading,spacing:18) {
                HStack { Image(systemName:"waveform.circle.fill").font(.largeTitle).foregroundStyle(.mint); VStack(alignment:.leading) { Text("Live Interpreter").font(.title.bold()); Text("Local prototype · English ↔ Spanish").pluginSecondaryText() }; Spacer(); Text("PREVIEW").font(.caption.bold()).padding(8).background(.mint.opacity(0.15),in:Capsule()) }
                Picker("Direction",selection:$model.target) { Text("I speak English → Spanish").tag("es"); Text("They speak Spanish → English").tag("en") }.pickerStyle(.segmented).disabled(model.busy || model.recording).onChange(of:model.target) { _,_ in model.stopPlayback(); model.sample() }
                HStack { Button("Use sample") { model.sample() }; Button("Choose audio…") { model.chooseFile() }; Text(model.source?.lastPathComponent ?? "No audio selected").lineLimit(1).pluginSecondaryText(); Spacer() }.disabled(model.busy || model.recording)
                HStack(alignment:.top,spacing:16) {
                    GroupBox("Recognized speech") { ScrollView { Text(model.original.isEmpty ? "Your source speech will appear here." : model.original).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled).padding(8) }.frame(height:145) }
                    GroupBox("Translation") { ScrollView { Text(model.translated.isEmpty ? "The translation will appear here." : model.translated).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled).padding(8) }.frame(height:145) }
                }
                HStack {
                    if !model.ready { Button(model.preparing ? "Preparing…" : "Prepare interpreter") { model.prepare() }.disabled(model.preparing) }
                    Button(model.recording ? "Finish phrase" : "Record phrase") { if model.recording { model.finishRecording() } else { model.startRecording() } }.disabled(!model.ready || model.busy)
                    Button("Translate") { model.translate() }.pluginPrimaryAction().disabled(!model.ready || model.busy || model.recording || model.source == nil)
                    Button(model.playing ? "Stop playback" : "Play translation") { model.play() }.disabled(model.output == nil || model.busy || model.recording)
                    Spacer(); Button("Stop") { model.stop() }
                }
                HStack { if model.busy || model.preparing || model.recording { ProgressView().controlSize(.small) }; Text(model.status).lineLimit(2); Spacer() }.font(.callout)
                Text(model.timing.isEmpty ? "Nemotron 3.5 → Hy‑MT2 → Kokoro · MLX · one model at a time" : model.timing).font(.caption).pluginSecondaryText()
                Divider()
                Text("This preview accepts audio clips up to 30 seconds. Audio and results are saved locally for review. Playback uses your current Mac output. Teams is not connected; virtual microphone and speaker integration comes next.").font(.caption).pluginSecondaryText().fixedSize(horizontal:false,vertical:true)
                BridgeSetupView(root: model.root)
                if let folder=model.folder { Button("Show saved audio and timings") { NSWorkspace.shared.open(folder) }.font(.caption) }
            }.padding(24).frame(minWidth:780,minHeight:690).pluginThemed()
        }.defaultSize(width:820,height:720)
    }
}
