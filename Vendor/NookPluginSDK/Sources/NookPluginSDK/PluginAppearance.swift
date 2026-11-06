public enum PluginAppearanceObservationMode: Sendable { case system, hostDelivered }

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import SwiftUI
import Combine

private final class AppearanceObserverToken: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol
    init(_ center: NotificationCenter, _ token: NSObjectProtocol) { self.center=center;self.token=token }
    func remove() { center.removeObserver(token) }
}

/// One negotiated host session. Explicit instances own their callbacks; the
/// privately marked legacy singleton never offers a store-wide clean receipt.
@MainActor public final class PluginAppearanceStore: ObservableObject {
    public static let shared = PluginAppearanceStore(observation:.system, sharedOwnership:true)
    @Published public private(set) var delivery: PluginAppearanceDelivery?
    private var identity: (String, UUID)?
    private var mutations:PluginAppearanceSource?
    let appearanceLifetime = PluginAppearanceLifetime()
    private let mode: PluginAppearanceObservationMode
    private let sharedOwnership: Bool
    private let readAccessibility: @MainActor () -> (Bool,Bool,Bool)
    private var cachedAccessibility = (false,false,false)
    public var isRetiring: Bool { appearanceLifetime.isSealed }
    var permitsScreenObservation: Bool { mode == .system && !isRetiring }
    public convenience init() { self.init(observation:.system,sharedOwnership:false) }
    public convenience init(observation:PluginAppearanceObservationMode) { self.init(observation:observation,sharedOwnership:false) }
    private init(observation:PluginAppearanceObservationMode,sharedOwnership:Bool,
                 sources:[(NotificationCenter,Notification.Name)]? = nil,
                 accessibility:(@MainActor () -> (Bool,Bool,Bool))? = nil) {
        mode=observation;self.sharedOwnership=sharedOwnership
        readAccessibility=accessibility ?? {
            let workspace=NSWorkspace.shared
            return (workspace.accessibilityDisplayShouldReduceTransparency,
                    workspace.accessibilityDisplayShouldReduceMotion,
                    workspace.accessibilityDisplayShouldIncreaseContrast)
        }
        if observation == .system {
            let selected=sources ?? [
                (.default,NSColor.systemColorsDidChangeNotification),
                (.default,NSApplication.didChangeScreenParametersNotification),
                (NSWorkspace.shared.notificationCenter,NSWorkspace.accessibilityDisplayOptionsDidChangeNotification),
                (DistributedNotificationCenter.default(),Notification.Name("AppleInterfaceThemeChangedNotification"))]
            for (center,name) in selected {
                guard let source=appearanceLifetime.makeSource() else { continue }
                let token=center.addObserver(forName:name,object:nil,queue:nil){[weak self,source] _ in
                    guard let original=source.enter() else{return};defer{original.finish()}
                    source.submit{[weak self] in
                        guard let self,!self.isRetiring else{return}
                        self.objectWillChange.send()
                    }
                }
                let owned=AppearanceObserverToken(center,token)
                source.finishRegistration(stop:{owned.remove()})
            }
        }
    }
    deinit { appearanceLifetime.seal() }
    // Authored-source seam exercises the same private singleton ownership path
    // without ever evaluating the process-global .shared or system centers.
    static func authoredStore(observation:PluginAppearanceObservationMode, sharedOwnership:Bool,
                              sources:[(NotificationCenter,Notification.Name)],
                              accessibility:@escaping @MainActor () -> (Bool,Bool,Bool)) -> PluginAppearanceStore {
        PluginAppearanceStore(observation:observation,sharedOwnership:sharedOwnership,sources:sources,accessibility:accessibility)
    }
    @discardableResult public func sealForRetirement() -> Bool {
        guard !sharedOwnership else{return false}
        appearanceLifetime.seal();return true
    }
    public func retirement() async -> Bool {
        guard sealForRetirement() else{return false}
        return await appearanceLifetime.retirement()
    }
    private func admitMutation()->PluginAppearanceCallbackLease? {
        guard !isRetiring else{return nil}
        if mutations == nil {
            guard let original=appearanceLifetime.makeSource()else{return nil}
            mutations=original;original.finishRegistration(stop:{})
        }
        return mutations?.enter()
    }
    public func beginSession(pluginID:String,session:UUID) {
        guard let original=admitMutation()else{return};defer{original.finish()}
        guard !isRetiring,identity?.0 != pluginID || identity?.1 != session else{return}
        identity=(pluginID,session);delivery=nil
    }
    @discardableResult public func endSession(pluginID:String,session:UUID)->Bool {
        guard let original=admitMutation()else{return false};defer{original.finish()}
        guard !isRetiring,identity?.0==pluginID,identity?.1==session else{return false}
        identity=nil;delivery=nil;return true
    }
    @discardableResult public func receive(_ message:PluginMessage)->Bool {
        guard let original=admitMutation()else{return false};defer{original.finish()}
        guard !isRetiring,message.apiVersion==1,message.type=="appearance",message.pluginID==identity?.0,
              message.session==identity?.1,let value=message.appearance else{return false}
        return update(value)
    }
    @discardableResult public func update(_ value:PluginAppearanceDelivery)->Bool {
        guard let original=admitMutation()else{return false};defer{original.finish()}
        guard !isRetiring,(try? value.validate()) != nil,delivery.map({value.revision>$0.revision}) ?? true else{return false}
        delivery=value;return true
    }
    public func context(screenNumber:UInt32?,fallback:ColorScheme)->PluginAppearanceContext {
        var value=delivery?.displays.first(where:{$0.screenNumber==screenNumber}) ?? delivery?.shared ?? .init()
        if value.mode == .system{value.scheme=fallback == .dark ? .dark:.light}
        if mode == .system {
            let original=admitMutation();defer{original?.finish()}
            if original != nil && !isRetiring{cachedAccessibility=readAccessibility()}
            value.reduceTransparency=cachedAccessibility.0
            value.reduceMotion=cachedAccessibility.1
            value.increasedContrast=cachedAccessibility.2
        }
        return value
    }
}
private struct PluginAppearanceKey: EnvironmentKey { static let defaultValue = PluginAppearanceContext() }
extension EnvironmentValues {
    public var pluginAppearance: PluginAppearanceContext {
        get { self[PluginAppearanceKey.self] }
        set { self[PluginAppearanceKey.self] = newValue }
    }
}
extension Color {
    public init(pluginHex: String) {
        let n = UInt32(pluginHex.dropFirst(), radix: 16) ?? 0
        self.init(.sRGB, red: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255, opacity: 1)
    }
}

