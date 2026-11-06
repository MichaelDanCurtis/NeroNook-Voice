import AppKit
import SwiftUI
import NookPluginSDK
import VoiceAudio

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class DictationOverlayBindings {
    private weak var surface:AnyObject?
    private var token:UUID?
    func bind(_ original:AnyObject,token:UUID){surface=original;self.token=token}
    func permits(_ original:AnyObject,token:UUID)->Bool{surface === original && self.token==token}
    func invalidate(){surface=nil;token=nil}
}

@MainActor final class DictationOverlay {
    private var panel:NSPanel?
    private var hosting:NSHostingView<AnyView>?
    private let bindings=DictationOverlayBindings()
    private var panelPresentation:UUID?
    private let appearanceStore:PluginAppearanceStore?
    private let presentationAllowed:@MainActor ()->Bool
    private let callbacks=VoiceAudioCallbackAdmission()
    private var generation=UUID()
    private var closed=false
    private var originalRetirement:Task<Bool,Never>?
    init(appearanceStore:PluginAppearanceStore?=nil,presentationAllowed:@escaping @MainActor ()->Bool={true}){
        self.appearanceStore=appearanceStore;self.presentationAllowed=presentationAllowed
    }
    private func current(_ token:UUID)->Bool{!closed && generation==token && presentationAllowed() && !closed && generation==token}
    private func discardIfUnowned(_ candidate:NSPanel){
        if panel === candidate{if panelPresentation == nil{candidate.orderOut(nil)};return}
        candidate.orderOut(nil);candidate.contentView=nil;candidate.close()
    }
    func show(model:VoiceModel){
        guard !closed,presentationAllowed(),let original=callbacks.enter()else{return};defer{original.finish()}
        let token=UUID();generation=token;panelPresentation=token;bindings.invalidate()
        guard current(token)else{return}
        if panel == nil{
            let p=DictationPanel(contentRect:NSRect(x:0,y:0,width:420,height:154),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            guard current(token)else{discardIfUnowned(p);return}
            panel=p
            p.isOpaque=false
            guard current(token)else{discardIfUnowned(p);return}
            p.backgroundColor = .clear
            guard current(token)else{discardIfUnowned(p);return}
            p.hasShadow=true
            guard current(token)else{discardIfUnowned(p);return}
            p.level = .floating
            guard current(token)else{discardIfUnowned(p);return}
            p.hidesOnDeactivate=false
            guard current(token)else{discardIfUnowned(p);return}
            p.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            guard current(token)else{discardIfUnowned(p);return}
        }
        guard current(token),let originalPanel=panel else{return}
        bindings.bind(originalPanel,token:token)
        let store=appearanceStore ?? .shared
        guard current(token)else{discardIfUnowned(originalPanel);return}
        let root=AnyView(DictationOverlayView(model:model,perform:{[weak self,weak originalPanel]work in self?.perform(panel:originalPanel,token:token,work:work)}).pluginThemed(store:store,background:false))
        if let hosting{hosting.rootView=root}else{
            let created=NSHostingView(rootView:root)
            guard current(token)else{discardIfUnowned(originalPanel);return}
            hosting=created
        }
        guard current(token)else{discardIfUnowned(originalPanel);return}
        originalPanel.contentView=hosting
        guard current(token)else{discardIfUnowned(originalPanel);return}
        if !originalPanel.isVisible{
            guard current(token)else{discardIfUnowned(originalPanel);return}
            let screen=NSScreen.screens.first{$0.frame.contains(NSEvent.mouseLocation)} ?? NSScreen.main
            guard current(token)else{discardIfUnowned(originalPanel);return}
            if let rect=screen?.visibleFrame{
                originalPanel.setFrameOrigin(NSPoint(x:rect.midX-210,y:rect.minY+42))
            }
        }
        guard current(token),panel === originalPanel else{discardIfUnowned(originalPanel);return}
        originalPanel.orderFrontRegardless() // Preserve the destination keyboard focus.
        if !current(token) || panel !== originalPanel{discardIfUnowned(originalPanel)}
    }
    private func perform(panel originalPanel:NSPanel?,token:UUID,work:()->Void){
        guard current(token),let originalPanel,panel === originalPanel,bindings.permits(originalPanel,token:token),
              let original=callbacks.enter()else{return};defer{original.finish()}
        guard current(token),panel === originalPanel,bindings.permits(originalPanel,token:token)else{return}
        work()
    }
    func hide(){
        guard !closed,let original=callbacks.enter()else{return};defer{original.finish()}
        generation=UUID();panelPresentation=nil;bindings.invalidate();let originalPanel=panel;originalPanel?.orderOut(nil)
    }
    func sealPresentationForRetirement()->Task<Bool,Never>{
        if let originalRetirement{return originalRetirement}
        closed=true;generation=UUID();bindings.invalidate();callbacks.seal()
        let originalPanel=panel,originalHost=hosting;panel=nil;hosting=nil;panelPresentation=nil
        let original=Task {await callbacks.waitForReturn();_ = originalPanel;_ = originalHost;return true}
        originalRetirement=original
        originalPanel?.orderOut(nil);originalPanel?.contentView=nil;originalPanel?.close()
        callbacks.nativeStopReturned()
        return original
    }
}

private struct DictationOverlayView: View {
    @Environment(\.pluginAppearance) private var appearance
    @ObservedObject var model: VoiceModel
    let perform:(@escaping ()->Void)->Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.session.phase == .listening ? "waveform" : "mic.fill").foregroundStyle(Color(pluginHex: appearance.palette.accent))
                Text(model.session.recording ? "Dictating to \(model.targetName)" : "Nero Voice").font(.callout.bold())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { perform{model.dismissOverlay()} } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss dictation")
            }
            Text(model.status).font(.caption).pluginSecondaryText().lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text(model.overlayText ?? (model.session.transcript.isEmpty ? "Your words will appear here" : model.session.transcript))
                .font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if model.session.recording || model.inserting {
                    Button("Stop") { perform{model.stopRecording()} }.disabled(!model.session.recording || model.session.phase == .finishing)
                    Button("Cancel") { perform{model.cancel()} }
                } else {
                    Button("Open Voice") { perform{model.dismissOverlay();model.reveal?()} }
                }
                Spacer()
                Text("ON DEVICE").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(pluginHex: appearance.palette.accent))
            }.font(.caption)
        }.padding(16).frame(width: 420, height: 154).background(Color(pluginHex: appearance.palette.surface), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.12)))
    }
}
