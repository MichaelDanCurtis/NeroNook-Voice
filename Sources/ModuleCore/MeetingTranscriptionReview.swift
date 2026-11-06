import Foundation

public enum MeetingTranscriptionChoice: String, Codable, Sendable { case keepCorrection, keepBoth }
public struct MeetingTranscriptionOrigin: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let meetingID: UUID
    public let provider: MeetingASRProvider
    public let track: String
    public let baseDigest: String
    public let modelRevision: String?
    public let runtimeRevision: String?
    public init(attemptID: UUID = UUID(), meetingID: UUID, provider: MeetingASRProvider, track: String,
                baseDigest: String, modelRevision: String? = nil, runtimeRevision: String? = nil) {
        self.attemptID=attemptID; self.meetingID=meetingID; self.provider=provider; self.track=track
        self.baseDigest=baseDigest; self.modelRevision=modelRevision; self.runtimeRevision=runtimeRevision
    }
    func validate() throws {
        guard ["mic","system"].contains(track), Self.digest(baseDigest),
              (modelRevision?.utf8.count ?? 0)<=120, (runtimeRevision?.utf8.count ?? 0)<=120 else { throw VoiceProblem.message("Invalid transcription origin") }
    }
    static func digest(_ text: String) -> Bool { text.utf8.count==64 && text.utf8.allSatisfy{(48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)} }
}
public struct MeetingTranscriptionAlternative: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { candidate.id }
    public let candidate: MeetingUtterance
    public let origin: MeetingTranscriptionOrigin
    public let protectedFingerprints: [String:String]
    public init(candidate: MeetingUtterance, origin: MeetingTranscriptionOrigin, protectedFingerprints: [String:String]) {
        self.candidate=candidate;self.origin=origin;self.protectedFingerprints=protectedFingerprints
    }
}
public struct MeetingTranscriptionReview: Codable, Equatable, Sendable {
    public var pending: [MeetingTranscriptionAlternative]
    public var origins: [String:MeetingTranscriptionOrigin]
    public var keptAlternativeIDs: [UUID]?
    public var keptProtectedFingerprints: [String:[String:String]]?
    public init(pending: [MeetingTranscriptionAlternative] = [], origins: [String:MeetingTranscriptionOrigin] = [:]) { self.pending=pending;self.origins=origins }
}
extension MeetingTranscript {
    public static var keptRecognitionAlternativeLabel: String { "Kept recognition version · may overlap reviewed speech" }
    public func isKeptRecognitionAlternative(_ id:UUID) -> Bool {transcriptionReview?.keptAlternativeIDs?.contains(id) ?? false}
    public var pendingTranscriptionCount: Int { transcriptionReview?.pending.count ?? 0 }
    public var hasPendingTranscription: Bool { pendingTranscriptionCount>0 }
    public var transcriptionRevision: String? { storageBinding?.revision }
    public static var transcriptionReviewNotice: String { "Review the new transcription alternatives before asking questions or creating notes. Recognition can finish while your corrections are retained." }
    public func requireResolvedTranscription() throws {
        guard !hasPendingTranscription else { throw VoiceProblem.message(Self.transcriptionReviewNotice) }
    }
    private static func overlaps(_ a: MeetingUtterance, _ b: MeetingUtterance) -> Bool { a.track==b.track && a.end>=b.start && b.end>=a.start }
    public func protectedPassages(for alternative: MeetingTranscriptionAlternative) -> [MeetingUtterance] {
        utterances.filter { ($0.reviewed || $0.correction != nil) && Self.overlaps($0,alternative.candidate) }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }
    public mutating func beginContinuation(track: String, origin: MeetingTranscriptionOrigin) throws {
        try validate();try origin.validate()
        guard track==origin.track, providerID==origin.provider.rawValue || (providerID==nil && origin.provider == .apple), !completedTracks.contains(track) else { throw VoiceProblem.message("This transcription continuation is no longer current") }
        var next=self
        let protected=utterances.filter { $0.track==track && ($0.reviewed || $0.correction != nil) }
        if !protected.isEmpty || next.transcriptionReview != nil {
            if next.transcriptionReview==nil { next.transcriptionReview=MeetingTranscriptionReview() }
        }
        next.utterances.removeAll { $0.track==track && !$0.reviewed && $0.correction==nil }
        next.pruneTranscriptionOrigins();try next.validate();self=next
    }
    public mutating func receiveContinuation(_ rows: [MeetingUtterance], origin: MeetingTranscriptionOrigin) throws {
        try origin.validate();try validate();var next=self
        var knownIDs=Set(utterances.map(\.id)+(transcriptionReview?.pending.map(\.id) ?? []))
        let protectedRows=utterances.filter{$0.reviewed || $0.correction != nil}
        guard providerID==origin.provider.rawValue || (providerID==nil && origin.provider == .apple) else { throw VoiceProblem.message("Transcription provider changed") }
        var encodedBudget=try JSONEncoder().encode(next).count
        let originBytes=try JSONEncoder().encode(origin).count
        for line in rows {
            var check=MeetingTranscript(locale:locale,provider:origin.provider);check.utterances=[line];try check.validate()
            guard line.track==origin.track, !line.reviewed, line.correction==nil, line.speaker==nil,
                  !knownIDs.contains(line.id) else { throw VoiceProblem.message("Invalid or repeated transcription passage") }
            let protected=protectedRows.filter { Self.overlaps($0,line) }
            // Bound provenance allocation BEFORE creating a wide comparison map.
            guard next.utterances.count+next.pendingTranscriptionCount<40000,
                  protected.isEmpty || next.pendingTranscriptionCount<4096 else {throw VoiceProblem.message("Transcription review limit reached; saved words and audio are retained")}
            let incoming=try JSONEncoder().encode(line).count
            let addition=incoming+(protected.isEmpty ? originBytes : 2*originBytes)+512+protected.count*128
            guard encodedBudget<=32_000_000,addition<=32_000_000-encodedBudget-2048 else {throw VoiceProblem.message("Transcription review storage limit reached; saved words and audio are retained")}

            encodedBudget+=addition;knownIDs.insert(line.id)
            if !protected.isEmpty {
                if next.transcriptionReview==nil { next.transcriptionReview=MeetingTranscriptionReview() }
                let fingerprints=Dictionary(uniqueKeysWithValues:protected.map{($0.id.uuidString,MeetingQuestionSnapshot.fingerprint($0,names:next.names))})
                next.transcriptionReview?.pending.append(.init(candidate:line,origin:origin,protectedFingerprints:fingerprints))
            } else { next.utterances.append(line) }
            if next.transcriptionReview != nil { next.transcriptionReview?.origins[line.id.uuidString]=origin }
        }
        try next.validate();self=next
    }
    public mutating func finishContinuation(track: String) throws {
        guard ["mic","system"].contains(track) else { throw VoiceProblem.message("Invalid transcription track") }
        var next=self;if !next.completedTracks.contains(track){next.completedTracks.append(track)};try next.validate();self=next
    }
    public func resolveAlternative(_ id: UUID, expectedDigest: String, choice: MeetingTranscriptionChoice) throws -> MeetingTranscript {
        guard expectedDigest==MeetingNotebook.digest(self), let index=transcriptionReview?.pending.firstIndex(where:{$0.id==id}) else { throw VoiceProblem.message("The transcript changed. Review this passage again before choosing.") }
        var next=self;let item=next.transcriptionReview!.pending.remove(at:index)
        if choice == .keepBoth {
            guard !next.utterances.contains(where:{$0.id==item.id}) else { throw VoiceProblem.message("This passage is already present") }
            var line=item.candidate;line.reviewed=true;next.utterances.append(line)
            if next.transcriptionReview?.keptAlternativeIDs==nil{next.transcriptionReview?.keptAlternativeIDs=[]}
            next.transcriptionReview?.keptAlternativeIDs?.append(line.id)
            next.transcriptionReview?.keptAlternativeIDs?.sort{$0.uuidString<$1.uuidString}
            if next.transcriptionReview?.keptProtectedFingerprints==nil{next.transcriptionReview?.keptProtectedFingerprints=[:]}
            next.transcriptionReview?.keptProtectedFingerprints?[line.id.uuidString]=item.protectedFingerprints
        }
        next.pruneTranscriptionOrigins();try next.validate();return next
    }
    mutating func pruneTranscriptionOrigins() {
        guard var review=transcriptionReview else{return}
        let ids=Set(utterances.map{$0.id.uuidString}+review.pending.map{$0.id.uuidString})
        review.origins=review.origins.filter{ids.contains($0.key)}
        review.keptAlternativeIDs=review.keptAlternativeIDs?.filter{ids.contains($0.uuidString)}
        review.keptProtectedFingerprints=review.keptProtectedFingerprints?.filter{ids.contains($0.key)}
        transcriptionReview=review
    }
    func validateTranscriptionReview() throws {
        guard let review=transcriptionReview else{return}
        let ids=Set(utterances.map(\.id));let pending=review.pending
        guard pending.count<=4096,utterances.count+pending.count<=40000,Set(pending.map(\.id)).count==pending.count,
              !pending.contains(where:{ids.contains($0.id)}),review.origins.count<=40000 else { throw VoiceProblem.message("Transcription review limit reached; saved words and audio are retained") }
        let known=Set(utterances.map{$0.id.uuidString}+pending.map{$0.id.uuidString})
        let canonical=Dictionary(uniqueKeysWithValues:utterances.map{($0.id,$0)})
        let tracks=Dictionary(uniqueKeysWithValues:utterances.map{($0.id.uuidString,$0.track)}+pending.map{($0.id.uuidString,$0.candidate.track)})
        for (id,origin) in review.origins {
            try origin.validate()
            let track=tracks[id]
            guard known.contains(id),track==origin.track else{throw VoiceProblem.message("Invalid transcription provenance")}
        }
        let kept=review.keptAlternativeIDs ?? []
        guard kept.count<=40000,Set(kept).count==kept.count,Set((review.keptProtectedFingerprints ?? [:]).keys)==Set(kept.map(\.uuidString)),
              kept.allSatisfy({id in canonical[id]?.reviewed==true && review.origins[id.uuidString] != nil}) else{throw VoiceProblem.message("Invalid retained recognition version")}
        for map in (review.keptProtectedFingerprints ?? [:]).values {
            guard !map.isEmpty,map.count<=40000,map.allSatisfy({UUID(uuidString:$0.key) != nil && MeetingTranscriptionOrigin.digest($0.value)}) else{throw VoiceProblem.message("Invalid recognition comparison provenance")}
        }
        for item in pending {
            try item.origin.validate();var check=MeetingTranscript(locale:locale,provider:item.origin.provider);check.utterances=[item.candidate];try check.validate()
            guard item.candidate.track==item.origin.track,item.candidate.correction==nil,!item.candidate.reviewed,item.candidate.speaker==nil,
                  !item.protectedFingerprints.isEmpty,item.protectedFingerprints.count<=40000,
                  item.protectedFingerprints.allSatisfy({UUID(uuidString:$0.key) != nil && MeetingTranscriptionOrigin.digest($0.value)}),
                  review.origins[item.id.uuidString]==item.origin else { throw VoiceProblem.message("Invalid transcription alternative") }
        }
    }
    public var pendingTranscriptionText: String {
        guard let items=transcriptionReview?.pending,!items.isEmpty else{return ""}
        return "\n## Unresolved recognition alternatives — not combined transcript\n" + items.map {
            "[\(String(format:"%.2f",$0.candidate.start))–\(String(format:"%.2f",$0.candidate.end))] \($0.origin.track) · \($0.origin.provider.rawValue) · attempt \($0.origin.attemptID.uuidString)\n\($0.candidate.text)"
        }.joined(separator:"\n\n") + "\nReview these complete passages alongside your retained corrections.\n"
    }
}
