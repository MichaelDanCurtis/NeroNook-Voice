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
        guard serviceAllowsActivity(),!busy,!speaking else{return}
        let owner=LocalFoundationModelWork.currentOwner,epoch=UUID()
        referenceOwner=owner;referencePickerOwner=owner;referenceEpoch=epoch
        let panel=NSOpenPanel(),callback=VoiceFileCallback()
        referencePicker=panel;referencePickerCallback=callback
        fileWork.retain(callback.returned,owner:owner)
        panel.allowedContentTypes=[.audio];panel.allowsMultipleSelection=false
        panel.title="Choose 3–30 seconds of clear speech"
        guard fileWork.permits(owner),referencePicker === panel else{callback.abandonBeforeStart();return}
        panel.begin{[weak self] result in Task{@MainActor in
            callback.deliver{
                guard let self,self.referencePicker === panel,self.referenceEpoch == epoch else{return}
                self.referencePicker=nil;self.referencePickerCallback=nil
                guard result == .OK,let url=panel.url,!self.speaking else{return}
                self.adoptReferenceSource(url,owned:false,owner:owner)
                if self.referenceName.isEmpty{self.referenceName=String(url.deletingPathExtension().lastPathComponent.prefix(60))}
                self.status="Reference selected · enter the exact spoken words, then Save voice";self.changed?()
            }
        }}
    }
    func startQwenReference() {
        guard serviceAllowsActivity() else { return }
        guard !busy, !speaking else { return }
        let epoch = UUID(); referenceEpoch = epoch
        let owner=LocalFoundationModelWork.currentOwner;referenceOwner=owner
        referenceChecking = true; status = "Checking microphone permission…"
        referenceTimer = Task { [weak self] in
            guard let self,!Task.isCancelled else { return }
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
            } catch { if referenceEpoch == epoch {fileWork.recordFailure(owner);cancelReference();referenceRecording=false;status=error.localizedDescription;changed?()} }
        }
    }
    func finishQwenReference() {
        guard referenceRecording else{return}
        let owner=referenceOwner,epoch=UUID();referenceEpoch=epoch
        referenceTimer?.cancel();referenceTimer=nil;referenceRecording=false;referenceChecking=true
        let finished=referenceRecorder.finishOwned()
        let original=Task{[self] in
            do{
                let result=await finished.value;referenceFinishResult=(epoch,result)
                if case .failure=result{fileWork.recordFailure(owner)}
                let url=try result.get()
                guard referenceEpoch == epoch else{makeReferenceSource(url,owned:true,owner:owner).discard();return}
                adoptReferenceSource(url,owned:true,owner:owner)
                status="Recording stopped · enter its exact words, then Save voice"
            }catch{if referenceEpoch == epoch{status=error.localizedDescription}}
            if referenceEpoch == epoch{referenceChecking=false;changed?()}
        }
        fileWork.retain(original,owner:owner)
    }
    func adoptReferenceSource(_ url:URL,owned:Bool,owner:VoiceFoundationOwner){
        guard allowProductEffect(.externalFiles)else{return}
        discardReferenceSource()
        referenceInput=makeReferenceSource(url,owned:owned,owner:owner)
        referenceSource=url;referenceOwned=owned
    }
    func makeReferenceSource(_ url:URL,owned:Bool,owner:VoiceFoundationOwner)->VoiceOwnedFileSource{
        VoiceOwnedFileSource(url:url,owned:owned,failure:{[weak self] issue in
            if self?.referenceCleanupIssue == nil{self?.referenceCleanupIssue=issue}
            self?.fileWork.recordFailure(owner)
        })
    }
    func discardReferenceSource() {
        referenceInput?.discard();referenceInput=nil
        referenceSource=nil;referenceOwned=false
    }
    func cancelReference() {
        referenceEpoch=UUID();referenceTimer?.cancel();referenceTimer=nil
        let panel=referencePicker,callback=referencePickerCallback
        referencePicker=nil;referencePickerCallback=nil
        callback?.close{panel?.cancel(nil)}
        let owner=referenceOwner,original=referenceRecorder.ownedCancellationResult()
        if let returned=original.completion{
            let joined=Task{[self] in await returned.value;if original.issue() != nil{fileWork.recordFailure(owner)}}
            fileWork.retain(joined,owner:owner)
        }
        referenceRecording=false;referenceChecking=false;referenceSaving=false
    }
    func saveQwenReference() {
        guard serviceAllowsActivity(),!busy,!speaking,let source=referenceInput else{return}
        let owner=LocalFoundationModelWork.currentOwner,epoch=UUID()
        referenceOwner=owner;referenceEpoch=epoch
        let name=referenceName,transcript=referenceTranscript,url=source.url
        let library=configuration.qwenLibrary
        do{
            let consumer=try source.acquire()
            do{
                try fileWork.start(owner:owner,work:{Result{try library.save(source:url,name:name,transcript:transcript)}},cancelled:{source.release(consumer)}){[weak self,source] result in
                    defer{source.release(consumer)}
                    self?.referenceSaveResult=(epoch,owner,result)
                    if case .failure = result{self?.fileWork.recordFailure(owner)}
                    guard let self,self.referenceEpoch == epoch else{return}
                    self.referenceSaving=false
                    do{
                        let saved=try result.get();self.qwenProfiles=try self.fileWork.operation(owner:owner){try self.configuration.qwenLibrary.list()}
                        self.qwenOptions.cloneID=saved.id;self.qwenOptions.mode = .clone
                        self.discardReferenceSource();self.referenceName="";self.referenceTranscript=""
                        self.status="\(saved.name) saved on this Mac · ready to preview after preparing the cloning model"
                    }catch{self.status=error.localizedDescription}
                    self.changed?()
                }
                referenceSaving=true
            }catch{source.release(consumer);throw error}
        }catch{referenceSaving=false;status=error.localizedDescription;changed?()}
    }
    func archiveQwenReference() {
        guard serviceAllowsActivity(),!busy,!speaking,let id=qwenOptions.cloneID else{return}
        let owner=LocalFoundationModelWork.currentOwner
        do{
            try fileWork.afterOriginal(owner:owner,capture:{[self] in
                captureReferenceConsumer()
            },operation:{[self] in
                try configuration.qwenLibrary.archive(id);lastArchivedVoice=id
                qwenProfiles=try configuration.qwenLibrary.list();qwenOptions.cloneID=nil
                status="Voice archived · Undo is available";changed?()
            },failed:{[weak self] error in self?.status=error.localizedDescription;self?.changed?()})
        }catch{status=error.localizedDescription;changed?()}
    }
    func restoreQwenReference() {
        guard serviceAllowsActivity(),!busy,!speaking,let id=lastArchivedVoice else{return}
        let owner=LocalFoundationModelWork.currentOwner
        do{
            try fileWork.afterOriginal(owner:owner,capture:{[self] in
                captureReferenceConsumer()
            },operation:{[self] in
                try configuration.qwenLibrary.restore(id);lastArchivedVoice=nil
                qwenProfiles=try configuration.qwenLibrary.list();qwenOptions.cloneID=id
                status="Voice restored";changed?()
            },failed:{[weak self] error in self?.status=error.localizedDescription;self?.changed?()})
        }catch{status=error.localizedDescription;changed?()}
    }
}
