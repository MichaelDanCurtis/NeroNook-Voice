import Foundation
import Darwin
import NookLocalServiceKit
import AppKit
import VoiceAudio

/// Only retained original creation capabilities can publish a first ACTIVE.
/// Neither a URL nor an existing empty directory supplies this authority.
protocol VoiceLifecycleGenesisProvision: AnyObject, Sendable {
    func consume(owner: LocalServiceOwner, binding: VoiceLifecycleBinding) throws
    func revalidate() throws
    func matches(rootFD: Int32) throws
    func closeAfterConsumption() throws
}

/// A missing normal root observed under the already-held native owner. It
/// pins the original Application Support parent through confirmation/creation.
/// No directory or lifecycle record is created by inspection.
final class VoiceNormalEnrollment: VoiceLifecycleGenesisProvision, @unchecked Sendable {
    let policy: VoiceServicePolicy
    let owner: LocalServiceOwner
    let binding: VoiceLifecycleBinding
    let root: URL
    private let base: URL
    private let baseFD: Int32
    private var parentFD: Int32
    private var rootFD: Int32 = -1
    private let baseNode: Node
    private var parentNode: Node?
    private var rootNode: Node?
    private var creating = false, claimed = false, closed = false
    private var closeErrors: [Int32] = []
    private let lock = NSLock()
    private struct Node: Equatable {
        let device: dev_t, inode: ino_t, mode: mode_t, uid: uid_t
        init(_ value: stat) { device=value.st_dev; inode=value.st_ino; mode=value.st_mode; uid=value.st_uid }
    }
    private static let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    private init(policy: VoiceServicePolicy, owner: LocalServiceOwner, binding: VoiceLifecycleBinding,
                 base: URL, baseFD: Int32, parentFD: Int32, baseNode: Node, parentNode: Node?) {
        self.policy=policy; self.owner=owner; self.binding=binding; root=policy.lifecycleRoot
        self.base=base; self.baseFD=baseFD; self.parentFD=parentFD
        self.baseNode=baseNode; self.parentNode=parentNode
    }
    private static func physical(_ path: String) -> Bool {
        guard let value=realpath(path,nil) else{return false}; defer{free(value)}
        return String(cString:value)==path
    }
    private static func safe(_ value: stat) -> Bool {
        value.st_mode & S_IFMT == S_IFDIR && value.st_uid == geteuid() && value.st_mode & 0o022 == 0
    }
    private static func absent(_ name: String, at fd: Int32) throws -> Bool {
        var value=stat()
        if fstatat(fd,name,&value,AT_SYMLINK_NOFOLLOW)==0{return false}
        guard errno==ENOENT else{throw VoiceLifecycleFailure.io(errno)}
        return true
    }
    static func inspect(policy: VoiceServicePolicy, owner: LocalServiceOwner,
                        binding: VoiceLifecycleBinding) throws -> VoiceNormalEnrollment? {
        try owner.revalidate()
        let root=policy.lifecycleRoot, parent=root.deletingLastPathComponent(), base=parent.deletingLastPathComponent()
        guard root.isFileURL, root.lastPathComponent=="ServiceLifecycle", parent.lastPathComponent=="NeroVoice",
              binding.ownPolicyKey==owner.ownPolicyKey, binding.serviceIdentifier==policy.serviceIdentifier,
              physical(base.path) else{throw VoiceLifecycleFailure.unsafeRoot}
        let fd=open(base.path,flags); guard fd>=0 else{throw VoiceLifecycleFailure.io(errno)}
        var parentFD:Int32 = -1
        var transferred:VoiceNormalEnrollment?
        do {
            var held=stat(),named=stat()
            guard fstat(fd,&held)==0,lstat(base.path,&named)==0,Node(held)==Node(named),safe(held) else{throw VoiceLifecycleFailure.unsafeRoot}
            var parentNode:Node?
            if try !absent("NeroVoice",at:fd) {
                parentFD=openat(fd,"NeroVoice",flags);guard parentFD>=0 else{throw VoiceLifecycleFailure.unsafeRoot}
                var parentHeld=stat(),parentNamed=stat()
                guard fstat(parentFD,&parentHeld)==0,fstatat(fd,"NeroVoice",&parentNamed,AT_SYMLINK_NOFOLLOW)==0,
                      Node(parentHeld)==Node(parentNamed),safe(parentHeld) else{throw VoiceLifecycleFailure.unsafeRoot}
                parentNode=Node(parentHeld)
                if try !absent("ServiceLifecycle",at:parentFD) {
                    var errors:[Int32]=[]
                    if Darwin.close(parentFD) != 0{errors.append(errno)};parentFD = -1
                    if Darwin.close(fd) != 0{errors.append(errno)}
                    if !errors.isEmpty{throw VoiceProvisionCleanupFailure(original:VoiceLifecycleFailure.unsafeRoot,closeErrors:errors)}
                    return nil // Every existing root belongs to ordinary begin/recovery, never enrollment.
                }
            }
            let value=VoiceNormalEnrollment(policy:policy,owner:owner,binding:binding,base:base,
                baseFD:fd,parentFD:parentFD,baseNode:Node(held),parentNode:parentNode)
            transferred=value
            try value.revalidate();return value
        } catch {
            // A returned capability owns the descriptors; all other paths close
            // their originals once. Never retry a reused numeric descriptor.
            if let transferred {
                do {try transferred.closeAfterConsumption()}
                catch let cleanup as VoiceProvisionCleanupFailure {throw VoiceProvisionCleanupFailure(original:error,closeErrors:cleanup.closeErrors)}
                throw error
            }
            if let failure=error as? VoiceProvisionCleanupFailure { throw failure }
            var errors:[Int32]=[]
            if parentFD>=0,Darwin.close(parentFD) != 0{errors.append(errno)}
            if Darwin.close(fd) != 0{errors.append(errno)}
            if !errors.isEmpty{throw VoiceProvisionCleanupFailure(original:error,closeErrors:errors)}
            throw error
        }
    }
    /// Called only by the retained confirmed normal startup, off MainActor.
    /// Failure artifacts are preserved; there is deliberately no rollback/reset.
    /// Startup owns this single detached mutation; bootstrap joins that original
    /// before closing the capability. Inspection/UI never mutate these FDs.
    func createOriginal(checkpoint: (@Sendable () -> Void)? = nil) throws {
        lock.lock();guard !creating,!claimed,!closed else{lock.unlock();throw VoiceLifecycleFailure.busy}
        creating=true;lock.unlock()
        try Task.checkCancellation();try revalidate()
        if parentFD<0 {
            guard mkdirat(baseFD,"NeroVoice",0o700)==0 else{throw VoiceLifecycleFailure.io(errno)}
            var created=stat()
            guard fstatat(baseFD,"NeroVoice",&created,AT_SYMLINK_NOFOLLOW)==0,
                  Self.safe(created),created.st_mode & 0o7777==0o700 else{throw VoiceLifecycleFailure.unsafeRoot}
            let fd=openat(baseFD,"NeroVoice",Self.flags);guard fd>=0 else{throw VoiceLifecycleFailure.io(errno)}
            parentFD=fd;var value=stat()
            guard fstat(fd,&value)==0,Node(value)==Node(created) else{throw VoiceLifecycleFailure.unsafeRoot}
            parentNode=Node(value)
            guard fsync(baseFD)==0 else{throw VoiceLifecycleFailure.io(errno)}
        }
        try Task.checkCancellation();try revalidate()
        guard mkdirat(parentFD,"ServiceLifecycle",0o700)==0 else{throw VoiceLifecycleFailure.io(errno)}
        var created=stat()
        guard fstatat(parentFD,"ServiceLifecycle",&created,AT_SYMLINK_NOFOLLOW)==0,
              Self.safe(created),created.st_mode & 0o7777==0o700 else{throw VoiceLifecycleFailure.unsafeRoot}
        rootNode=Node(created)
        let fd=openat(parentFD,"ServiceLifecycle",Self.flags);guard fd>=0 else{throw VoiceLifecycleFailure.io(errno)}
        rootFD=fd
        guard fsync(parentFD)==0 else{throw VoiceLifecycleFailure.io(errno)}
        checkpoint?();try Task.checkCancellation();try revalidate()
    }
    func revalidate() throws {
        try owner.revalidate();lock.lock();defer{lock.unlock()}
        guard !closed,Self.physical(base.path) else{throw VoiceLifecycleFailure.unsafeRoot}
        var held=stat(),named=stat()
        guard fstat(baseFD,&held)==0,lstat(base.path,&named)==0,Node(held)==baseNode,Node(named)==baseNode else{throw VoiceLifecycleFailure.unsafeRoot}
        if let parentNode {
            guard fstat(parentFD,&held)==0,fstatat(baseFD,"NeroVoice",&named,AT_SYMLINK_NOFOLLOW)==0,
                  Node(held)==parentNode,Node(named)==parentNode else{throw VoiceLifecycleFailure.unsafeRoot}
            if let rootNode {
                guard rootFD>=0,fstat(rootFD,&held)==0,fstatat(parentFD,"ServiceLifecycle",&named,AT_SYMLINK_NOFOLLOW)==0,
                      Node(held)==rootNode,Node(named)==rootNode else{throw VoiceLifecycleFailure.unsafeRoot}
            } else if try !Self.absent("ServiceLifecycle",at:parentFD){throw VoiceLifecycleFailure.unsafeRoot}
        } else if try !Self.absent("NeroVoice",at:baseFD){throw VoiceLifecycleFailure.unsafeRoot}
    }
    func consume(owner expected: LocalServiceOwner, binding expectedBinding: VoiceLifecycleBinding) throws {
        guard owner === expected,binding.serviceIdentifier==expectedBinding.serviceIdentifier,
              binding.buildIdentifier==expectedBinding.buildIdentifier,binding.bootSessionUUID==expectedBinding.bootSessionUUID,
              binding.ownPolicyKey==expectedBinding.ownPolicyKey else{throw VoiceLifecycleFailure.invalidBinding}
        lock.lock();let allowed = !closed && !claimed && rootFD>=0
        if allowed{claimed=true};lock.unlock()
        guard allowed else{throw VoiceLifecycleFailure.busy}
        try revalidate()
    }
    func matches(rootFD fd: Int32) throws {
        try revalidate();var value=stat()
        guard let rootNode,fstat(fd,&value)==0,Node(value)==rootNode else{throw VoiceLifecycleFailure.unsafeRoot}
    }
    func closeAfterConsumption() throws {
        lock.lock();defer{lock.unlock()}
        if !closed {
            closed=true
            for fd in [rootFD,parentFD,baseFD] where fd>=0 {if Darwin.close(fd) != 0{closeErrors.append(errno)}}
        }
        if !closeErrors.isEmpty{throw VoiceProvisionCleanupFailure(original:VoiceLifecycleFailure.unsafeRoot,closeErrors:closeErrors)}
    }
    deinit {try? closeAfterConsumption()}
}

