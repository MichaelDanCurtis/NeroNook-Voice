import AppKit
import SwiftUI
import NookPluginSDK
import ModuleCore
import VoiceAudio

private final class MeetingOfferPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor final class MeetingCallOfferPanel {
    private var panel: MeetingOfferPanel?
    private var expiry: Task<Void, Never>?
    private var callbacks: VoiceAudioCallbackAdmission?
    private var generation = UUID()
    private var closed = false
    private var originals: [UUID: Task<Void, Never>] = [:]
    private var originalRetirement: Task<Bool, Never>?
    private let appearanceStore: PluginAppearanceStore?
    // Read-only identity for the actual injected store; retirement remains
    // limited to this panel and never retires the borrowed store.
    var presentationAppearanceStore: PluginAppearanceStore? { appearanceStore }
    private let presentationAllowed: @MainActor () -> Bool

    init(appearanceStore: PluginAppearanceStore? = nil,
         presentationAllowed: @escaping @MainActor () -> Bool = { true }) {
        self.appearanceStore = appearanceStore
        self.presentationAllowed = presentationAllowed
    }
    private func permits(_ token: UUID) -> Bool {
        guard !closed, generation == token else { return false }
        let allowed = presentationAllowed()
        return allowed && !closed && generation == token
    }
    private func retain(_ task: Task<Void, Never>) {
        let id = UUID(); originals[id] = task
        Task { @MainActor [weak self] in await task.value; self?.originals[id] = nil }
    }
    func show(_ offer: MeetingCallOffer, start: @escaping () -> Void, dismiss: @escaping () -> Void) {
        let entry = generation
        guard permits(entry) else { return }
        hide()
        let afterHide = generation
        guard permits(afterHide) else { return }
        let token = UUID(); generation = token
        let admission = VoiceAudioCallbackAdmission(); callbacks = admission
        guard let opening = admission.enter() else { return }
        defer {
            opening.finish()
            if generation == token && self.panel == nil { hide() }
        }
        guard permits(token) else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard permits(token) else { return }
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(500, visible.width - 24), height = min(176, visible.height - 24)
        let frame = NSRect(x: visible.midX - width/2, y: visible.maxY - height - 8, width: width, height: height)
        guard permits(token) else { return }
        let panel = MeetingOfferPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        var transferred = false
        defer { if !transferred { panel.orderOut(nil); panel.contentView = nil } }
        guard permits(token) else { return }
        panel.isOpaque = false
        guard permits(token) else { return }
        panel.backgroundColor = .clear
        guard permits(token) else { return }
        panel.hasShadow = true
        guard permits(token) else { return }
        panel.level = .floating
        guard permits(token) else { return }
        panel.hidesOnDeactivate = false
        guard permits(token) else { return }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard permits(token) else { return }
        panel.title = "Nero Voice · Teams meeting notes"
        let admittedStart = { [weak self] in
            guard let entered = admission.enter() else { return }; defer { entered.finish() }
            guard let self, self.permits(token) else { return }; start()
        }
        let admittedDismiss = { [weak self] in
            guard let entered = admission.enter() else { return }; defer { entered.finish() }
            guard let self, self.permits(token) else { return }; dismiss()
        }
        guard permits(token) else { return }
        // Legacy resolves .shared only at an actually admitted presentation.
        let store = appearanceStore ?? .shared
        guard permits(token) else { return }
        let host = NSHostingView(rootView: MeetingCallOfferView(offer: offer, start: admittedStart, dismiss: admittedDismiss).frame(width: width, height: height).pluginThemed(store: store, background: false))
        guard permits(token) else { return }
        host.sizingOptions = []
        guard permits(token) else { return }
        panel.contentView = host
        guard permits(token) else { return }
        panel.setFrame(frame, display: false)
        guard permits(token) else { return }
        self.panel = panel; transferred = true
        guard permits(token), self.panel === panel else { hideIfOriginal(panel, token: token); return }
        panel.orderFrontRegardless()
        guard permits(token), self.panel === panel else { hideIfOriginal(panel, token: token); return }
        expiry = Task { try? await Task.sleep(for: .seconds(35)); guard !Task.isCancelled else { return }; admittedDismiss() }
    }
    private func hideIfOriginal(_ candidate: MeetingOfferPanel, token: UUID) {
        if generation == token, panel === candidate { hide() }
        // A native orderFront call can return after reentrant Stop already hid
        // this same original. Close it again before the opening lease returns;
        // each show creates a distinct panel, so no replacement is affected.
        candidate.orderOut(nil); candidate.contentView = nil
    }
    func hide() {
        generation = UUID()
        let originalExpiry = expiry, admission = callbacks, originalPanel = panel
        expiry = nil; callbacks = nil; panel = nil
        guard originalExpiry != nil || admission != nil || originalPanel != nil else { return }
        admission?.seal()
        let closeFence = VoiceAudioCallbackAdmission()
        let entered = closeFence.enter()!
        closeFence.seal()
        // Reserve this exact teardown before cancellation/AppKit can reenter.
        let original = Task { @MainActor in
            await closeFence.waitForReturn()
            await originalExpiry?.value; await admission?.waitForReturn(); _ = originalPanel
        }
        retain(original)
        originalExpiry?.cancel()
        originalPanel?.orderOut(nil); originalPanel?.contentView = nil
        admission?.nativeStopReturned()
        closeFence.nativeStopReturned(); entered.finish()
    }
    /// Establish the original receipt before native close can synchronously
    /// reenter. The fence holds it until this exact hide call has returned.
    func sealPresentationForRetirement() -> Task<Bool, Never> {
        if let originalRetirement { return originalRetirement }
        closed = true
        let fence = VoiceAudioCallbackAdmission()
        let entered = fence.enter()!
        fence.seal()
        let original = Task { @MainActor [self] in
            await fence.waitForReturn()
            while !originals.isEmpty {
                let captured = Array(originals.values)
                for task in captured { await task.value }
                await Task.yield()
            }
            return true
        }
        originalRetirement = original
        hide()
        fence.nativeStopReturned(); entered.finish()
        return original
    }
    func retire() async { _ = await sealPresentationForRetirement().value }
}
private struct MeetingCallOfferView: View {
    @Environment(\.pluginAppearance) private var appearance
    let offer: MeetingCallOffer
    let start: () -> Void
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.wave.2.fill").font(.title3).foregroundStyle(Color(pluginHex: appearance.palette.accent))
                VStack(alignment: .leading, spacing: 3) {
                    Text(offer.signal.evidence == .callControls ? "Teams call detected" : "Teams microphone in use").font(.headline)
                    Text("Start meeting notes in Nero Voice?").font(.subheadline)
                }
                Spacer()
            }
            Text(offer.signal.browserWide ? "Records your microphone and this browser’s audio, including other tabs. Audio stays on this Mac." : "Records your microphone and Teams audio on this Mac. Separate speakers can be labelled in both sources.")
                .font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("NERO VOICE").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(Color(pluginHex: appearance.palette.accent))
                Spacer()
                Button("Not now", action: dismiss).buttonStyle(.bordered)
                Button("Start notes", action: start).pluginPrimaryAction()
            }
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(pluginHex: appearance.palette.surface), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.15)))
    }
}
