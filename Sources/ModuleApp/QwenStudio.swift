import SwiftUI
import NookPluginSDK
import ModuleCore

struct QwenStudio: View {
    @ObservedObject var model: VoiceModel
    private var editingDisabled: Bool { model.busy || model.speaking }
    var body: some View {
        PluginSettingsPage("Qwen Voice Studio", subtitle: "Create a voice, clone a local reference, or choose a preset.", symbol: "waveform", width: 780, height: 700) {
                    HStack {
                        if model.speechBackend == .qwen { Label("Selected for Nero", systemImage: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                        else { Button("Use Qwen for Nero") { model.chooseSpeechBackend(.qwen) }.disabled(editingDisabled) }
                    }
                    Picker("Voice source", selection: Binding(get: { model.qwenOptions.mode }, set: model.chooseQwenMode)) {
                        ForEach(QwenMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).disabled(editingDisabled)
                    PluginSettingsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            if model.qwenOptions.mode == .preset {
                                Picker("Voice", selection: Binding(get: { model.qwenSpeaker }, set: model.chooseQwenSpeaker)) {
                                    ForEach(QwenSpeaker.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                                TextField("Style instruction · optional", text: $model.qwenOptions.instruction, axis: .vertical).lineLimit(2...3)
                                Text("Describe delivery, emotion or accent. For example: warm, conversational and unhurried.").font(.caption).pluginSecondaryText()
                            } else if model.qwenOptions.mode == .design {
                                Text("Describe the voice").font(.headline)
                                TextField("A warm female voice, low register, clear English, calm and conversational…", text: $model.qwenOptions.instruction, axis: .vertical).lineLimit(3...5)
                                Text("Uses Qwen VoiceDesign. The description creates a voice for each utterance; it is not a saved speaker identity.").font(.caption).pluginSecondaryText()
                            } else {
                                HStack {
                                    Picker("Saved voice", selection: $model.qwenOptions.cloneID) {
                                        Text("Choose a voice").tag(Optional<UUID>.none)
                                        ForEach(model.qwenProfiles) { Text($0.name).tag(Optional($0.id)) }
                                    }
                                    Button("Archive") { model.archiveQwenReference() }.disabled(model.qwenOptions.cloneID == nil)
                                    if model.lastArchivedVoice != nil { Button("Undo archive") { model.restoreQwenReference() } }
                                }
                                if let p = model.qwenProfiles.first(where: { $0.id == model.qwenOptions.cloneID }) {
                                    Text("\(p.seconds, specifier: "%.1f") seconds · reference and transcript saved on this Mac").font(.caption).pluginSecondaryText()
                                }
                            }
                            HStack {
                                Picker("Speaking language", selection: $model.qwenOptions.language) { ForEach(QwenOptions.languages, id: \.self) { Text($0) } }
                                if model.qwenOptions.mode != .clone {
                                    Picker("Delivery", selection: $model.speechDelivery) { ForEach(SpeechDelivery.allCases, id: \.self) { Text($0.title).tag($0) } }
                                }
                            }
                            if model.qwenOptions.mode == .clone { Text("Cloning follows the reference voice. Style instructions and Delivery apply to presets and described voices.").font(.caption).pluginSecondaryText() }
                        }.padding(10).disabled(editingDisabled)
                    }
                    if model.qwenOptions.mode == .clone {
                        PluginSettingsSection("Add a reference voice") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Use 3–30 seconds of clear speech and write exactly what is said. Short, quiet recordings work best.").font(.callout).pluginSecondaryText()
                                HStack {
                                    Button("Import audio…") { model.importQwenReference() }.disabled(editingDisabled)
                                    if model.referenceRecording {
                                        Label("Recording · \(model.referenceElapsed)s / 30s", systemImage: "record.circle.fill").foregroundStyle(.red)
                                        Button("Stop recording") { model.finishQwenReference() }
                                    } else { Button("Record microphone") { model.startQwenReference() }.disabled(editingDisabled) }
                                    Spacer()
                                    Text(model.referenceSource?.lastPathComponent ?? "No recording selected").font(.caption).pluginSecondaryText().lineLimit(1)
                                }
                                TextField("Voice name", text: $model.referenceName).disabled(editingDisabled)
                                TextField("Exact words spoken in the reference recording", text: $model.referenceTranscript, axis: .vertical).lineLimit(3...5).disabled(editingDisabled)
                                HStack {
                                    Button("Save voice") { model.saveQwenReference() }.disabled(editingDisabled || model.referenceSource == nil || model.referenceName.isEmpty || model.referenceTranscript.isEmpty)
                                    Text("The original file is preserved. Nero stores its own local copy.").font(.caption).pluginSecondaryText()
                                }
                            }.padding(10)
                        }
                    }
                    PluginSettingsSection("Listen") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Preview text", text: $model.qwenPreview, axis: .vertical).lineLimit(2...4).disabled(editingDisabled)
                            HStack {
                                Button(model.speaking ? "Stop" : "Preview Qwen") {
                                    if model.speaking { model.stopSpeaking() }
                                    else { model.chooseSpeechBackend(.qwen); model.speakText(model.qwenPreview) }
                                }.pluginPrimaryAction().disabled(model.busy || (!model.speaking && !model.qwenReady))
                                Button(model.qwenReady ? "Prepare selected model" : "Download & prepare · about 3.1 GB") { model.prepareQwen() }.disabled(editingDisabled)
                                Button("Release model") { model.releaseSpeakingModel() }.disabled(editingDisabled)
                            }
                            Text("One Qwen model in memory at a time. Switching modes unloads it. Each downloaded model uses about 3.1 GB of disk; unused models stay unloaded.").font(.caption).pluginSecondaryText()
                        }.padding(10)
                    }
                    PluginAdvancedSection(detail: "Generation controls trade consistency, variety and startup delay. Defaults suit most voices.") {
                        VStack(alignment: .leading, spacing: 14) {
                            control("Temperature", value: $model.qwenOptions.temperature, range: 0...1.5, detail: "Lower is steadier; higher varies the delivery.")
                            control("Top P", value: $model.qwenOptions.topP, range: 0.1...1, detail: "Limits the range of likely speech tokens.")
                            Stepper("Top K · \(model.qwenOptions.topK) · 0 uses the model default", value: $model.qwenOptions.topK, in: 0...100)
                            control("Repetition penalty", value: $model.qwenOptions.repetitionPenalty, range: 1...1.5, detail: "Discourages repeated sounds.")
                            Stepper("Generation limit · \(model.qwenOptions.maxTokens) tokens", value: $model.qwenOptions.maxTokens, in: 128...1800, step: 128)
                            control("Audio chunk interval", value: $model.qwenOptions.streamingInterval, range: 0.16...1, detail: "Seconds. Smaller chunks can start sooner, with more overhead.")
                            Button("Reset advanced settings") {
                                var v = QwenOptions(); v.mode = model.qwenOptions.mode; v.cloneID = model.qwenOptions.cloneID; v.language = model.qwenOptions.language; v.instruction = model.qwenOptions.instruction; model.qwenOptions = v
                            }
                        }.padding(.top, 14).disabled(editingDisabled)
                    }
        } footer: {
            HStack { Text(model.status).font(.caption).pluginSecondaryText().lineLimit(2); Spacer(); if model.busy { Button("Cancel") { model.cancel() } } }.padding(16)
        }
        .onDisappear { model.cancelReference() }
    }
    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue, format: .number.precision(.fractionLength(2))).monospacedDigit() }
            Slider(value: value, in: range, step: 0.01)
            Text(detail).font(.caption).pluginSecondaryText()
        }
    }
}