/// Narrow native presentation boundary; fixtures supply a held response without
/// opening an application/window or ever touching a default user profile.
@MainActor protocol VoiceNormalEnrollmentPrompt: AnyObject {
    func confirm(_ opportunity: VoiceNormalEnrollment, parent: VoiceEnrollmentWindowAnchor.Snapshot?) async -> Bool
    func cancel()
}

@MainActor final class VoiceNativeEnrollmentPrompt: VoiceNormalEnrollmentPrompt {
    private var original: Task<Bool,Never>?
    private var response: AsyncStream<Bool>.Continuation?
    private var alert: NSAlert?
    private var window: NSWindow?
    private var parentSnapshot: VoiceEnrollmentWindowAnchor.Snapshot?
    private var parentObservation: UUID?
    private var generation=UUID()
    private var cancelled=false, registered=false, endRequested=false
    private let callbacks=VoiceAudioCallbackAdmission()

    // Identical defaulted native seams in baseline and candidate. Tests observe
    // the real prompt path without presenting consent or accepting enrollment.
    typealias SheetReply = (NSApplication.ModalResponse) -> Void
    private let keyWindow: @MainActor () -> NSWindow?
    private let beginSheet: @MainActor (NSAlert, NSWindow, @escaping SheetReply) -> Void
    private let endSheet: @MainActor (NSAlert, NSWindow) -> Void
    private let canEndSheet: @MainActor (NSAlert, NSWindow) -> Bool
    init(keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp?.keyWindow },
         beginSheet: @escaping @MainActor (NSAlert, NSWindow, @escaping SheetReply) -> Void = { alert, parent, reply in
             alert.beginSheetModal(for: parent, completionHandler: reply)
         },
         endSheet: @escaping @MainActor (NSAlert, NSWindow) -> Void = { alert, parent in
             parent.endSheet(alert.window, returnCode: .cancel)
         },
         canEndSheet: @escaping @MainActor (NSAlert, NSWindow) -> Bool = { alert, parent in
             alert.window.sheetParent === parent
         }) {
        self.keyWindow = keyWindow; self.beginSheet = beginSheet; self.endSheet = endSheet; self.canEndSheet = canEndSheet
    }

    func confirm(_ opportunity: VoiceNormalEnrollment, parent: VoiceEnrollmentWindowAnchor.Snapshot?) async -> Bool {
        if let original{return await original.value}
        let pair=AsyncStream<Bool>.makeStream(bufferingPolicy:.bufferingNewest(1))
        response=pair.continuation
        let callbacks=callbacks
        let task=Task{@MainActor in
            var accepted=false
            for await value in pair.stream{accepted=value}
            await callbacks.waitForReturn()
            return accepted
        }
        original=task // Before every AppKit getter/constructor/callout.
        guard !cancelled,let parent,parent.isCurrent else{complete(false);return await joinedResult(task)}
        let window = parent.parent
        self.window=window;parentSnapshot=parent
        parentObservation=parent.onInvalidation { [weak self] in self?.cancel() }
        let token=generation,alert=NSAlert()
        self.alert=alert
        alert.messageText="Set up shared Nero Voice?"
        alert.informativeText="Let NeroNook and your assistant use Nero Voice on this Mac. Your recordings and voice settings stay where they are. Recording still starts only when you ask, and other apps need their own approval."
        alert.addButton(withTitle:"Set Up")
        alert.addButton(withTitle:"Cancel")
        alert.window.isReleasedWhenClosed=false
        guard !cancelled,generation==token,self.window === window,parent.isCurrent else{complete(false);return await joinedResult(task)}
        registered=true
        beginSheet(alert,window){[self,alert,window] result in
            guard let entered=callbacks.enter()else{return};defer{entered.finish()}
            let accepted = !cancelled && generation==token && self.alert === alert && self.window === window
                && parent.isCurrent && window.isVisible && result == .alertFirstButtonReturn
            complete(accepted)
        }
        if cancelled{requestEnd()}
        return await joinedResult(task)
    }
    private func joinedResult(_ task:Task<Bool,Never>) async->Bool {
        let accepted=await task.value
        // The original registration/callback admission and response Task have
        // returned. Only now release native window/content ownership.
        parentSnapshot?.removeObservation(parentObservation);parentObservation=nil;parentSnapshot=nil
        alert=nil;window=nil
        return accepted
    }
    private func complete(_ accepted:Bool) {
        callbacks.seal();callbacks.nativeStopReturned()
        response?.yield(accepted);response?.finish();response=nil
    }
    func cancel() {
        cancelled=true;generation=UUID()
        if registered{requestEnd()}
        // If registration has not begun, confirm() checks this flag after the
        // original constructor returns. It alone completes that original.
    }
    private func requestEnd() {
        guard !endRequested,registered,let window,let alert,canEndSheet(alert,window) else{return}
        endRequested=true // Before a reentrant native completion.
        endSheet(alert, window)
    }
}
