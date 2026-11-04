import Foundation
import ModuleCore

/// The actual saved Apple/local branches. No model/store/global construction.
@MainActor enum SavedMeetingTrackProcessor {
    /// The actual saved-transcription source selector; no model/global construction.
    static func prepareTranscription(store:MeetingStore,meetingID:UUID,provider:MeetingASRProvider,locale:String,
        modelRevision:String?=nil,runtimeRevision:String?=nil) throws -> MeetingTranscript {
        try store.transcript(meetingID,provider:provider) ?? store.prepareFirstRefinement(meetingID,provider:provider,locale:locale,modelRevision:modelRevision,runtimeRevision:runtimeRevision)
    }
    /// Refined records are authoritative; live availability is diagnostic until selected.
    static func loadPresentation(store:MeetingStore,meetingID:UUID,provider:MeetingASRProvider,preferLive:Bool=false) throws -> (transcript:MeetingTranscript?,hasLive:Bool,hasRefined:Bool,showingLive:Bool) {
        let refined=try store.transcript(meetingID,provider:provider)
        if !preferLive,let refined {
            let available:Bool
            do{available=try store.transcriptStorageByteCount(meetingID,provider:provider,live:true) != nil}
            catch{available=true} // A retained but unreadable live draft must not hide refined words.
            return (refined,available,true,false)
        }
        // Existing bounded metadata refuses known unsafe/special files before live decoding.
        _ = try store.transcriptStorageByteCount(meetingID,provider:provider,live:true)
        let live=try store.liveTranscript(meetingID,provider:provider)
        if preferLive,live==nil{throw VoiceProblem.message("The saved live draft is unavailable. The refined snapshot remains separate.")}
        return (live,live != nil,refined != nil,live != nil)
    }
    static func run(transcript: MeetingTranscript, meetingID: UUID, track: String,
        provider: MeetingASRProvider, modelRevision: String? = nil, runtimeRevision: String? = nil,
        assemble: @MainActor () async throws -> Void,
        apple: @MainActor (_ emit: @escaping @MainActor (MeetingUtterance) throws -> Void) async throws -> Void,
        local: @MainActor () async throws -> [MeetingUtterance],
        checkpointDue: @escaping @MainActor () -> Bool,
        save: @escaping @MainActor (MeetingTranscript) throws -> MeetingTranscript,
        publish: @escaping @MainActor (MeetingTranscript) -> Void,
        requireCurrent: @escaping @MainActor () throws -> Void,
        didReceive: @escaping @MainActor (MeetingUtterance) -> Void = { _ in }) async throws -> MeetingTranscript {
        try Task.checkCancellation();try requireCurrent();try await assemble()
        try Task.checkCancellation();try requireCurrent()
        guard !transcript.completedTracks.contains(track) else{return transcript}
        let origin=MeetingTranscriptionOrigin(meetingID:meetingID,provider:provider,track:track,
            baseDigest:MeetingNotebook.digest(transcript),modelRevision:modelRevision,runtimeRevision:runtimeRevision)
        var callbackActive=true
        defer{callbackActive=false}
        var result=transcript;try result.beginContinuation(track:track,origin:origin)
        if provider == .apple {
            try await apple { line in
                guard callbackActive else{throw CancellationError()}
                try Task.checkCancellation();try requireCurrent()
                var next=result;try next.receiveContinuation([line],origin:origin);didReceive(line)
                try Task.checkCancellation();try requireCurrent()
                if checkpointDue() {
                    try Task.checkCancellation();try requireCurrent();next=try save(next)
                    try Task.checkCancellation();try requireCurrent();publish(next)
                    try Task.checkCancellation();try requireCurrent()
                }
                result=next
            }
        } else {
            let rows=try await local();try Task.checkCancellation();try requireCurrent()
            for start in stride(from:0,to:rows.count,by:16) {
                await Task.yield();try Task.checkCancellation();try requireCurrent()
                try result.receiveContinuation(Array(rows[start..<min(start+16,rows.count)]),origin:origin)
            }
        }
        try Task.checkCancellation();try requireCurrent();try result.finishContinuation(track:track)
        result=try save(result);try Task.checkCancellation();try requireCurrent();publish(result);try Task.checkCancellation();try requireCurrent();return result
    }
}