/// The same renderer serves default and explicitly owned stores. A window
/// manager can own just these surface sources without retiring its borrowed store.
public struct PluginThemedRoot<Content:View>:View {
    @ObservedObject private var store:PluginAppearanceStore
    @Environment(\.colorScheme) private var systemScheme
    @State private var screenNumber:UInt32?
    private let content:Content
    private let fillsBackground:Bool
    private let surfaceLifetime:PluginAppearanceLifetime
    public init(store:PluginAppearanceStore = .shared,background:Bool=true,@ViewBuilder content:()->Content) {
        self.init(store:store,background:background,surfaceLifetime:store.appearanceLifetime,content:content)
    }
    init(store:PluginAppearanceStore,background:Bool=true,surfaceLifetime:PluginAppearanceLifetime,@ViewBuilder content:()->Content) {
        self.store=store;self.fillsBackground=background;self.surfaceLifetime=surfaceLifetime;self.content=content()
    }
    public var body:some View {
        let appearance=store.context(screenNumber:screenNumber,fallback:systemScheme)
        content
            .buttonStyle(PluginGlassButtonStyle())
            .environment(\.pluginAppearance,appearance)
            .preferredColorScheme(appearance.mode == .system ? nil:appearance.scheme == .dark ? .dark:.light)
            .tint(Color(pluginHex:appearance.palette.accent))
            .accentColor(Color(pluginHex:appearance.palette.accent))
            .foregroundStyle(Color(pluginHex:appearance.palette.text))
            .background { if fillsBackground { PluginGlassSurface(radius:0).environment(\.pluginAppearance,appearance) } }
            .background { if store.permitsScreenObservation && !surfaceLifetime.isSealed {
                PluginScreenProbe(store:store,lifetime:surfaceLifetime,screenNumber:$screenNumber)
            } }
    }
}
private struct PluginScreenProbe:NSViewRepresentable {
    let store:PluginAppearanceStore
    let lifetime:PluginAppearanceLifetime
    @Binding var screenNumber:UInt32?
    func makeNSView(context:Context)->Probe {
        let view=Probe();view.configure(store:store,lifetime:lifetime){if screenNumber != $0 {screenNumber=$0}};return view
    }
    func updateNSView(_ view:Probe,context:Context){view.configure(store:store,lifetime:lifetime){if screenNumber != $0 {screenNumber=$0}}}
    static func dismantleNSView(_ view:Probe,coordinator:()){view.retire()}
    @MainActor final class Probe:NSView {
        private weak var store:PluginAppearanceStore?
        private weak var originalWindow:NSWindow?
        private var lifetime:PluginAppearanceLifetime?
        private var source:PluginAppearanceSource?
        private var generation=UUID()
        private var changed:((UInt32?)->Void)?
        deinit { source?.seal() }
        override func hitTest(_ point:NSPoint)->NSView?{nil}
        func configure(store:PluginAppearanceStore,lifetime:PluginAppearanceLifetime,changed:@escaping(UInt32?)->Void){
            let replaced=self.store !== store || self.lifetime !== lifetime
            if replaced{retire()}
            self.store=store;self.lifetime=lifetime;self.changed=changed
            if replaced{attach()}
        }
        override func viewDidMoveToWindow(){super.viewDidMoveToWindow();attach()}
        func retire(){generation=UUID();let old=source;source=nil;originalWindow=nil;old?.seal()}
        private func attach(){
            retire()
            guard let store,store.permitsScreenObservation,let lifetime,!lifetime.isSealed,
                  let window=self.window,let original=lifetime.makeSource() else{return}
            let token=generation;source=original;originalWindow=window
            let observer=NotificationCenter.default.addObserver(forName:NSWindow.didChangeScreenNotification,object:window,queue:nil){[weak self,weak window,original] _ in
                guard let entered=original.enter()else{return};defer{entered.finish()}
                original.submit{[weak self,weak window,original] in self?.report(window:window,source:original,generation:token)}
            }
            let owned=AppearanceObserverToken(.default,observer)
            original.finishRegistration(stop:{owned.remove()})
            guard let entered=original.enter()else{return};defer{entered.finish()}
            original.submit{[weak self,weak window,original] in self?.report(window:window,source:original,generation:token)}
        }
        private func report(window:NSWindow?,source original:PluginAppearanceSource,generation token:UUID){
            guard generation==token,source === original,lifetime?.isSealed == false,let store,store.permitsScreenObservation,
                  let window,originalWindow === window else{return}
            let number=(window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            guard generation==token,source === original,lifetime?.isSealed == false,!store.isRetiring,originalWindow === window else{return}
            changed?(number)
        }
    }
}

public struct PluginThemeCard<Content: View>: View {
    @Environment(\.pluginAppearance) private var appearance
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content=content() }
    public var body: some View {
        content.padding(16 * appearance.theme.style.spacingScale)
            .background(PluginGlassSurface(radius:appearance.theme.style.cornerRadius))

    }
}

extension View {
    public func pluginThemed(background: Bool = true) -> some View { PluginThemedRoot(background:background) { self } }
    public func pluginThemed(store:PluginAppearanceStore,background:Bool=true)->some View { PluginThemedRoot(store:store,background:background){self} }
}

#endif
