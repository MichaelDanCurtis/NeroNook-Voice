#if canImport(UIKit)
import UIKit
import SwiftUI
import Combine

private final class AppearanceUIKitObserverToken: @unchecked Sendable {
    let center: NotificationCenter
    let token: NSObjectProtocol
    init(_ center: NotificationCenter, _ token: NSObjectProtocol) { self.center=center;self.token=token }
    func remove() { center.removeObserver(token) }
}

/// UIKit retains its existing shared-context rendering. Explicit owned stores
/// add the same lifecycle API without asserting native platform qualification.
@MainActor public final class PluginAppearanceStore: ObservableObject {
    public static let shared = PluginAppearanceStore(observation:.system,sharedOwnership:true)
    @Published public private(set) var delivery: PluginAppearanceDelivery?
    private var identity:(String,UUID)?
    let appearanceLifetime = PluginAppearanceLifetime()
    private let mode:PluginAppearanceObservationMode
    private let sharedOwnership:Bool
    private let readAccessibility:@MainActor () -> (Bool,Bool,Bool)
    private var cachedAccessibility=(false,false,false)
    private var mutations:PluginAppearanceSource?
    public var isRetiring:Bool { appearanceLifetime.isSealed }
    public convenience init() { self.init(observation:.system,sharedOwnership:false) }
    public convenience init(observation:PluginAppearanceObservationMode) { self.init(observation:observation,sharedOwnership:false) }
    private init(observation:PluginAppearanceObservationMode,sharedOwnership:Bool,
                 sources:[(NotificationCenter,Notification.Name)]?=nil,
                 accessibility:(@MainActor () -> (Bool,Bool,Bool))?=nil) {
        mode=observation;self.sharedOwnership=sharedOwnership
        readAccessibility=accessibility ?? {
            (UIAccessibility.isReduceTransparencyEnabled,UIAccessibility.isReduceMotionEnabled,
             UIAccessibility.isDarkerSystemColorsEnabled)
        }
        // Inert host-delivered construction does not evaluate any UIKit source
        // factory or accessibility getter. The default path stays system-owned.
        if observation == .system {
            let selected=sources ?? [
                (.default,UIApplication.didBecomeActiveNotification),
                (.default,UIAccessibility.reduceMotionStatusDidChangeNotification),
                (.default,UIAccessibility.reduceTransparencyStatusDidChangeNotification),
                (.default,UIAccessibility.darkerSystemColorsStatusDidChangeNotification)]
            for (center,name) in selected {
                guard let source=appearanceLifetime.makeSource() else { continue }
                let token=center.addObserver(forName:name,object:nil,queue:nil){[weak self,source] _ in
                    guard let original=source.enter() else{return};defer{original.finish()}
                    source.submit{[weak self] in
                        guard let self,!self.isRetiring else{return}
                        self.objectWillChange.send()
                    }
                }
                let owned=AppearanceUIKitObserverToken(center,token)
                source.finishRegistration(stop:{owned.remove()})
            }
        }
    }
    deinit { appearanceLifetime.seal() }
    static func authoredStore(observation:PluginAppearanceObservationMode,sharedOwnership:Bool,
                              sources:[(NotificationCenter,Notification.Name)],
                              accessibility:@escaping @MainActor () -> (Bool,Bool,Bool)) -> PluginAppearanceStore {
        PluginAppearanceStore(observation:observation,sharedOwnership:sharedOwnership,sources:sources,accessibility:accessibility)
    }
    @discardableResult public func sealForRetirement()->Bool {
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
    public func context(screenNumber:UInt32?=nil,fallback:ColorScheme)->PluginAppearanceContext {
        var value=screenNumber.flatMap{number in delivery?.displays.first{$0.screenNumber==number}} ?? delivery?.shared ?? .init()
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
private struct PluginAppearanceKey:EnvironmentKey { static let defaultValue=PluginAppearanceContext() }
extension EnvironmentValues { public var pluginAppearance:PluginAppearanceContext { get{self[PluginAppearanceKey.self]} set{self[PluginAppearanceKey.self]=newValue} } }
extension Color { public init(pluginHex:String) { let n=UInt32(pluginHex.dropFirst(),radix:16) ?? 0;self.init(.sRGB,red:Double((n>>16)&255)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255,opacity:1) } }
public struct PluginThemedRoot<Content:View>:View {
    @ObservedObject private var store:PluginAppearanceStore
    @Environment(\.colorScheme) private var systemScheme
    private let content:Content
    private let fillsBackground:Bool
    public init(store:PluginAppearanceStore = .shared,background:Bool=true,@ViewBuilder content:()->Content) {self.store=store;self.fillsBackground=background;self.content=content()}
    public var body:some View {
        let appearance=store.context(fallback:systemScheme)
        content.buttonStyle(PluginGlassButtonStyle()).environment(\.pluginAppearance,appearance)
            .preferredColorScheme(appearance.mode == .system ? nil:appearance.scheme == .dark ? .dark:.light)
            .tint(Color(pluginHex:appearance.palette.accent)).foregroundStyle(Color(pluginHex:appearance.palette.text))
            .background { if fillsBackground { PluginGlassSurface(radius:0).environment(\.pluginAppearance,appearance) } }
    }
}
extension View {
    public func pluginThemed(background:Bool=true)->some View { PluginThemedRoot(background:background){self} }
    public func pluginThemed(store:PluginAppearanceStore,background:Bool=true)->some View { PluginThemedRoot(store:store,background:background){self} }
}
#endif
