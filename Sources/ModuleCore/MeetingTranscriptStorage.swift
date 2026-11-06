import Foundation
import CryptoKit
import Darwin

/// Value provenance of reviewed live rows copied into an independent refined snapshot.
public struct MeetingLiveRefinementSource: Codable, Equatable, Sendable {
    public let meetingID:UUID
    public let provider:MeetingASRProvider
    public let sha256:String
    public let includedRowIDs:[UUID]
    public let locale:String
    public let modelRevision:String?
    public let runtimeRevision:String?
    public let speakerModelRevision:String?
    public var notice:String {includedRowIDs.isEmpty ? "Refined snapshot saved. Later live edits stay separate." : "Refined from reviewed live words. Later live edits stay separate."}
    func validate() throws {
        guard MeetingTranscriptionOrigin.digest(sha256),includedRowIDs.count<=40000,
              Set(includedRowIDs).count==includedRowIDs.count,locale.utf8.count<=100,
              (modelRevision?.utf8.count ?? 0)<=120,(runtimeRevision?.utf8.count ?? 0)<=120,
              (speakerModelRevision?.utf8.count ?? 0)<=120 else{throw VoiceProblem.message("Invalid live refinement provenance")}
    }
}
fileprivate struct MeetingInitialLiveBinding: Equatable, Sendable { let sha256:String? }
/// Store-minted initial-read identity. It is not encoded or an authority receipt.
public struct MeetingTranscriptStorageBinding: Equatable, Sendable {
    fileprivate let folder: String
    fileprivate let device: UInt64
    fileprivate let inode: UInt64
    fileprivate let meeting: UUID
    fileprivate let provider: MeetingASRProvider
    fileprivate let legacySHA256: String?
    fileprivate let payloadSHA256: String?
    public let revision: String?
    fileprivate let initialLive:MeetingInitialLiveBinding?
    fileprivate let expectedLiveRefinementSource:MeetingLiveRefinementSource?
}
enum MeetingTranscriptStorage {
    private struct Envelope: Codable {
        let version: Int
        let meetingID: UUID
        let provider: MeetingASRProvider
        let legacySHA256: String?
        let revision: UUID
        let transcript: MeetingTranscript
    }
    static func exists(_ url: URL) -> Bool {
        var value=stat();if lstat(url.path,&value)==0{return true}
        return errno != ENOENT // diagnostic only; errors never authorize fallback
    }
    private static func identity(_ folder: URL) throws -> (String,UInt64,UInt64) {
        var value=stat();guard lstat(folder.path,&value)==0,value.st_mode&S_IFMT==S_IFDIR,
              let raw=realpath(folder.path,nil) else { throw VoiceProblem.message("Meeting transcript directory is unavailable") }
        defer{free(raw)};return (String(cString:raw),UInt64(value.st_dev),UInt64(value.st_ino))
    }
    static func byteCount(_ url: URL) throws -> Int? {
        var value=stat();if lstat(url.path,&value) != 0 { if errno==ENOENT{return nil};throw VoiceProblem.message("Transcript metadata is unavailable") }
        guard value.st_mode&S_IFMT==S_IFREG,value.st_nlink==1,value.st_size>=0,value.st_size<=32_000_000 else { throw VoiceProblem.message("Transcript is unavailable or exceeds its limit") }
        return Int(value.st_size)
    }
    static func data(_ url: URL) throws -> Data? {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
        if fd<0 { if errno==ENOENT{return nil};throw VoiceProblem.message("Transcript is unavailable") }
        defer{_ = close(fd)}
        var value=stat();guard fstat(fd,&value)==0,value.st_mode&S_IFMT==S_IFREG,value.st_nlink==1,value.st_size>=0,value.st_size<=32_000_000 else { throw VoiceProblem.message("Transcript is unavailable or exceeds its limit") }
        var result=Data(),buffer=[UInt8](repeating:0,count:65536)
        while true {
            let count=Darwin.read(fd,&buffer,min(buffer.count,32_000_001-result.count))
            guard count>=0 else { throw VoiceProblem.message("Transcript read failed") }
            if count==0{break};result.append(contentsOf:buffer.prefix(count))
            guard result.count<=32_000_000 else { throw VoiceProblem.message("Transcript exceeds its limit") }
        }
        return result
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    private static func paths(_ folder: URL,_ provider: MeetingASRProvider) -> (URL,URL) {
        (folder.appendingPathComponent(provider.transcriptFile),folder.appendingPathComponent("review-v2-"+provider.transcriptFile))
    }
    private static func binding(_ folder: URL,_ id: UUID,_ provider: MeetingASRProvider,_ legacy: String?,_ payload: String?,_ revision: String?) throws -> MeetingTranscriptStorageBinding {
        let (path,dev,ino)=try identity(folder)
        return .init(folder:path,device:dev,inode:ino,meeting:id,provider:provider,legacySHA256:legacy,payloadSHA256:payload,revision:revision,initialLive:nil,expectedLiveRefinementSource:nil)
    }
    private static func check(_ value: MeetingTranscriptStorageBinding,folder: URL,id: UUID,provider: MeetingASRProvider) throws {
        let (path,dev,ino)=try identity(folder)
        guard value.folder==path,value.device==dev,value.inode==ino,value.meeting==id,value.provider==provider else { throw VoiceProblem.message("Transcript belongs to a different source. Reload it before saving.") }
    }
    private static func updated(_ initial:MeetingTranscriptStorageBinding,legacy:String?,payload:String?,revision:String?,source:MeetingLiveRefinementSource? = nil) -> MeetingTranscriptStorageBinding {
        .init(folder:initial.folder,device:initial.device,inode:initial.inode,meeting:initial.meeting,provider:initial.provider,legacySHA256:legacy,payloadSHA256:payload,revision:revision,initialLive:nil,expectedLiveRefinementSource:source)
    }
    private static func validate(_ value: MeetingTranscript,id: UUID,provider: MeetingASRProvider) throws {
        try value.validate()
        if let source=value.liveRefinementSource {
            let protectedIDs=Set(value.utterances.filter{$0.reviewed || $0.correction != nil}.map(\.id))
            guard source.meetingID==id,source.provider==provider,Set(source.includedRowIDs).isSubset(of:protectedIDs) else{throw VoiceProblem.message("Live refinement snapshot belongs to a different meeting, provider or protected passage")}
        }
        guard value.providerID==provider.rawValue || (provider == .apple && value.providerID==nil) else { throw VoiceProblem.message("Transcript provider changed") }
        for origin in Array(value.transcriptionReview?.origins.values ?? Dictionary<String,MeetingTranscriptionOrigin>().values) + (value.transcriptionReview?.pending.map(\.origin) ?? []) {
            guard origin.meetingID==id,origin.provider==provider else { throw VoiceProblem.message("Transcription review belongs to a different meeting or provider") }
        }
    }
    static func prepareNew(folder:URL,id:UUID,provider:MeetingASRProvider,locale:String,modelRevision:String?,runtimeRevision:String?) throws -> MeetingTranscript {
        let initial=try binding(folder,id,provider,nil,nil,nil)
        let (v1,v2)=paths(folder,provider)
        guard !exists(v1),!exists(v2) else{throw VoiceProblem.message("A transcript appeared. Reload it before starting recognition.")}
        var result=MeetingTranscript(locale:locale,provider:provider,modelRevision:modelRevision,runtimeRevision:runtimeRevision)
        try check(initial,folder:folder,id:id,provider:provider);result.storageBinding=initial;try result.validate();return result
    }
    private static func checkInitialLive(_ initial:MeetingTranscriptStorageBinding,folder:URL,provider:MeetingASRProvider) throws {
        guard let live=initial.initialLive else{return}
        let url=folder.appendingPathComponent("live-"+provider.transcriptFile)
        guard try data(url).map(hash)==live.sha256 else{throw VoiceProblem.message("The live draft changed before the first refined save. Both versions are retained; reload before refining.")}
    }
    static func prepareFirstRefinement(folder:URL,id:UUID,provider:MeetingASRProvider,locale:String,modelRevision:String?,runtimeRevision:String?) throws -> MeetingTranscript {
        var result=try prepareNew(folder:folder,id:id,provider:provider,locale:locale,modelRevision:modelRevision,runtimeRevision:runtimeRevision)
        guard let initial=result.storageBinding else{throw VoiceProblem.message("First refinement source is unavailable")}
        let sourceURL=folder.appendingPathComponent("live-"+provider.transcriptFile)
        let bytes=try data(sourceURL)
        if let bytes {
            let live=try JSONDecoder().decode(MeetingTranscript.self,from:bytes);try live.validate()
            guard live.providerID==provider.rawValue,live.transcriptionReview==nil,live.liveRefinementSource==nil else{throw VoiceProblem.message("The selected live draft is unavailable for first refinement")}
            result.utterances=live.utterances.filter{$0.reviewed || $0.correction != nil}
            result.names=live.names
            result.transcriptionReview=MeetingTranscriptionReview()
            result.liveRefinementSource=MeetingLiveRefinementSource(meetingID:id,provider:provider,sha256:hash(bytes),includedRowIDs:result.utterances.map(\.id),locale:live.locale,modelRevision:live.modelRevision,runtimeRevision:live.runtimeRevision,speakerModelRevision:live.speakerModelRevision)
        }
        // No live completion/speaker flags or old recognition metadata enter the new run.
        let guarded=MeetingTranscriptStorageBinding(folder:initial.folder,device:initial.device,inode:initial.inode,meeting:initial.meeting,provider:initial.provider,legacySHA256:initial.legacySHA256,payloadSHA256:initial.payloadSHA256,revision:initial.revision,initialLive:MeetingInitialLiveBinding(sha256:bytes.map(hash)),expectedLiveRefinementSource:result.liveRefinementSource)
        try check(guarded,folder:folder,id:id,provider:provider);try checkInitialLive(guarded,folder:folder,provider:provider)
        let (v1,v2)=paths(folder,provider)
        guard !exists(v1),!exists(v2) else{throw VoiceProblem.message("A refined transcript appeared. Reload before refining.")}
        result.storageBinding=guarded;try validate(result,id:id,provider:provider);return result
    }
    static func read(folder: URL,id: UUID,provider: MeetingASRProvider) throws -> MeetingTranscript? {
        let initial=try binding(folder,id,provider,nil,nil,nil)
        let (v1,v2)=paths(folder,provider)
        if exists(v2) {
            guard let bytes=try data(v2) else { throw VoiceProblem.message("Transcription review needs recovery; no older fallback was opened") }
            let envelope=try JSONDecoder().decode(Envelope.self,from:bytes)
            guard ((envelope.version==2 && envelope.transcript.liveRefinementSource==nil) || (envelope.version==3 && envelope.transcript.liveRefinementSource != nil)),envelope.meetingID==id,envelope.provider==provider,
                  envelope.legacySHA256.map({MeetingTranscriptionOrigin.digest($0)}) ?? true else { throw VoiceProblem.message("Unsupported transcription review data; saved files are retained") }
            let legacy=try data(v1)
            guard legacy.map(hash)==envelope.legacySHA256 else { throw VoiceProblem.message("Transcript copies differ. Both versions are retained; this recording needs recovery before further edits.") }
            var result=envelope.transcript;guard result.transcriptionReview != nil else{throw VoiceProblem.message("Versioned transcription review metadata is missing")};try validate(result,id:id,provider:provider)
            try check(initial,folder:folder,id:id,provider:provider)
            result.storageBinding=updated(initial,legacy:envelope.legacySHA256,payload:hash(bytes),revision:envelope.revision.uuidString,source:result.liveRefinementSource)
            return result
        }
        guard let bytes=try data(v1) else{return nil}
        var result=try JSONDecoder().decode(MeetingTranscript.self,from:bytes);try validate(result,id:id,provider:provider)
        guard result.transcriptionReview==nil else { throw VoiceProblem.message("Transcription review requires its versioned file; saved words are retained") }
        try check(initial,folder:folder,id:id,provider:provider);result.storageBinding=updated(initial,legacy:hash(bytes),payload:nil,revision:nil);return result
    }
    private static func atomic(_ bytes: Data,to url: URL,exclusive: Bool) throws {
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".transcript-"+UUID().uuidString)
        let fd=open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd>=0 else{throw VoiceProblem.message("Cannot save transcript; existing words are retained")}
        var original=fd
        defer{if original>=0{_ = close(original)}}
        try bytes.withUnsafeBytes { raw in
            var written=0
            while written<raw.count {
                let count=Darwin.write(fd,raw.baseAddress!.advanced(by:written),raw.count-written)
                guard count>0 else{throw VoiceProblem.message("Transcript write failed; saved files are retained")};written+=count
            }
        }
        guard fsync(fd)==0 else{throw VoiceProblem.message("Transcript sync failed; saved files are retained")}
        original = -1;guard close(fd)==0 else{throw VoiceProblem.message("Transcript close failed; saved files are retained")}
        if exclusive {
            // Link publishes the complete synced file exclusively, never overwrites.
            guard link(temporary.path,url.path)==0 else{throw VoiceProblem.message("A transcript review already appeared. Reload before continuing.")}
            guard unlink(temporary.path)==0 else{throw VoiceProblem.message("Transcript publication needs recovery; files are retained")}
        } else { guard rename(temporary.path,url.path)==0 else{throw VoiceProblem.message("Transcript replacement failed; files are retained")} }
        let directory=open(url.deletingLastPathComponent().path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard directory>=0 else{throw VoiceProblem.message("Transcript directory sync is unavailable")}
        let synced=fsync(directory);let closed=close(directory)
        guard synced==0,closed==0 else{throw VoiceProblem.message("Transcript directory sync failed; reload retained files")}
    }
    static func save(_ value: MeetingTranscript,folder: URL,id: UUID,provider: MeetingASRProvider) throws -> MeetingTranscript {
        try validate(value,id:id,provider:provider);let initial=try binding(folder,id,provider,nil,nil,nil);let (v1,v2)=paths(folder,provider)
        if let original=value.storageBinding {
            guard value.liveRefinementSource==original.expectedLiveRefinementSource else{throw VoiceProblem.message("Copied live snapshot provenance cannot be removed or replaced")}
        }
        let hasV2=exists(v2),useV2=hasV2 || value.transcriptionReview != nil
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        if useV2 {
            guard value.transcriptionReview != nil else{throw VoiceProblem.message("Transcription review metadata cannot be removed") }
            guard let original=value.storageBinding else{throw VoiceProblem.message("Reload this transcript before saving review data")}
            try check(original,folder:folder,id:id,provider:provider)
            guard value.liveRefinementSource==original.expectedLiveRefinementSource else{throw VoiceProblem.message("Copied live snapshot provenance cannot be removed or replaced")}
            guard (try data(v1)).map(hash)==original.legacySHA256 else { throw VoiceProblem.message("Transcript copies differ. Both versions are retained; this recording needs recovery before further edits.") }
            if hasV2 {
                guard original.revision != nil,let current=try data(v2),hash(current)==original.payloadSHA256 else { throw VoiceProblem.message("Transcript review changed. Reload before choosing.") }
                let existing=try JSONDecoder().decode(Envelope.self,from:current)
                guard ((existing.version==2 && existing.transcript.liveRefinementSource==nil) || (existing.version==3 && existing.transcript.liveRefinementSource != nil)),existing.transcript.liveRefinementSource==original.expectedLiveRefinementSource else{throw VoiceProblem.message("Copied live snapshot provenance changed; reload retained files")}
            } else { guard original.revision==nil,original.payloadSHA256==nil else{throw VoiceProblem.message("Transcript review disappeared; recovery is required")} }
            let revision=UUID(),envelope=Envelope(version:value.liveRefinementSource==nil ? 2 : 3,meetingID:id,provider:provider,legacySHA256:original.legacySHA256,revision:revision,transcript:value)
            let bytes=try encoder.encode(envelope);guard bytes.count<=32_000_000 else{throw VoiceProblem.message("Transcription review exceeds its storage limit; saved words remain")}
            try checkInitialLive(original,folder:folder,provider:provider)
            try atomic(bytes,to:v2,exclusive:!hasV2)
            try checkInitialLive(original,folder:folder,provider:provider)
            guard (try data(v1)).map(hash)==original.legacySHA256 else{throw VoiceProblem.message("Transcript copies differ. Both versions are retained; this recording needs recovery before further edits.")}
            try check(original,folder:folder,id:id,provider:provider)
            var result=value;result.storageBinding=updated(original,legacy:original.legacySHA256,payload:hash(bytes),revision:revision.uuidString,source:value.liveRefinementSource);return result
        }
        let originalLegacy=try data(v1)
        var exclusiveLegacy=originalLegacy==nil
        if let original=value.storageBinding {
            try check(original,folder:folder,id:id,provider:provider)
            exclusiveLegacy=original.legacySHA256==nil
            guard original.revision==nil,originalLegacy.map(hash)==original.legacySHA256 else{throw VoiceProblem.message("Transcript changed before saving; reload it")}
        }
        let bytes=try encoder.encode(value);guard bytes.count<=32_000_000 else{throw VoiceProblem.message("Transcript exceeds its limit")}
        guard !exists(v2) else{throw VoiceProblem.message("Transcript review appeared; reload before saving")}
        if let original=value.storageBinding{try checkInitialLive(original,folder:folder,provider:provider)}
        try atomic(bytes,to:v1,exclusive:exclusiveLegacy)
        if let original=value.storageBinding{try checkInitialLive(original,folder:folder,provider:provider)}
        guard !exists(v2) else{throw VoiceProblem.message("Transcript review appeared while saving; reload retained files")}
        try check(initial,folder:folder,id:id,provider:provider)
        var result=value;result.storageBinding=updated(initial,legacy:hash(bytes),payload:nil,revision:nil);return result
    }
}
