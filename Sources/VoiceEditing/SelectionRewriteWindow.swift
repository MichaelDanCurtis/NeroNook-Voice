import AppKit
import SwiftUI
import ModuleCore
import NookPluginSDK

/// Tracks the actual original synchronous presentation/delegate frames. It
/// carries no native window or editor capability and can be tested in isolation.
@MainActor final class SelectionPresentationAdmission {
    private(set) var closed=false
    private var generation=UUID()
    private var entered=0
    private weak var surface:AnyObject?
    private var waiters:[CheckedContinuation<Void,Never>]=[]
    func begin()->UUID?{guard !closed else{return nil};entered += 1;generation=UUID();return generation}
    func enterCallback()->Bool{guard !closed else{return false};entered += 1;return true}
    func finish(){entered -= 1;if closed && entered==0{let old=waiters;waiters.removeAll();for waiter in old{waiter.resume()}}}
    func current(_ token:UUID)->Bool{!closed && generation==token}
    func bind(_ original:AnyObject,token:UUID){guard current(token)else{return};surface=original}
    func permits(_ original:AnyObject,token:UUID)->Bool{current(token) && surface === original}
    func invalidate(){generation=UUID();surface=nil}
    func seal(){closed=true;invalidate()}
    func holdTeardownReturn(){entered += 1;seal()}
    func retirement()async{if entered==0{return};await withCheckedContinuation{waiters.append($0)}}
}

@MainActor private final class SelectionCloseDelegate:NSObject,NSWindowDelegate {
    let close:(Notification)->Void
    init(close:@escaping(Notification)->Void){self.close=close}
    func windowWillClose(_ notification:Notification){close(notification)}
}

