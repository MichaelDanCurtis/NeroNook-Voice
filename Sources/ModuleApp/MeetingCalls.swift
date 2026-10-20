import AppKit
import Foundation
import ModuleCore
import VoiceAudio

extension MeetingModel {
    func startCallDetection() {
        guard !CommandLine.arguments.contains("--protocol-test"), Bundle.main.object(forInfoDictionaryKey: "NeroLiveFixtureAudio") == nil,
              callOffersEnabled, !callDetectionSuspended, callDetectionTask == nil else { return }
        callDetectionTask = Task { [weak self] in
            while !Task.isCancelled {
                let signal = await MeetingCallObservation.sample()
                guard !Task.isCancelled, let self, self.callOffersEnabled, !self.callDetectionSuspended else { return }
                self.receiveCallObservation(signal)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func stopCallDetection() {
        callDetectionTask?.cancel(); callDetectionTask = nil
        callState.reset(); callOffer = nil; callPanel.hide()
    }
    func receiveCallObservation(_ signal: MeetingCallSignal?) {
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
        guard callOffersEnabled, !callDetectionSuspended, !occupied, canStart?() != false,
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
        callOffersEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "teamsMeetingOffers")
        stopCallDetection(); if enabled { startCallDetection() }
    }
}
