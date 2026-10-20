import Foundation
import Combine
import ModuleCore

/// One explicit, short-lived preparation. No audio engine or capture APIs.
/// The warmed recognizer is consumed once; used recognition is never recycled.
@MainActor public final class SpeechPreloader: ObservableObject {
    @Published public private(set) var status = "Prepare Talk without recording"
    @Published public private(set) var ready = false
    @Published public private(set) var preparing = false
    private var resource: MeetingLiveTranscriber?
    private var identity: String?
    private var epoch = UUID()
    private var expiry: Task<Void, Never>?
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
        release(); let token = UUID(); epoch = token
        let service = MeetingLiveTranscriber(); resource = service
        identity = key(provider, locale, helper); preparing = true; status = "Loading selected speech model · microphone off"
        do {
            try await prepareWorker(service, provider, locale, helper)
            try Task.checkCancellation()
            guard epoch == token else { throw CancellationError() }
            guard service.transfer(update: { _ in throw VoiceProblem.message("Prepared speech returned words without audio") }, failure: { [weak self] _ in
                guard let self, self.epoch == token else { return }; self.release(); self.status = "Preparation ended · press Prepare to retry"
            }, dormant: true) else { throw VoiceProblem.message("The speech model could not stay ready") }
            preparing = false; ready = true; status = "Talk ready · microphone off · releases after 2 minutes"
            LocalModelProcess.reserveIdle(token) { [weak self] in
                guard let self, self.epoch == token else { return }; self.release()
            }
            expiry = Task { [weak self] in
                try? await Task.sleep(for: self?.hold ?? .seconds(120))
                guard !Task.isCancelled, let self, self.epoch == token else { return }
                self.release(); self.status = "Prepared model released after idle time"
            }
        } catch {
            service.cancel()
            if epoch == token { release(); status = error is CancellationError ? "Preparation cancelled" : "Could not prepare speech · retry or choose another model" }
            throw error
        }
    }
    public func take(provider: VoiceASRProvider, locale: String, helper: URL,
                     update: @escaping (MeetingLiveUpdate) throws -> Void,
                     failure: @escaping (String) -> Void) -> MeetingLiveTranscriber? {
        guard ready, identity == key(provider, locale, helper), let service = resource,
              service.transfer(update: update, failure: failure, dormant: false) else { release(); return nil }
        LocalModelProcess.claimIdle(epoch); epoch = UUID(); expiry?.cancel(); expiry = nil
        resource = nil; identity = nil; ready = false; status = "Prepared model used by Talk"
        return service
    }
    public func release() {
        LocalModelProcess.claimIdle(epoch); epoch = UUID(); expiry?.cancel(); expiry = nil
        resource?.cancel(); resource = nil; identity = nil; ready = false; preparing = false
        status = "Prepared model released · microphone off"
    }
}
