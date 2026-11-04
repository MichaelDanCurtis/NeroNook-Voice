import AppKit
import Foundation
import ModuleCore
import VoiceAudio

// The visible slot can be cleared immediately, but the original sampler is
// retained until its actual detached/native observation call has returned.
@MainActor final class MeetingCallDetectionOwner {
    private(set) var current: Task<Void, Never>?
    private(set) var sealed = false
    private var originals: [UUID: Task<Void, Never>] = [:]
    func install(_ task: Task<Void, Never>) -> Bool {
        guard !sealed, current == nil else {
            let id = UUID(); originals[id] = task; task.cancel()
            Task { @MainActor [weak self] in await task.value; self?.originals[id] = nil }
            return false
        }
        current = task; return true
    }
    func stop() {
        let original = current; current = nil
        guard let original else { return }
        let id = UUID(); originals[id] = original; original.cancel()
        Task { @MainActor [weak self] in await original.value; self?.originals[id] = nil }
    }
    func seal() { sealed = true; stop() }
    func waitForReturn() async {
        while !originals.isEmpty {
            let captured = Array(originals.values)
            for original in captured { await original.value }
            await Task.yield()
        }
    }
}

extension MeetingModel {
    func startCallDetection() {
        guard allowProductEffect(.observation) else{return}
        guard !nativeClosing, !CommandLine.arguments.contains("--protocol-test"), Bundle.main.object(forInfoDictionaryKey: "NeroLiveFixtureAudio") == nil,
              callOffersEnabled, !callDetectionSuspended, !callDetectionOwner.sealed, callDetectionOwner.current == nil else { return }
        let original = Task { [weak self] in
            while !Task.isCancelled {
                let signal = await MeetingCallObservation.sample()
                guard !Task.isCancelled, let self, self.callOffersEnabled, !self.callDetectionSuspended else { return }
                self.receiveCallObservation(signal)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        _ = callDetectionOwner.install(original)
    }
    func stopCallDetection() {
        callDetectionOwner.stop()
        callState.reset(); callOffer = nil; callPanel.hide()
    }
    func receiveCallObservation(_ signal: MeetingCallSignal?) {
        guard allowProductEffect(.observation) else{return}
        guard !nativeClosing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let offer = callState.observe(signal, at: now, available: !occupied && canStart?() != false)
        if let shown = callOffer, !callState.isFresh(shown.id, at: now) || occupied || canStart?() == false {
            callOffer = nil; callPanel.hide()
        }
        guard let offer else { return }
        callOffer = offer
        callPanel.show(offer, start: { [weak self] in self?.acceptDetectedCall(offer.id) }, dismiss: { [weak self] in self?.dismissDetectedCall(offer.id) })
        changed?()
    }
    func dismissDetectedCall(_ id: UUID) {
        callState.dismiss(id)
        if callOffer?.id == id { callOffer = nil; callPanel.hide(); changed?() }
    }
    func acceptDetectedCall(_ id: UUID) {
        guard allowProductEffect(.capture) else{return}
        guard !nativeClosing, callOffersEnabled, !callDetectionSuspended, !occupied, canStart?() != false,
              let offer = callOffer, offer.id == id, callState.isFresh(id, at: ProcessInfo.processInfo.systemUptime) else {
            status = "That call offer is no longer available. Open Meetings to choose sources."; dismissDetectedCall(id); return
        }
        refreshSources()
        guard sources.contains(where: { $0.id == offer.signal.source }) else {
            status = "The call audio source is unavailable. Nothing was recorded. Open Meetings and refresh sources."; dismissDetectedCall(id); return
        }
        dismissDetectedCall(id)
        // A newly detected call must not inherit the previous recording's
        // calendar link or private notebook. Saved meetings remain untouched.
        calendarLink = nil; calendarStatus = ""; calendarPickerOpen = false
        start(title: "Teams meeting · " + Date().formatted(date: .abbreviated, time: .shortened), mic: true, source: offer.signal.source, live: liveEnabled)
    }
    func chooseCallOffers(_ enabled: Bool) {
        guard !nativeClosing else { return }
        callOffersEnabled = enabled; storeMeetingPreference(enabled, forKey: "teamsMeetingOffers")
        stopCallDetection(); if enabled { startCallDetection() }
    }
}
