import Foundation
import Darwin
import ModuleCore

/// Exact FileHandle objects stay retained until their owner's retirement. A
/// closed numeric descriptor is never consulted again or mistaken for a new FD.
final class VoiceOriginalIOClose:@unchecked Sendable{
    private let lock=NSLock()
    private var closed:[ObjectIdentifier:FileHandle]=[:]
    let receipt:MeetingCleanupReceipt
    init(_ receipt:MeetingCleanupReceipt){self.receipt=receipt}
    func close(_ handle:FileHandle,context:String){
        close(handle,context:context){try $0.close()}
    }
    func closeThrowing(_ handle:FileHandle,context:String)throws{
        lock.lock();let id=ObjectIdentifier(handle)
        guard closed[id] == nil else{lock.unlock();return}
        closed[id]=handle;lock.unlock()
        do{try handle.close()}catch{receipt.record(context+": \(error)");throw error}
    }
    func close(_ handle:FileHandle,context:String,operation:(FileHandle)throws->Void){
        lock.lock();let id=ObjectIdentifier(handle)
        guard closed[id] == nil else{lock.unlock();return}
        closed[id]=handle;lock.unlock()
        receipt.close(handle,context:context,operation:operation)
    }
}

/// One bounded physical stdout reader. Stop closes future callback admission;
/// entered callbacks retain the original FD until their actual syscall returns.
final class VoiceOriginalPipeReader:@unchecked Sendable{
    private let handle:FileHandle
    private let closer:VoiceOriginalIOClose
    private let callbacks=VoiceAudioCallbackAdmission()
    private let lock=NSLock(),readLock=NSLock()
    private var original:Task<Void,Never>?
    private var continuation:AsyncThrowingStream<Data,Error>.Continuation?
    init(handle:FileHandle,closer:VoiceOriginalIOClose){self.handle=handle;self.closer=closer}
    func install(_ output:AsyncThrowingStream<Data,Error>.Continuation,
                 checkpoint:(@Sendable()->Void)?=nil){
        lock.lock();continuation=output;lock.unlock()
        let callbacks=callbacks,handle=handle,closer=closer,readLock=readLock
        handle.readabilityHandler={file in
            guard let entered=callbacks.enter()else{return};defer{entered.finish()}
            guard readLock.try()else{return};defer{readLock.unlock()}
            checkpoint?()
            guard callbacks.isOpen else{return}
            var bytes=[UInt8](repeating:0,count:262_144)
            var count:Int
            repeat{count=Darwin.read(file.fileDescriptor,&bytes,bytes.count)}while count<0 && errno == EINTR
            if count<0{
                let code=errno
                closer.receipt.record("stdout read failed: \(code)")
                file.readabilityHandler=nil
                output.finish(throwing:VoiceProblem.message("Local speech output read failed (\(code))"));return
            }
            if count==0{file.readabilityHandler=nil;output.finish();return}
            for offset in stride(from:0,to:count,by:16_384){
                let data=Data(bytes[offset..<min(offset+16_384,count)])
                switch output.yield(data){
                case .enqueued:break
                case .dropped:file.readabilityHandler=nil;output.finish(throwing:VoiceProblem.message("Local speech output could not keep up"));return
                case .terminated:file.readabilityHandler=nil;return
                @unknown default:file.readabilityHandler=nil;output.finish(throwing:VoiceProblem.message("Local speech output unavailable"));return
                }
            }
        }
    }
    func seal(){
        callbacks.seal()
        lock.lock();let original=continuation;lock.unlock();original?.finish()
    }
    /// The setter/close can contend with an already entered Foundation callback;
    /// keep it off MainActor, and close only after that original callback returns.
    func retire()->Task<Void,Never>{
        lock.lock();defer{lock.unlock()}
        if let original{return original}
        callbacks.seal();continuation?.finish()
        let handle=handle,callbacks=callbacks,closer=closer
        let task=Task.detached{
            handle.readabilityHandler=nil
            callbacks.nativeStopReturned()
            await callbacks.waitForReturn()
            closer.close(handle,context:"stdout close failed")
        }
        original=task;return task
    }
}

/// Cross-module result custody for actual original I/O joins. This does not
/// turn a task or a caller-supplied owner ID into native/resource authority.
@MainActor public final class VoiceOriginalIOOutcomes{
    private let receipt=MeetingCleanupReceipt()
    public var issue:String?{receipt.issue}
    public init(){}
    public func join(_ original:Task<Void,Never>?,issue:@escaping @MainActor ()->String?)->Task<Void,Never>?{
        guard let original else{if let value=issue(){receipt.record(value)};return nil}
        return Task{[receipt] in
            await original.value
            if let value=issue(){receipt.record(value)}
        }
    }
}
