import AppKit
import SwiftUI
import Foundation
import Darwin
import NookPluginSDK
import VoiceAudio
import ModuleCore

/// Composition data only. This does not mint a native owner, lifecycle epoch,
/// microphone permission or authority to coexist with another audio service.
@MainActor final class VoiceProductConfiguration {
    enum Effect: String, CaseIterable {
        case observation, discovery, globalControls, accessibility, capture, speech, model, provider, externalFiles, nativePresentation
    }
    let isolated: Bool
    let root: URL?
    private let revalidateOriginal: @Sendable () throws -> Void
    let preferences: VoiceProductPreferences
    let appearance = VoiceProductAppearance()
    private(set) var denied: [Effect: Int] = [:]
    var reason: String { "This isolated Voice session has not enabled microphone, speech, models, accounts or system controls." }
    static var legacy: VoiceProductConfiguration { VoiceProductConfiguration(root: nil, preferences: .legacy()) }
    private init(root: URL?, preferences: VoiceProductPreferences, revalidate: @escaping @Sendable () throws -> Void = {}) {
        self.root=root; self.isolated=root != nil; self.preferences=preferences;self.revalidateOriginal=revalidate
    }
    static func isolated(root: URL, revalidate: @escaping @Sendable () throws -> Void) throws -> VoiceProductConfiguration {
        try revalidate()
        let parent=root.deletingLastPathComponent()
        try checkDirectory(parent)
        guard mkdir(root.path,0o700)==0 else{throw VoiceProblem.message("A fresh isolated Product directory is required; existing data is retained")}
        try revalidate();try checkDirectory(root)
        for name in ["Meetings", "Dictation", "QwenVoices"] {
            let child=root.appendingPathComponent(name,isDirectory:true)
            guard mkdir(child.path,0o700)==0 else{throw VoiceProblem.message("Cannot create a fresh isolated Voice data directory")}
            try revalidate();try checkDirectory(child)
        }
        let identities=try ([root]+["Meetings","Dictation","QwenVoices"].map{root.appendingPathComponent($0,isDirectory:true)}).map{try VoiceProductDirectoryIdentity($0)}
        let validate: @Sendable () throws -> Void = {
            try revalidate()
            for identity in identities{try identity.revalidate()}
        }
        try validate()
        let result=VoiceProductConfiguration(root:root,preferences:try VoiceProductPreferences(root:root,revalidate:validate),revalidate:validate)
        try result.validateData()
        return result
    }
    func validateData() throws { try revalidateOriginal() }
    @discardableResult func permitsData() -> Bool {
        do{try validateData();return true}catch{return false}
    }
    nonisolated static func physicalPath(_ url:URL)throws->String{
        guard let raw=realpath(url.path,nil)else{throw VoiceProblem.message("Cannot resolve isolated Voice directory")}
        defer{free(raw)}
        return String(cString:raw)
    }
    nonisolated static func checkDirectory(_ root: URL) throws {
        guard root.isFileURL,Array(root.path.utf8) == Array(try physicalPath(root).utf8) else { throw VoiceProblem.message("Select a physical isolated Voice directory") }
        var info=stat()
        guard lstat(root.path,&info)==0,info.st_mode & S_IFMT == S_IFDIR,info.st_uid == getuid(),info.st_mode & 0o077 == 0 else {
            throw VoiceProblem.message("The isolated Voice directory must be private and owned by this user")
        }
    }
    func allows(_ effect: Effect) -> Bool { !isolated }
    @discardableResult func admit(_ effect: Effect) -> Bool {
        guard allows(effect) else { denied[effect,default:0] += 1;return false }; return true
    }
    func require(_ effect: Effect) throws {
        guard admit(effect) else { throw VoiceProblem.message(reason) }
    }
    var meetingsRoot: URL {
        root?.appendingPathComponent("Meetings",isDirectory:true) ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NeroVoice/Meetings",isDirectory:true)
    }
    var dictationRoot: URL {
        root?.appendingPathComponent("Dictation",isDirectory:true) ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NeroVoice/Dictation",isDirectory:true)
    }
    var qwenLibrary: QwenVoiceLibrary { QwenVoiceLibrary(root:root?.appendingPathComponent("QwenVoices",isDirectory:true)) }
}

