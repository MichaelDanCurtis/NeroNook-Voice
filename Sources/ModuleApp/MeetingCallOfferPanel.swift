import AppKit
import SwiftUI
import NookPluginSDK
import ModuleCore

private final class MeetingOfferPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor final class MeetingCallOfferPanel {
    private var panel: MeetingOfferPanel?
    private var expiry: Task<Void, Never>?
    func show(_ offer: MeetingCallOffer, start: @escaping () -> Void, dismiss: @escaping () -> Void) {
        hide()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(500, visible.width - 24), height = min(176, visible.height - 24)
        let frame = NSRect(x: visible.midX - width/2, y: visible.maxY - height - 8, width: width, height: height)
        let panel = MeetingOfferPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "Nero Voice · Teams meeting notes"
        let host = NSHostingView(rootView: MeetingCallOfferView(offer: offer, start: start, dismiss: dismiss).frame(width: width, height: height).pluginThemed(background:false))
        host.sizingOptions = []
        panel.contentView = host; panel.setFrame(frame, display: false)
        self.panel = panel; panel.orderFrontRegardless()
        expiry = Task { try? await Task.sleep(for: .seconds(35)); guard !Task.isCancelled else { return }; dismiss() }
    }
    func hide() { expiry?.cancel(); expiry = nil; panel?.orderOut(nil); panel?.contentView = nil; panel = nil }
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
