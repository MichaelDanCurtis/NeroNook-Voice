import Foundation
import Combine
import ModuleCore

/// One explicit, short-lived preparation. No audio engine or capture APIs.
/// The warmed recognizer is consumed once; used recognition is never recycled.
@MainActor public final class SpeechPreloader: ObservableObject {
    @Published public private(set) var status = "Prepare Talk without recording"
    @Published public private(set) var ready = false
    @Published public private(set) var preparing = false
    @Published public private(set) var retiring = false
    private var resource: MeetingLiveTranscriber?
    private var identity: String?
    private var epoch = UUID()
    private var expiry: Task<Void, Never>?
    private let preparationGate = SpeechPreparationGate()
    private var retirement: Task<Void, Never>?
    private var retirementID: UUID?
    private let ioOutcomes=VoiceOriginalIOOutcomes()
    private let timerReturns=SpeechWorkerRetirement()
    public var resourceReturnIssue:String?{ioOutcomes.issue}
    private var publishingStatus = false
    private var pendingStatus: String?
    public var busy: Bool { preparing || preparationGate.busy || retirement != nil }
    public func retirementCompletion()->Task<Void,Never>?{
        let original=retirement,expiry=timerReturns.completion()
        guard original != nil || expiry != nil else{return nil}
        return Task{await original?.value;await expiry?.value}
    }
    private let hold: Duration
    private let prepareWorker: (MeetingLiveTranscriber, VoiceASRProvider, String, URL) async throws -> Void
    public init() {
        hold = .seconds(120)
        prepareWorker = { service, provider, locale, helper in
            try await service.start(provider: provider, tracks: ["mic"], locale: locale, helper: helper,
                                    update: { _ in throw VoiceProblem.message("Prepared speech returned words without audio") }, failure: { _ in })
        }
    }
    init(hold: Duration, prepare: @escaping (MeetingLiveTranscriber, VoiceASRProvider, String, URL) async throws -> Void) {
        self.hold = hold; prepareWorker = prepare
    }
    private func key(_ provider: VoiceASRProvider, _ locale: String, _ helper: URL) -> String {
        provider.rawValue + "\n" + locale + "\n" + helper.standardizedFileURL.path
    }
    public func prepare(provider: VoiceASRProvider, locale: String, helper: URL) async throws {
        let permit = try await preparationGate.acquire()
        defer { preparationGate.release(permit); objectWillChange.send() }
        let previousEpoch = epoch, token = UUID(); epoch = token
        LocalModelProcess.claimIdle(previousEpoch)
        releaseOwnedResources()
        let originalRetirement = retirement
        var owned: MeetingLiveTranscriber?
        do {
            try requireCurrent(token)
            preparing = true
            try requireCurrent(token)
            setStatus("Loading selected speech model · microphone off")
            try requireCurrent(token)
            await originalRetirement?.value
            try requireCurrent(token)
            let service = MeetingLiveTranscriber(); owned = service; resource = service
            identity = key(provider, locale, helper)
            try await prepareWorker(service, provider, locale, helper)
            try requireCurrent(token)
            guard service.transfer(update: { _ in throw VoiceProblem.message("Prepared speech returned words without audio") }, failure: { [weak self] _ in
                guard let self, self.epoch == token else { return }; self.release(); self.setStatus("Preparation ended · press Prepare to retry")
            }, dormant: true) else { throw VoiceProblem.message("The speech model could not stay ready") }
            LocalModelProcess.reserveIdle(token) { [weak self] in
                guard let self, self.epoch == token else { return }; self.release()
            }
            try requireCurrent(token)
            expiry = Task { [weak self] in
                try? await Task.sleep(for: self?.hold ?? .seconds(120))
                guard !Task.isCancelled, let self, self.epoch == token else { return }
                self.release(); self.setStatus("Prepared model released after idle time")
            }
            setStatus("Talk ready · microphone off · releases after 2 minutes")
            try requireCurrent(token)
            preparing = false
            try requireCurrent(token)
            ready = true
            // @Published can synchronously call a subscriber which releases
            // this preparation. Never leave a stale ready flag afterward.
            try requireCurrent(token)
        } catch {
            if epoch == token {
                release(); setStatus(error is CancellationError ? "Preparation cancelled" : "Could not prepare speech · retry or choose another model")
            } else {
                owned?.cancel();retainRetirement(owned?.retirementCompletion(),issue:{[original=owned] in original?.resourceReturnIssue})
                if resource == nil { ready = false; preparing = false }
            }
            throw error
        }
    }
    private func requireCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard epoch == token else { throw CancellationError() }
        guard ioOutcomes.issue == nil else{throw VoiceProblem.message("Previous speech resources need recovery. Restart Voice before preparing again.")}
    }
    // A nested release during @Published.willSet must win over the outer
    // assignment. Serialize only presentation updates; no resource/grant is
    // inferred from text, and redundant nested values do not recurse forever.
    private func setStatus(_ value: String) {
        pendingStatus = value
        guard !publishingStatus else { return }
        publishingStatus = true
        defer { publishingStatus = false }
        while let next = pendingStatus {
            pendingStatus = nil
            if status != next { status = next }
        }
    }
    private func retainRetirement(_ completion:Task<Void,Never>?,issue:@escaping @MainActor ()->String?={nil}){
        guard let original=ioOutcomes.join(completion,issue:issue)else{return}
        let prior = retirement, id = UUID(); retirementID = id
        retirement = Task { [weak self] in
            await prior?.value; await original.value
            guard let self, self.retirementID == id else { return }
            self.retirement = nil; self.retirementID = nil; self.retiring = false
        }
        retiring = true
    }
    public func take(provider: VoiceASRProvider, locale: String, helper: URL,
                     update: @escaping (MeetingLiveUpdate) throws -> Void,
                     failure: @escaping (String) -> Void) -> MeetingLiveTranscriber? {
        guard !busy,ioOutcomes.issue == nil else{return nil}
        guard ready, identity == key(provider, locale, helper), let service = resource,
              service.transfer(update: update, failure: failure, dormant: false) else { release(); return nil }
        LocalModelProcess.claimIdle(epoch); epoch = UUID();let originalExpiry=expiry;expiry=nil;originalExpiry?.cancel();timerReturns.retain(originalExpiry)
        resource = nil; identity = nil; ready = false; setStatus("Prepared model used by Talk")
        return service
    }
    public func release() {
        LocalModelProcess.claimIdle(epoch); epoch = UUID()
        releaseOwnedResources()
    }
    private func releaseOwnedResources() {
        let originalExpiry=expiry;expiry=nil;originalExpiry?.cancel();timerReturns.retain(originalExpiry)
        let original = resource; resource = nil; identity = nil
        original?.cancel();retainRetirement(original?.retirementCompletion(),issue:{[original] in original?.resourceReturnIssue})
        ready = false; preparing = false
        setStatus("Prepared model released · microphone off")
    }
}