/// The isolated path never constructs a UserDefaults suite or reads global
/// preference domains. Writes stay in its real root-local bounded plist.
@MainActor final class VoiceProductPreferences {
    private let usesLegacyDefaults:Bool
    private let root: URL?
    private let revalidate: @Sendable () throws -> Void
    private var values: [String:Any] = [:]
    private(set) var issue: String?
    static func legacy() -> VoiceProductPreferences { VoiceProductPreferences(legacy:true) }
    private init(legacy:Bool) { usesLegacyDefaults=legacy;root=nil;revalidate={} }
    init(root:URL,revalidate:@escaping @Sendable () throws -> Void) throws {
        self.root=root;usesLegacyDefaults=false;self.revalidate=revalidate
        try revalidate()
        try VoiceProductConfiguration.checkDirectory(root)
        let url=root.appendingPathComponent("preferences.plist")
        var info=stat()
        if lstat(url.path,&info)==0 {
            guard info.st_mode & S_IFMT == S_IFREG,info.st_nlink == 1,info.st_uid == getuid(),info.st_size <= 65536 else {
                throw VoiceProblem.message("Isolated Voice preferences need recovery")
            }
            let data=try Self.readOriginal(url,revalidate:revalidate)
            guard data.count<=65536,let value=try PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:Any],value.count<=128 else {
                throw VoiceProblem.message("Isolated Voice preferences exceed their limits")
            }
            values=value
        } else if errno != ENOENT { throw VoiceProblem.message("Cannot inspect isolated Voice preferences") }
    }
    private static func readOriginal(_ url:URL,revalidate:@Sendable ()throws->Void)throws->Data{
        try revalidate()
        let descriptor=open(url.path,O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor>=0 else{throw VoiceProblem.message("Cannot open isolated Voice preferences")}
        let result:Result<Data,Error>
        do{
            var original=stat()
            guard fstat(descriptor,&original)==0,original.st_mode & S_IFMT == S_IFREG,original.st_uid==getuid(),original.st_nlink==1,original.st_size>=0,original.st_size<=65536 else{
                throw VoiceProblem.message("Invalid isolated Voice preferences file")
            }
            var data=Data(),buffer=[UInt8](repeating:0,count:8192)
            while data.count<=65536{
                let amount=min(buffer.count,65537-data.count)
                let count=read(descriptor,&buffer,amount)
                if count<0{if errno==EINTR{continue};throw VoiceProblem.message("Cannot read isolated Voice preferences")}
                if count==0{break}
                data.append(contentsOf:buffer.prefix(count))
            }
            guard data.count<=65536 else{throw VoiceProblem.message("Isolated Voice preferences exceed their limits")}
            var after=stat(),named=stat()
            guard fstat(descriptor,&after)==0,lstat(url.path,&named)==0,
                  original.st_dev==after.st_dev,original.st_ino==after.st_ino,
                  after.st_dev==named.st_dev,after.st_ino==named.st_ino,after.st_nlink==1,after.st_size==data.count else{
                throw VoiceProblem.message("Isolated Voice preferences changed during read")
            }
            try revalidate();result = .success(data)
        }catch{result = .failure(error)}
        if close(descriptor) != 0{
            let actualCode=errno
            let primary:Error
            switch result{case .failure(let original):primary=original;case .success:primary=VoiceProblem.message("The original isolated preferences descriptor failed to close")}
            throw VoiceProvisionCleanupFailure(original:primary,closeErrors:[actualCode])
        }
        return try result.get()
    }
    func object(forKey key:String)->Any? {
        do{try revalidate()}catch{issue=error.localizedDescription;return nil}
        return usesLegacyDefaults ? UserDefaults.standard.object(forKey:key):values[key]
    }
    func string(forKey key:String)->String? { object(forKey:key) as? String }
    func data(forKey key:String)->Data? { object(forKey:key) as? Data }
    func bool(forKey key:String)->Bool { object(forKey:key) as? Bool ?? false }
    func set(_ value:Any?,forKey key:String) {
        if usesLegacyDefaults { UserDefaults.standard.set(value,forKey:key);return }
        guard issue == nil,let root else { return }
        do {
            try revalidate()
            try VoiceProductConfiguration.checkDirectory(root)
            var next=values;next[key]=value
            guard next.count<=128,key.utf8.count<=128 else { throw VoiceProblem.message("Too many isolated Voice preferences") }
            let data=try PropertyListSerialization.data(fromPropertyList:next,format:.binary,options:0)
            guard data.count<=65536 else { throw VoiceProblem.message("Isolated Voice preferences are too large") }
            let target=root.appendingPathComponent("preferences.plist")
            var info=stat()
            if lstat(target.path,&info)==0 {
                guard info.st_mode & S_IFMT == S_IFREG,info.st_nlink == 1,info.st_uid == getuid() else { throw VoiceProblem.message("Isolated Voice preferences changed") }
            } else if errno != ENOENT { throw VoiceProblem.message("Cannot inspect isolated Voice preferences") }
            try data.write(to:target,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
            try VoiceProductConfiguration.checkDirectory(root)
            try revalidate()
            values=next
        } catch { issue=error.localizedDescription }
    }
}

/// The exact construction frame is reserved before SDK registration callouts.
/// Its completion hands over the original store even when Stop won reentry.
@MainActor final class VoiceAppearanceConstruction {
    private var returned:PluginAppearanceStore?
    private var waiters:[CheckedContinuation<PluginAppearanceStore,Never>]=[]
    func finish(_ store:PluginAppearanceStore){
        guard returned == nil else{return};returned=store
        let originals=waiters;waiters.removeAll();for original in originals{original.resume(returning:store)}
    }
    func retirement()async->Bool{
        let original:PluginAppearanceStore
        if let returned{original=returned}else{original=await withCheckedContinuation{waiters.append($0)}}
        return await original.retirement()
    }
}

/// One actual SDK store, selected once before a shared service's full product
/// construction. Merely constructing the placeholder/configuration is inert.
@MainActor final class VoiceProductAppearance:ObservableObject {
    private var originalStore:PluginAppearanceStore?
    private var originalConstruction:VoiceAppearanceConstruction?
    private var constructionPlaceholder:PluginAppearanceStore?
    private var observation:PluginAppearanceObservationMode?
    private var originalRetirement:Task<Bool,Never>?
    private let makeStore:@MainActor (PluginAppearanceObservationMode)->PluginAppearanceStore
    private(set) var isPresentationAllowed=true
    var materialized:Bool{originalStore != nil}
    // Preserve the existing read interface through the actual SDK owner.
    var delivery:PluginAppearanceDelivery?{store.delivery}
    func context(_ scheme:ColorScheme)->PluginAppearanceContext{
        store.context(screenNumber:nil,fallback:scheme)
    }
    init(makeStore:@escaping @MainActor (PluginAppearanceObservationMode)->PluginAppearanceStore={PluginAppearanceStore(observation:$0)}){self.makeStore=makeStore}
    var store:PluginAppearanceStore{
        if let originalStore{return originalStore}
        if originalConstruction != nil{
            if let constructionPlaceholder{return constructionPlaceholder}
            // Reentrant view access never overwrites an entered constructor or
            // starts another live observer owner. This value cannot admit work.
            let inert=PluginAppearanceStore(observation:.hostDelivered)
            _ = inert.sealForRetirement();constructionPlaceholder=inert;return inert
        }
        let original=PluginAppearanceStore(observation:.hostDelivered)
        originalStore=original;observation = .hostDelivered
        if !isPresentationAllowed{_ = original.sealForRetirement()}
        return original
    }
    func prepareSharedService(observation selected:PluginAppearanceObservationMode)throws{
        guard isPresentationAllowed else{throw VoiceProblem.message("Voice presentation is retired")}
        if originalStore != nil{
            guard observation==selected else{throw VoiceProblem.message("Voice appearance was already materialized with another observation policy")}
            return
        }
        guard originalConstruction == nil else{throw VoiceProblem.message("Voice appearance construction is already entered")}
        let construction=VoiceAppearanceConstruction();originalConstruction=construction
        let original=makeStore(selected)
        let accepted=isPresentationAllowed && originalConstruction === construction && originalStore == nil
        if accepted{originalStore=original;observation=selected}
        else{_ = original.sealForRetirement()}
        construction.finish(original) // Only after the actual constructor returned.
        guard accepted else{throw VoiceProblem.message("Voice appearance retired during construction")}
    }
    func beginSession(pluginID:String,session:UUID){guard isPresentationAllowed else{return};store.beginSession(pluginID:pluginID,session:session)}
    @discardableResult func receive(_ message:PluginMessage)->Bool{guard isPresentationAllowed else{return false};return store.receive(message)}
    @discardableResult func endSession(pluginID:String,session:UUID)->Bool{
        guard isPresentationAllowed,let originalStore else{return false}
        return originalStore.endSession(pluginID:pluginID,session:session)
    }
    func sealForRetirement()->Task<Bool,Never>{
        isPresentationAllowed=false
        if let originalRetirement{return originalRetirement}
        let construction=originalConstruction,captured=originalStore
        let original=Task {
            if let construction{return await construction.retirement()}
            if let captured{return await captured.retirement()}
            return true
        }
        originalRetirement=original
        if let captured{_ = captured.sealForRetirement()}
        return original
    }
}

struct VoiceProductSurface<Content:View>:View {
    let isolated:Bool
    @ObservedObject var appearance:VoiceProductAppearance
    let content:Content
    init(isolated:Bool,appearance:VoiceProductAppearance,@ViewBuilder content:()->Content) {
        self.isolated=isolated;self.appearance=appearance;self.content=content()
    }
    var body:some View {
        Group {
            if isolated {PluginThemedRoot(store:appearance.store){content}}
            else {content.pluginThemed()}
        }
    }
}

private struct VoiceProductDirectoryIdentity:Sendable {
    let url:URL
    let device:dev_t
    let inode:ino_t
    init(_ url:URL)throws{
        try VoiceProductConfiguration.checkDirectory(url)
        var info=stat();guard lstat(url.path,&info)==0 else{throw VoiceProblem.message("Cannot retain isolated directory identity")}
        self.url=url;device=info.st_dev;inode=info.st_ino
    }
    func revalidate()throws{
        // No actor/UI access; same original physical directory at every admission.
        var info=stat()
        guard lstat(url.path,&info)==0,info.st_mode & S_IFMT == S_IFDIR,info.st_dev==device,info.st_ino==inode,
              info.st_uid==getuid(),info.st_mode & 0o077==0,Array(url.path.utf8)==Array(try VoiceProductConfiguration.physicalPath(url).utf8) else{
            throw VoiceProblem.message("The original isolated Voice directory changed")
        }
    }
}
