import Foundation
import ModuleCore
import NookPluginSDK

extension VoiceModel {
    var voiceDefinition: PluginCustomView {
        PluginCustomView(entry: "dictate/index.html", revision: "voice_22", state: [
            "microphone": .string(microphone),
            "microphones": .string(String(data: (try? JSONEncoder().encode(microphones.map { ["id": $0.id, "name": $0.displayName] })) ?? Data(), encoding: .utf8) ?? "[]"),
            "personal": .string(String(data: (try? JSONEncoder().encode(personalizationViewState)) ?? Data(), encoding: .utf8) ?? "{}"),
            "warmReady": .boolean(preloader.ready), "warmBusy": .boolean(preloader.preparing), "warmStatus": .string(preloader.status),
            "provider": .string(dictationASR.rawValue), "ready": .boolean(selectedModelReady),
            "busy": .boolean(busy), "recording": .boolean(session.recording), "level": .number(inputLevel),
            "status": .string(String(status.prefix(400))), "text": .string(session.transcript),
            "shortcut": .string(shortcutName), "shortcutPreset": .string(shortcut == .standard ? "fn" : shortcut == .optionCommand ? "optionCommand" : "custom"), "captionPlacement": .string(captionPlacement.rawValue), "style": .string(shortcutStyle == .hold ? "hold" : "toggle"),
            "preparing": .boolean(preparingAssets), "speaking": .boolean(speaking),
            "speechBackend": .string(speechBackend.rawValue), "qwenMode": .string(qwenOptions.mode.rawValue), "qwenSpeaker": .string(qwenSpeaker.rawValue), "qwenReady": .boolean(qwenReady),
            "speechVoice": .string(String(speechVoiceName.prefix(80))), "speechDelivery": .string(speechDelivery.rawValue)
        ], events: [
            .init("personal", input: .init([.init("command", .string), .init("page", .string, required: false), .init("app", .string, required: false), .init("tone", .string, required: false), .init("id", .string, required: false), .init("name", .string, required: false), .init("text", .string, required: false), .init("enabled", .boolean, required: false), .init("days", .number, required: false), .init("offset", .number, required: false)])),
            .init("shortcut", input: .init([.init("value", .string)])),
            .init("captions", input: .init([.init("value", .string)])),
            .init("speech", input: .init([.init("backend", .string, required: false), .init("speaker", .string, required: false)])),
            .init("provider", input: .init([.init("value", .string)])),
            .init("microphone", input: .init([.init("value", .string)])),
            .init("command", input: .init([.init("value", .string)])),
            .init("edit", input: .init([.init("text", .string)]))
        ], ownsChrome: true)
    }
    func handleVoice(_ event: PluginViewEvent) throws {
        guard event.panelID == "voice" else { throw VoiceProblem.message("Unknown voice view") }
        try voiceDefinition.validate(event)
        guard !CommandLine.arguments.contains("--protocol-test") else { return }
        if event.name == "microphone", case .string(let value) = event.values["value"] {
            guard !busy else { throw VoiceProblem.message("Stop the current speech activity before changing the microphone.") }
            refreshDevices()
            guard value.isEmpty || microphones.contains(where: { $0.id == value }) else { throw VoiceProblem.message("That microphone is no longer connected. Choose an available input.") }
            microphone = value; status = "Microphone selected"; changed?()
        } else if event.name == "speech", !busy {
            if case .string(let value) = event.values["backend"], let backend = SpeechBackend(rawValue: value) { chooseSpeechBackend(backend) }
            if case .string(let value) = event.values["speaker"], let speaker = QwenSpeaker(rawValue: value) { chooseQwenSpeaker(speaker) }
        } else if event.name == "shortcut", !busy, case .string(let value) = event.values["value"] {
            if value == "fn" { chooseShortcut(.standard) }
            else if value == "optionCommand" { chooseShortcut(.optionCommand) }
            else if value == "custom" { reveal?(); DispatchQueue.main.async { [weak self] in self?.settings = true } }
        } else if event.name == "captions", !busy, case .string(let value) = event.values["value"], let placement = PluginTransientCaption.Placement(rawValue: value) {
            captionPlacement = placement
        } else if event.name == "personal" { do { try handlePersonalization(event.values) } catch { personalizationStatus = error.localizedDescription } }
        else if event.name == "provider", case .string(let value) = event.values["value"], let provider = VoiceASRProvider(rawValue: value) {
            chooseASR(provider)
        } else if event.name == "edit", case .string(let text) = event.values["text"] { if !busy { edit(text) } }
        else if event.name == "command", case .string(let value) = event.values["value"] {
            switch value {
            case "qwenStudio": showQwenStudio?()
            case "prepareQwen": prepareQwen()
            case "releaseQwen": if !busy { releaseSpeakingModel() }
            case "prepare": prepareLocalModel()
            case "preload": prepareConversation()
            case "release_preload": releasePreparedSpeech()
            case "record": if session.recording { stopRecording() } else { record() }
            case "cancel": cancel()
            case "copy": try submit(["text": .string(session.transcript), "destination": .string("Copy"), "read_reply": .boolean(false)])
            case "clear": clear()
            case "read": if speaking { stopSpeaking(); status = "Reading stopped" } else { readDraft() }
            case "preview": if speaking { stopSpeaking(); status = "Reading stopped" } else { previewSpeech() }
            case "speechSettings":
                refreshDevices(); reveal?()
                DispatchQueue.main.async { [weak self] in self?.settings = true }
            default: break
            }
        }
    }
}
