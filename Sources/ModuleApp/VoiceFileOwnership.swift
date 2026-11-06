import Foundation
import VoiceAudio

/// Actual original file supervisors, keyed by native-derived opaque owner.
/// Cancel closes admission first and retains every original until its return.
@MainActor final class VoiceFileWork {
    private struct Entry { let owner:VoiceFoundationOwner;let task:Task<Void,Never> }
    private var originals:[UUID:Entry]=[:]
    private var synchronous:[UUID:VoiceFoundationOwner]=[:]
    private var failures=Set<VoiceFoundationOwner>(),uncertain=Set<VoiceFoundationOwner>()
    private var unknown:[VoiceFoundationOwner:String]=[:]
    private var waiters:[UUID:CheckedContinuation<Void,Never>]=[:]
    private var closed=Set<VoiceFoundationOwner>(),sealed=false
    var busy:Bool{!originals.isEmpty || !synchronous.isEmpty}
    func permits(_ owner:VoiceFoundationOwner)->Bool{!sealed && !closed.contains(owner)}
    func retain(_ task:Task<Void,Never>,owner:VoiceFoundationOwner){
        let id=UUID();originals[id]=Entry(owner:owner,task:task)
        if !permits(owner){task.cancel()}
        Task{[weak self] in await task.value;self?.originals[id]=nil;self?.notifyReturn()}
    }
    func retainCallbacks(_ gate:VoiceAudioCallbackAdmission,owner:VoiceFoundationOwner){
        retain(Task{await gate.waitForReturn()},owner:owner)
    }
    func start<Value:Sendable>(owner:VoiceFoundationOwner,work:@escaping @Sendable()->Value,
        cancelled:@escaping @MainActor () ->Void = {},completed:@escaping @MainActor(Value)->Void)throws{
        guard permits(owner),originals.count<32 else{throw VoiceServiceProblem.busy}
        // This outer task is retained synchronously before it can run and
        // start the detached reader/writer. Cancellation never loses its join.
        let outer=Task{[self] in
            guard !Task.isCancelled,permits(owner) else{cancelled();return}
            let worker=Task.detached{work()}
            let result=await worker.value;completed(result)
        }
        retain(outer,owner:owner)
    }
    func close(_ owner:VoiceFoundationOwner?){
        if let owner{closed.insert(owner)}else{sealed=true}
        for original in originals.values where owner == nil || original.owner == owner{original.task.cancel()}
    }
    struct Operation {
        fileprivate let id:UUID
        fileprivate let owner:VoiceFoundationOwner
    }
    func begin(_ owner:VoiceFoundationOwner)throws->Operation{
        guard permits(owner),synchronous.count<32 else{throw CancellationError()}
        let id=UUID();synchronous[id]=owner;return Operation(id:id,owner:owner)
    }
    func finish(_ operation:Operation){
        guard synchronous[operation.id] == operation.owner else{return}
        synchronous[operation.id]=nil;notifyReturn()
    }
    func operation<Value>(owner:VoiceFoundationOwner,_ body:()throws->Value)throws->Value{
        let original=try begin(owner);defer{finish(original)}
        do{return try body()}catch{if !(error is CancellationError){recordFailure(owner)};throw error}
    }
    static func aggregate(_ results:[VoiceResourceRelease])->VoiceResourceRelease{
        var failed=false,uncertain=false
        for result in results{
            switch result{
            case .unknown(let issue):return .unknown(issue)
            case .released(.failed):failed=true
            case .released(.effectUncertain):uncertain=true
            default:break
            }
        }
        return .released(uncertain ? .effectUncertain:failed ? .failed:.cancelled)
    }
    func recordFailure(_ owner:VoiceFoundationOwner){failures.insert(owner)}
    func recordUnknown(_ owner:VoiceFoundationOwner,issue:String){if unknown[owner] == nil{unknown[owner]=issue}}
    func recordUncertain(_ owner:VoiceFoundationOwner){uncertain.insert(owner)}
    func release(_ owner:VoiceFoundationOwner?)->VoiceResourceRelease{
        guard !originals.values.contains(where:{owner == nil || $0.owner == owner}),
              !synchronous.values.contains(where:{owner == nil || $0 == owner}) else{return .unknown("file-original-return-pending")}
        if let issue=unknown.first(where:{owner == nil || $0.key == owner})?.value{return .unknown(issue)}
        if failures.contains(where:{owner == nil || $0 == owner}){return .released(.failed)}
        if uncertain.contains(where:{owner == nil || $0 == owner}){return .released(.effectUncertain)}
        return .released(.cancelled)
    }
    private func notifyReturn(){let captured=Array(waiters.values);waiters.removeAll();for waiter in captured{waiter.resume()}}
    func wait(_ owner:VoiceFoundationOwner?)async{
        while originals.values.contains(where:{owner == nil || $0.owner == owner}) || synchronous.values.contains(where:{owner == nil || $0 == owner}){
            await withCheckedContinuation{waiters[UUID()]=$0}
        }
    }
    /// Reserve the real outer owner BEFORE capture can call subscribers. The
    /// original prerequisite is then latched synchronously and always joined,
    /// even if a Stop reenters during capture or before the task first runs.
    func afterOriginal(owner:VoiceFoundationOwner,capture:()->VoiceFilePriorReturn,
        operation:@escaping @MainActor()throws->Void,failed:@escaping @MainActor (Error) ->Void)throws{
        guard permits(owner),originals.count<32 else{throw CancellationError()}
        let slot=VoiceFileCaptureSlot()
        let outer=Task{[self] in
            let original=await slot.value()
            await original.completion?.value
            if let issue=original.issue(){
                recordUnknown(owner,issue:issue)
                if permits(owner){failed(NSError(domain:"NeroVoice.OriginalFileConsumer",code:1,userInfo:[NSLocalizedDescriptionKey:issue]))}
                return
            }
            guard !Task.isCancelled,permits(owner) else{return}
            do{
                try self.operation(owner:owner,operation)
            }catch{recordFailure(owner);failed(error)}
        }
        retain(outer,owner:owner)
        slot.provide(capture())
    }

}

