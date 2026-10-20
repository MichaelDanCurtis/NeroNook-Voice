import AppKit
import SwiftUI
import NookPluginSDK

private final class DictationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class DictationOverlay {
    private var panel: NSPanel?
    func show(model: VoiceModel) {
        if panel == nil {
            let p = DictationPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 154), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating; p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: DictationOverlayView(model: model).pluginThemed(background:false))
            panel = p
        }
        guard let panel else { return }
        if !panel.isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let rect = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: rect.midX - 210, y: rect.minY + 42))
            }
        }
        panel.orderFrontRegardless() // Preserve the destination app's keyboard focus.
    }
    func hide() { panel?.orderOut(nil) }
}

private struct DictationOverlayView: View {
    @Environment(\.pluginAppearance) private var appearance
    @ObservedObject var model: VoiceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: model.session.phase == .listening ? "waveform" : "mic.fill").foregroundStyle(Color(pluginHex: appearance.palette.accent))
                Text(model.session.recording ? "Dictating to \(model.targetName)" : "Nero Voice").font(.callout.bold())
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.dismissOverlay() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss dictation")
            }
            Text(model.status).font(.caption).pluginSecondaryText().lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Text(model.overlayText ?? (model.session.transcript.isEmpty ? "Your words will appear here" : model.session.transcript))
                .font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if model.session.recording || model.inserting {
                    Button("Stop") { model.stopRecording() }.disabled(!model.session.recording || model.session.phase == .finishing)
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Open Voice") { model.dismissOverlay(); model.reveal?() }
                }
                Spacer()
                Text("ON DEVICE").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color(pluginHex: appearance.palette.accent))
            }.font(.caption)
        }.padding(16).frame(width: 420, height: 154).background(Color(pluginHex: appearance.palette.surface), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.12)))
    }
}