@MainActor public final class SelectionRewriteWindow:NSObject,NSWindowDelegate {
    private let model:SelectionRewrite
    private let appearanceStore:PluginAppearanceStore?
    private let presentationAllowed:@MainActor ()->Bool
    let presentationAdmission=SelectionPresentationAdmission()
    private var window:NSWindow?
    private var hosting:NSHostingView<AnyView>?
    private var originalDelegate:SelectionCloseDelegate?
    private var visibleGeneration:UUID?
    private var originalRetirement:Task<Bool,Never>?
    public init(model:SelectionRewrite,appearanceStore:PluginAppearanceStore?=nil,presentationAllowed:@escaping @MainActor ()->Bool={true}){
        self.model=model;self.appearanceStore=appearanceStore;self.presentationAllowed=presentationAllowed
    }
    private func current(_ token:UUID)->Bool{presentationAdmission.current(token) && presentationAllowed() && presentationAdmission.current(token)}
    private func discardIfUnowned(_ candidate:NSWindow){
        if window === candidate{if visibleGeneration==nil{candidate.orderOut(nil)};return}
        candidate.delegate=nil;candidate.contentView=nil;candidate.close()
    }
    public func show(){
        guard presentationAllowed(),let token=presentationAdmission.begin()else{return};defer{presentationAdmission.finish()}
        visibleGeneration=token
        guard current(token)else{return}
        if window == nil{
            let original=NSWindow(contentRect:.init(x:0,y:0,width:620,height:540),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            guard current(token)else{discardIfUnowned(original);return}
            window=original
            original.title="Nero Voice · Rewrite selection"
            guard current(token)else{discardIfUnowned(original);return}
            original.isReleasedWhenClosed=false
            guard current(token)else{discardIfUnowned(original);return}
            original.minSize = .init(width:480,height:480)
            guard current(token)else{discardIfUnowned(original);return}
            original.level = .floating
            guard current(token)else{discardIfUnowned(original);return}
            original.collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
            guard current(token)else{discardIfUnowned(original);return}
        }
        guard current(token),let original=window else{return}
        presentationAdmission.bind(original,token:token)
        let delegate=SelectionCloseDelegate{[weak self,weak original] note in
            guard let original else{return};self?.closeOriginal(note,surface:original,token:token)
        }
        originalDelegate=delegate;original.delegate=delegate
        guard current(token)else{discardIfUnowned(original);return}
        let store=appearanceStore ?? .shared
        guard current(token)else{discardIfUnowned(original);return}
        let root=AnyView(SelectionRewriteView(model:model,
            close:{[weak self,weak original]in self?.requestClose(surface:original,token:token)},
            perform:{[weak self,weak original]work in self?.performAction(surface:original,token:token,work:work)}).pluginThemed(store:store))
        if let hosting{hosting.rootView=root}
        else{
            let created=NSHostingView(rootView:root)
            guard current(token)else{discardIfUnowned(original);return}
            hosting=created
        }
        guard current(token)else{discardIfUnowned(original);return}
        original.contentView=hosting
        guard current(token)else{discardIfUnowned(original);return}
        let screen=NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main
        guard current(token)else{discardIfUnowned(original);return}
        if let screen{
            let frame=screen.visibleFrame
            guard current(token)else{discardIfUnowned(original);return}
            original.setFrameOrigin(.init(x:max(frame.minX,frame.midX-original.frame.width/2),y:max(frame.minY,frame.midY-original.frame.height/2)))
        }
        guard current(token)else{discardIfUnowned(original);return}
        NSApp.activate(ignoringOtherApps:true)
        guard current(token)else{discardIfUnowned(original);return}
        original.makeKeyAndOrderFront(nil)
        if !current(token){discardIfUnowned(original)}
    }
    public func hide(){
        guard presentationAdmission.enterCallback()else{return};defer{presentationAdmission.finish()}
        presentationAdmission.invalidate();visibleGeneration=nil;window?.orderOut(nil)
    }
    private func performAction(surface:NSWindow?,token:UUID,work:()->Void){
        guard let surface,current(token),presentationAdmission.permits(surface,token:token),presentationAdmission.enterCallback()else{return}
        defer{presentationAdmission.finish()}
        guard current(token),window === surface,presentationAdmission.permits(surface,token:token)else{return}
        work()
    }
    private func requestClose(surface:NSWindow?,token:UUID){
        guard let surface else{return}
        performAction(surface:surface,token:token){
            visibleGeneration=nil;presentationAdmission.invalidate();model.close(returnToEditor:true)
        }
    }
    private func closeOriginal(_ notification:Notification,surface:NSWindow,token:UUID){
        guard (notification.object as? NSWindow) === surface else{return}
        requestClose(surface:surface,token:token)
    }
    public func windowWillClose(_ notification:Notification){
        // Source-compatible direct delegate entry; actual native registration
        // uses the immutable per-presentation delegate above.
        guard let surface=window,let token=visibleGeneration else{return}
        closeOriginal(notification,surface:surface,token:token)
    }
    public func sealForRetirement()->Task<Bool,Never>{
        if let originalRetirement{return originalRetirement}
        presentationAdmission.holdTeardownReturn();defer{presentationAdmission.finish()}
        visibleGeneration=nil
        let originalWindow=window,originalHost=hosting,delegate=originalDelegate;window=nil;hosting=nil;originalDelegate=nil
        let original=Task {await presentationAdmission.retirement();_ = originalWindow;_ = originalHost;_ = delegate;return true}
        originalRetirement=original
        // No late window delegate can restore editor focus during global Stop.
        originalWindow?.delegate=nil;originalWindow?.contentView=nil;originalWindow?.close()
        return original
    }
}

public struct SelectionRewriteView: View {
    @ObservedObject private var model: SelectionRewrite
    private let close:()->Void
    private let perform:(@escaping ()->Void)->Void
    public init(model:SelectionRewrite,close:(()->Void)?=nil,perform:@escaping (@escaping ()->Void)->Void={ $0() }){self.model=model;self.close=close ?? {model.close(returnToEditor:true)};self.perform=perform}
    var operationBinding:Binding<SelectionTransformation>{
        Binding(get:{model.operation},set:{value in perform{model.operation=value}})
    }
    var resultBinding:Binding<String>{
        Binding(get:{model.result},set:{value in perform{model.result=value}})
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Rewrite selection", systemImage: "pencil.and.outline").font(.title2.bold())
                Spacer()
                Text("On this Mac").font(.caption).pluginSecondaryText()
            }
            Text(model.capture.map { "Selected in \($0.app)" } ?? "Select text in another app to begin.").font(.subheadline).pluginSecondaryText()
            Text("Original").font(.caption.bold())
            ScrollView { Text(model.capture?.text ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                .frame(minHeight: 60, maxHeight: 110).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Picker("Change", selection: operationBinding) {
                    ForEach(SelectionTransformation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().accessibilityLabel("Text transformation")
                Button("Generate preview") { perform{model.transform()} }
                if model.phase == .generating { ProgressView().controlSize(.small) }
            }.disabled(model.phase != .reviewing)
            Text("Preview · editable").font(.caption.bold())
            TextEditor(text: resultBinding).font(.body).scrollContentBackground(.hidden).padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .frame(minHeight: 110).disabled(model.phase != .reviewing).accessibilityLabel("Replacement preview")
            Text(model.status).font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("rewriteStatus")
            HStack {
                Button(model.phase == .applied || model.phase == .undone ? "Done" : "Cancel", action:close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy result") { perform{NSPasteboard.general.clearContents();NSPasteboard.general.setString(model.result,forType:.string)} }.disabled(model.result.isEmpty || model.working)
                if model.canUndo { Button("Undo replacement") { perform{model.undo()} } }
                else { Button("Replace selection") { perform{model.apply()} }.disabled(!model.canApply).keyboardShortcut(.return, modifiers: .command) }
            }
        }.padding(24).frame(minWidth: 430, minHeight: 425)
    }
}
