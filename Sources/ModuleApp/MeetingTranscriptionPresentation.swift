import Foundation
import ModuleCore
import NookPluginSDK

struct MeetingTranscriptionPresentation {
    var open=true
    var candidate=""
    var candidateOffset=0
    var protectedOffset=0
    var protectedRow=0
}
struct MeetingTranscriptionReviewViewState: Codable {
    var count=0, protectedRows=0, protectedRow=0, candidateOffset=0, candidateNext=0, protectedOffset=0, protectedNext=0
    var progress=0.0
    var processing=false
    var open=false,recognitionComplete=false,busy=false,candidateMore=false,protectedMore=false
    var meeting="",provider="",revision="",candidate="",digest="",track="",attempt="",status=""
    var candidateText="",protectedText="",previousCandidate="",nextCandidate=""
    var candidateTitle="",protectedTitle="",modelRevision="",runtimeRevision=""
}
@MainActor enum MeetingTranscriptionResolver {
    static func load(store:MeetingStore,meetingID:UUID,provider:MeetingASRProvider,visible:MeetingTranscript,
        submittedMeeting:String,submittedProvider:String,revision:String,candidate:String,digest:String) throws -> (MeetingTranscript,MeetingTranscriptionAlternative) {
        guard submittedMeeting==meetingID.uuidString,submittedProvider==provider.rawValue,
              UUID(uuidString:revision) != nil,let id=UUID(uuidString:candidate),
              visible.transcriptionRevision==revision,MeetingNotebook.digest(visible)==digest,
              let durable=try store.transcript(meetingID,provider:provider),durable.transcriptionRevision==revision,MeetingNotebook.digest(durable)==digest,
              let item=durable.transcriptionReview?.pending.first(where:{$0.id==id}),item.origin.meetingID==meetingID,item.origin.provider==provider else {
            throw VoiceProblem.message("The transcription review changed. Reload and compare this passage again.")
        }
        return (durable,item)
    }
    static func resolve(store:MeetingStore,meetingID:UUID,provider:MeetingASRProvider,visible:MeetingTranscript,
        submittedMeeting:String,submittedProvider:String,revision:String,candidate:String,digest:String,choice:MeetingTranscriptionChoice) throws -> MeetingTranscript {
        let (durable,item)=try load(store:store,meetingID:meetingID,provider:provider,visible:visible,submittedMeeting:submittedMeeting,submittedProvider:submittedProvider,revision:revision,candidate:candidate,digest:digest)
        return try store.saveTranscript(durable.resolveAlternative(item.id,expectedDigest:digest,choice:choice),id:meetingID,provider:provider)
    }
}
extension MeetingModel {
    /// Scalar paging preserves every UTF8 byte even for one huge grapheme.
    static func transcriptionPage(_ text:String,offset:Int) -> (String,Int,Bool) {
        let scalars=text.unicodeScalars
        guard offset>=0,offset<=scalars.count else{return ("",0,!text.isEmpty)}
        var index=scalars.index(scalars.startIndex,offsetBy:offset),out=String.UnicodeScalarView(),bytes=0,next=offset
        while index<scalars.endIndex {
            let scalar=scalars[index],cost=String(scalar).utf8.count
            if bytes+cost>1024{break};out.append(scalar);bytes+=cost;next+=1;index=scalars.index(after:index)
        }
        return (String(out),next,index<scalars.endIndex)
    }
    func transcriptionReviewView() -> MeetingTranscriptionReviewViewState {
        var view=MeetingTranscriptionReviewViewState();view.busy=occupied;view.processing=processing
        view.progress=processProgress.isFinite ? min(1,max(0,processProgress)) : 0
        guard let selected,let transcript,let pending=transcript.transcriptionReview?.pending,!pending.isEmpty else{return view}
        let index=pending.firstIndex(where:{$0.id.uuidString==transcriptionPresentation.candidate}) ?? 0,item=pending[index]
        let protected=transcript.protectedPassages(for:item),row=min(max(0,transcriptionPresentation.protectedRow),max(0,protected.count-1))
        let same=transcriptionPresentation.candidate==item.id.uuidString
        let co=same ? transcriptionPresentation.candidateOffset : 0,po=same ? transcriptionPresentation.protectedOffset : 0
        let cp=Self.transcriptionPage(item.candidate.text,offset:co)
        let pp=Self.transcriptionPage(protected.isEmpty ? "No current protected passage" : (protected[row].correction ?? protected[row].text),offset:po)
        view.open=transcriptionPresentation.open;view.count=pending.count;view.recognitionComplete=transcript.completedTracks.contains(item.origin.track) && Set(selected.chunks.map(\.track)).isSubset(of:Set(transcript.completedTracks))
        view.meeting=selected.id.uuidString;view.provider=asrProvider.rawValue;view.revision=transcript.transcriptionRevision ?? ""
        view.candidate=item.id.uuidString;view.digest=MeetingNotebook.digest(transcript);view.track=item.origin.track;view.attempt=item.origin.attemptID.uuidString
        view.status="May overlap reviewed words. Keep both preserves two parallel passages; keeping your correction discards this entire new passage, including its beginning and ending."
        if let source=transcript.liveRefinementSource{view.status += " " + source.notice}
        view.candidateTitle=String(format:"%.2f–%.2fs",item.candidate.start,item.candidate.end)+" · "+(item.origin.track=="mic" ? "Room" : "Call")+" · "+item.origin.provider.title+" · unassigned recognition"
        if !protected.isEmpty {
            let line=protected[row],speaker=line.speaker.flatMap{transcript.names[$0]} ?? "Unassigned"
            view.protectedTitle=String(format:"%.2f–%.2fs",line.start,line.end)+" · "+(line.track=="mic" ? "Room" : "Call")+" · "+speaker
        }
        view.modelRevision=item.origin.modelRevision ?? "Legacy or unspecified model"
        view.runtimeRevision=item.origin.runtimeRevision ?? "Unspecified recognition runtime"
        view.candidateText=cp.0;view.candidateOffset=co;view.candidateNext=cp.1;view.candidateMore=cp.2
        view.protectedText=pp.0;view.protectedOffset=po;view.protectedNext=pp.1;view.protectedMore=pp.2;view.protectedRow=row;view.protectedRows=protected.count
        if index>0{view.previousCandidate=pending[index-1].id.uuidString};if index+1<pending.count{view.nextCandidate=pending[index+1].id.uuidString}
        if !view.open{view.candidateText="";view.protectedText=""}
        return view
    }
    func handleTranscriptionReview(meeting:String,provider:String,revision:String,candidate:String,digest:String,choice:String,source:String,row:Double,offset:Double) throws {
        guard permitMeetingWork(),!occupied,let selected,!showingLiveTranscript,let store else{throw VoiceProblem.message("This transcription review is unavailable")}
        let sourceProvider=asrProvider
        func sameSource() -> Bool {permitMeetingWork() && !occupied && !showingLiveTranscript && self.selected?.id==selected.id && asrProvider==sourceProvider && meeting==selected.id.uuidString && provider==sourceProvider.rawValue}
        do {
        guard let visible=transcript,
              row.isFinite,row.rounded()==row,(0...39999).contains(row),offset.isFinite,offset.rounded()==offset,(0...32_000_000).contains(offset),
              ["candidate","protected"].contains(source),["open","close","page","keepCorrection","keepBoth"].contains(choice) else {throw VoiceProblem.message("This transcription review is unavailable")}
        let (durable,item)=try MeetingTranscriptionResolver.load(store:store,meetingID:selected.id,provider:sourceProvider,visible:visible,submittedMeeting:meeting,submittedProvider:provider,revision:revision,candidate:candidate,digest:digest)
        if choice=="open" || choice=="close" {
            transcriptionPresentation.open=choice=="open";transcript=durable;changed?();return
        }
        if choice=="page" {
            let passages=durable.protectedPassages(for:item)
            let text=source=="candidate" ? item.candidate.text : (passages.indices.contains(Int(row)) ? passages[Int(row)].correction ?? passages[Int(row)].text : "")
            guard Int(offset)<=text.unicodeScalars.count,(source=="candidate" || passages.indices.contains(Int(row))) else{throw VoiceProblem.message("Invalid review page")}
            if transcriptionPresentation.candidate != candidate{transcriptionPresentation=MeetingTranscriptionPresentation(open:true,candidate:candidate)}
            if source=="candidate"{transcriptionPresentation.candidateOffset=Int(offset)}
            else{transcriptionPresentation.protectedRow=Int(row);transcriptionPresentation.protectedOffset=Int(offset)}
            transcript=durable;changed?();return
        }
        guard transcriptionPresentation.open else{throw VoiceProblem.message("Open the comparison before choosing a transcription passage")}
        guard let decision=MeetingTranscriptionChoice(rawValue:choice) else{throw VoiceProblem.message("Unknown review choice")}
        transcript=try MeetingTranscriptionResolver.resolve(store:store,meetingID:selected.id,provider:sourceProvider,visible:visible,submittedMeeting:meeting,submittedProvider:provider,revision:revision,candidate:candidate,digest:digest,choice:decision)
        transcriptionPresentation=MeetingTranscriptionPresentation();highlightedUtterance="";highlightedCitation="";highlightedSourceText=""
        status=decision == .keepBoth ? "Both complete passages retained. Review possible overlapping speech." : "Your correction retained; the selected entire generated passage was discarded."
        searchLibrary();changed?()
        } catch {
            let originalError=error
            // A refusal is not a retry. Refresh only this still-owned idle source.
            if sameSource() {
                do {
                    let refreshed=try store.transcript(selected.id,provider:sourceProvider)
                    if sameSource() {
                        transcript=refreshed
                        transcriptionPresentation=MeetingTranscriptionPresentation(open:refreshed != nil)
                        status=refreshed==nil ? "The saved transcript is unavailable. This recording needs recovery before further edits." : "Transcript changed. Compare the refreshed passages before choosing again."
                        changed?()
                    }
                } catch {
                    if sameSource() {
                        // Bad/divergent V2 stays refused. Never reopen V1/live/another provider.
                        transcript=nil;transcriptionPresentation=MeetingTranscriptionPresentation(open:false)
                        status=error.localizedDescription;changed?()
                    }
                }
            }
            throw originalError
        }

    }
}

/// No hidden notes/bookmarks/Ask/transcript payload rides in comparison frames.
/// Two1024UTF8 scalar pages remain below32768 even after JSON escaping.
enum MeetingTranscriptionViewFrame {
    static func state(_ review:MeetingTranscriptionReviewViewState) -> [String:PluginValue] {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return ["selected":.string(review.meeting),"title":.string("Review transcription updates"),"notebookPage":.string("transcript"),
                "busy":.boolean(review.busy),"processing":.boolean(review.processing),"progress":.number(review.progress),"active":.boolean(false),"library":.string("[]"),"transcript":.string("[]"),"speakers":.string("{}"),
                "transcriptionReview":.string(String(decoding:(try? encoder.encode(review)) ?? Data(),as:UTF8.self))]
    }
}
