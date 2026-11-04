#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI

/// Native show callouts can synchronously reenter before an NSWindow exists.
/// Keep each original intent occupied until that actual show stack returns.
@MainActor final class PluginWindowIntents {
    static let maximumEntries=128
    private struct Slot { var current:UUID?; var originals:Set<UUID> }
    private var slots:[String:Slot]=[:]
    private var sealed=false
    private var heldOriginals=0
    func reserve(_ id:String)->UUID? {
        guard !sealed,heldOriginals<Self.maximumEntries,slots[id] != nil || slots.count<Self.maximumEntries else{return nil}
        let token=UUID();var slot=slots[id] ?? Slot(current:nil,originals:[])
        slot.current=token;slot.originals.insert(token);slots[id]=slot;heldOriginals += 1;return token
    }
    func isCurrent(_ id:String,_ token:UUID)->Bool { !sealed && slots[id]?.current==token }
    func finish(_ id:String,_ token:UUID,retainingCurrent:Bool) {
        guard var slot=slots[id],slot.originals.remove(token) != nil else{return}
        heldOriginals -= 1
        if slot.current==token && !retainingCurrent{slot.current=nil}
        if slot.current==nil && slot.originals.isEmpty{slots[id]=nil}else{slots[id]=slot}
    }
    func invalidate(_ id:String) {
        guard var slot=slots[id]else{return};slot.current=nil
        if slot.originals.isEmpty{slots[id]=nil}else{slots[id]=slot}
    }
    func invalidateAll(){for id in Array(slots.keys){invalidate(id)}}
    func seal(){sealed=true;invalidateAll()}
}

/// Window content remains the plugin's actual SwiftUI surface. An explicit
/// store is borrowed; retiring this manager never retires that store.
@MainActor public final class PluginWindows {
    private struct Entry { let window:NSWindow; let generation:UUID }
    private var windows:[String:Entry]=[:]
    private let lifetime=PluginAppearanceLifetime()
    private let intents=PluginWindowIntents()
    private let appearanceStore:PluginAppearanceStore?
    private var operations:PluginAppearanceSource?
    /// Inert until show: does not evaluate the legacy appearance singleton.
    public init() { appearanceStore=nil }
    public init(appearanceStore:PluginAppearanceStore) { self.appearanceStore=appearanceStore }
    deinit { lifetime.seal() }

    private func admit()->PluginAppearanceCallbackLease? {
        guard !lifetime.isSealed else{return nil}
        if operations == nil {
            guard let original=lifetime.makeSource()else{return nil}
            operations=original;original.finishRegistration(stop:{})
        }
        return operations?.enter()
    }
    private func current(_ id:String,_ generation:UUID,_ window:NSWindow)->Bool {
        !lifetime.isSealed && intents.isCurrent(id,generation) && windows[id]?.generation==generation && windows[id]?.window === window
    }
    private func discardIfUnowned(_ window:NSWindow) {
        guard !windows.values.contains(where:{$0.window === window})else{return}
        window.contentView=nil;window.close()
    }
    public func show<Content:View>(_ id:String,title:String,size:CGSize=CGSize(width:800,height:450),@ViewBuilder content:()->Content) {
        guard let original=admit()else{return};defer{original.finish()}
        guard let generation=intents.reserve(id)else{return}
        defer{intents.finish(id,generation,retainingCurrent:windows[id]?.generation==generation)}
        PluginApplication.configure()
        guard intents.isCurrent(id,generation),!lifetime.isSealed else{return}
        let window:NSWindow
        if let existing=windows[id]{window=existing.window}
        else {
            window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            guard intents.isCurrent(id,generation),!lifetime.isSealed else{discardIfUnowned(window);return}
            window.isReleasedWhenClosed=false
            guard intents.isCurrent(id,generation),!lifetime.isSealed else{discardIfUnowned(window);return}
            window.center()
            guard intents.isCurrent(id,generation),!lifetime.isSealed else{discardIfUnowned(window);return}
        }
        windows[id]=Entry(window:window,generation:generation)
        // Resolve the legacy store only at a genuinely admitted show point.
        let store=appearanceStore ?? .shared
        guard current(id,generation,window)else{discardIfUnowned(window);return}
        let root=PluginThemedRoot(store:store,surfaceLifetime:lifetime){content()}
        guard current(id,generation,window)else{discardIfUnowned(window);return}
        let hosting=NSHostingView(rootView:root)
        guard current(id,generation,window)else{discardIfUnowned(window);return}
        window.title=title
        guard current(id,generation,window)else{discardIfUnowned(window);return}
        window.contentView=hosting
        guard current(id,generation,window)else{discardIfUnowned(window);return}
        NSApp.activate(ignoringOtherApps:true)
        guard current(id,generation,window)else{discardIfUnowned(window);return}
        window.makeKeyAndOrderFront(nil)
        guard current(id,generation,window)else{discardIfUnowned(window);return}
    }
    public func close(_ id:String) {
        guard let original=admit()else{return};defer{original.finish()}
        intents.invalidate(id)
        guard let entry=windows.removeValue(forKey:id)else{return}
        entry.window.contentView=nil
        // A synchronous content teardown may have reused this same object.
        discardIfUnowned(entry.window)
    }
    public func closeAll() {
        guard let original=admit()else{return};defer{original.finish()}
        intents.invalidateAll()
        let originals=Array(windows.values);windows.removeAll()
        for entry in originals{discardIfUnowned(entry.window)}
    }
    /// Terminal for this manager, but never a store/global-system teardown.
    @discardableResult public func sealForRetirement()->Bool {
        let original=operations?.enter();defer{original?.finish()}
        intents.seal();lifetime.seal()
        let originals=Array(windows.values);windows.removeAll()
        for entry in originals{discardIfUnowned(entry.window)}
        return true
    }
    public func retirement()async->Bool {
        sealForRetirement()
        return await lifetime.retirement()
    }
}
#endif