@MainActor struct VoiceFilePriorReturn {
    let completion:Task<Void,Never>?
    let issue:@MainActor () ->String?
}
@MainActor private final class VoiceFileCaptureSlot {
    private var original:VoiceFilePriorReturn?
    private var waiters:[CheckedContinuation<VoiceFilePriorReturn,Never>]=[]
    func provide(_ captured:VoiceFilePriorReturn){
        guard original == nil else{return};original=captured
        let prior=waiters;waiters.removeAll();for waiter in prior{waiter.resume(returning:captured)}
    }
    func value()async->VoiceFilePriorReturn{
        if let original{return original}
        // Cancellation cannot drop an already-admitted original handoff.
        return await withCheckedContinuation{waiters.append($0)}
    }
}

/// A cleanup right belongs only to a temp created by this app. Each actual
/// detached consumer acquires before starting and releases after its return.
@MainActor final class VoiceOwnedFileSource {
    let url:URL
    private let owned:Bool
    private let cleanup:@Sendable(URL)throws->Void
    private let failure:@MainActor(String)->Void
    private var readers=Set<UUID>(),discarded=false,cleaned=false
    private(set)var cleanupIssue:String?
    init(url:URL,owned:Bool,cleanup:@escaping @Sendable(URL)throws->Void={try FileManager.default.removeItem(at:$0)},failure:@escaping @MainActor(String)->Void={_ in}){
        self.url=url;self.owned=owned;self.cleanup=cleanup;self.failure=failure
    }
    func acquire()throws->UUID{
        guard !discarded else{throw VoiceServiceProblem.staleContext}
        let id=UUID();readers.insert(id);return id
    }
    func release(_ original:UUID){guard readers.remove(original) != nil else{return};cleanIfReturned()}
    func discard(){discarded=true;cleanIfReturned()}
    private func cleanIfReturned(){
        guard discarded,readers.isEmpty,!cleaned else{return}
        cleaned=true
        if owned{do{try cleanup(url)}catch{cleanupIssue=error.localizedDescription;failure(error.localizedDescription)}}
    }
}

/// One pending native completion plus its queued delivery. The lease is held
/// from before panel.begin until that original callback's MainActor return.
@MainActor final class VoiceFileCallback {
    private let gate:VoiceAudioCallbackAdmission
    private let original:VoiceAudioCallbackLease
    private var closed=false,delivered=false
    let returned:Task<Void,Never>
    init(){
        let admission=VoiceAudioCallbackAdmission();gate=admission
        original=admission.enter()!
        returned=Task{await admission.waitForReturn()}
    }
    func close(stop:()->Void){closed=true;gate.seal();stop();gate.nativeStopReturned()}
    /// No native begin occurred, so there is no future callback to fabricate.
    func abandonBeforeStart(){
        guard !delivered else{return};delivered=true;closed=true
        gate.seal();gate.nativeStopReturned();original.finish()
    }
    func deliver(_ publish:()->Void){
        guard !delivered else{return};delivered=true
        let allowed = !closed;closed=true;gate.seal();gate.nativeStopReturned()
        defer{original.finish()}
        if allowed{publish()}
    }
}
