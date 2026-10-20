import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ModuleCore
import VoiceAudio

extension VoiceModel {
    func chooseQwenMode(_ mode: QwenMode) {
        guard !busy, !speaking else { return }
        qwenOptions.mode = mode; status = "\(mode.title) selected · one Qwen model at a time"
    }
    func importQwenReference() {
        guard !busy, !speaking else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.title = "Choose 3–30 seconds of clear speech"
        panel.begin { [weak self] result in Task { @MainActor in
            guard let self, result == .OK, let url = panel.url, !self.busy, !self.speaking else { return }
            self.discardReferenceSource(); self.referenceSource = url
            if self.referenceName.isEmpty { self.referenceName = String(url.deletingPathExtension().lastPathComponent.prefix(60)) }
            self.status = "Reference selected · enter the exact spoken words, then Save voice"; self.changed?()
        } }
    }
    func startQwenReference() {
        guard !busy, !speaking else { return }
        let epoch = UUID(); referenceEpoch = epoch
        referenceChecking = true; status = "Checking microphone permission…"
        referenceTimer = Task { [weak self] in
            guard let self else { return }
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled, referenceEpoch == epoch else { return }
            referenceChecking = false
            guard allowed else { status = "Allow Nero Voice microphone access in System Settings"; changed?(); return }
            do {
                discardReferenceSource(); try referenceRecorder.start(microphone: microphone.isEmpty ? nil : microphone)
                referenceRecording = true; referenceElapsed = 0; status = "Recording reference · microphone on · stops after 30 seconds"; changed?()
                for n in 1...30 {
                    try await Task.sleep(for: .seconds(1)); guard referenceEpoch == epoch, referenceRecording else { return }
                    referenceElapsed = n
                }
                finishQwenReference()
            } catch { if referenceEpoch == epoch { referenceRecorder.cancel(); referenceRecording = false; status = error.localizedDescription; changed?() } }
        }
    }
    func finishQwenReference() {
        guard referenceRecording else { return }
        referenceEpoch = UUID(); referenceTimer?.cancel(); referenceTimer = nil
        do { referenceSource = try referenceRecorder.finish(); referenceOwned = true; status = "Recording stopped · enter its exact words, then Save voice" }
        catch { status = error.localizedDescription }
        referenceRecording = false; changed?()
    }
    func discardReferenceSource() {
        if referenceOwned, let referenceSource { try? FileManager.default.removeItem(at: referenceSource) }
        referenceSource = nil; referenceOwned = false
    }
    func cancelReference() {
        referenceEpoch = UUID(); referenceTimer?.cancel(); referenceTimer = nil; referenceRecorder.cancel(); referenceRecording = false; referenceChecking = false; referenceSaving = false
    }
    func saveQwenReference() {
        guard !busy, !speaking, let source = referenceSource else { return }
        referenceSaving = true
        let epoch = UUID(); referenceEpoch = epoch
        let name = referenceName, transcript = referenceTranscript
        Task { [weak self] in
            let result = await Task.detached { Result { try QwenVoiceLibrary().save(source: source, name: name, transcript: transcript) } }.value
            guard let self, self.referenceEpoch == epoch else { return }; self.referenceSaving = false
            do {
                let saved = try result.get(); self.qwenProfiles = try QwenVoiceLibrary().list()
                self.qwenOptions.cloneID = saved.id; self.qwenOptions.mode = .clone
                self.discardReferenceSource(); self.referenceName = ""; self.referenceTranscript = ""
                self.status = "\(saved.name) saved on this Mac · ready to preview after preparing the cloning model"
            } catch { self.status = error.localizedDescription }
            self.changed?()
        }
    }
    func archiveQwenReference() {
        guard !busy, !speaking, let id = qwenOptions.cloneID else { return }
        do { try QwenVoiceLibrary().archive(id); lastArchivedVoice = id; qwenProfiles = try QwenVoiceLibrary().list(); qwenOptions.cloneID = nil; status = "Voice archived · Undo is available" }
        catch { status = error.localizedDescription }; changed?()
    }
    func restoreQwenReference() {
        guard !busy, !speaking, let id = lastArchivedVoice else { return }
        do { try QwenVoiceLibrary().restore(id); lastArchivedVoice = nil; qwenProfiles = try QwenVoiceLibrary().list(); qwenOptions.cloneID = id; status = "Voice restored" }
        catch { status = error.localizedDescription }; changed?()
    }
}
