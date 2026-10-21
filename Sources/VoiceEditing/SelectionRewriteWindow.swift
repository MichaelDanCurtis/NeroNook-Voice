import AppKit
import SwiftUI
import ModuleCore
import NookPluginSDK

@MainActor public final class SelectionRewriteWindow: NSObject, NSWindowDelegate {
    private let model: SelectionRewrite
    private var window: NSWindow?
    public init(model: SelectionRewrite) { self.model = model }
    public func show() {
        if window == nil {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 620, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Nero Voice · Rewrite selection"
            window.isReleasedWhenClosed = false; window.delegate = self
            window.minSize = .init(width: 480, height: 480)
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: SelectionRewriteView(model: model).pluginThemed())
            self.window = window
        }
        guard let window else { return }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            window.setFrameOrigin(.init(x: max(frame.minX, frame.midX - window.frame.width / 2), y: max(frame.minY, frame.midY - window.frame.height / 2)))
        }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    public func hide() { window?.orderOut(nil) }
    public func windowWillClose(_ notification: Notification) { model.close(returnToEditor: true) }
}

public struct SelectionRewriteView: View {
    @ObservedObject private var model: SelectionRewrite
    public init(model: SelectionRewrite) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Rewrite selection", systemImage: "pencil.and.outline").font(.title2.bold())
                Spacer()
                Text("On this Mac").font(.caption).pluginSecondaryText()
            }
            Text(model.capture.map { "Selected in \($0.app)" } ?? "Select text in another app to begin.").font(.subheadline).pluginSecondaryText()
            Text("Original").font(.caption.bold())
            ScrollView { Text(model.capture?.text ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                .frame(minHeight: 60, maxHeight: 110).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Picker("Change", selection: $model.operation) {
                    ForEach(SelectionTransformation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().accessibilityLabel("Text transformation")
                Button("Generate preview") { model.transform() }
                if model.phase == .generating { ProgressView().controlSize(.small) }
            }.disabled(model.phase != .reviewing)
            Text("Preview · editable").font(.caption.bold())
            TextEditor(text: $model.result).font(.body).scrollContentBackground(.hidden).padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .frame(minHeight: 110).disabled(model.phase != .reviewing).accessibilityLabel("Replacement preview")
            Text(model.status).font(.caption).pluginSecondaryText().fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("rewriteStatus")
            HStack {
                Button(model.phase == .applied || model.phase == .undone ? "Done" : "Cancel") { model.close(returnToEditor: true) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Copy result") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.result, forType: .string) }.disabled(model.result.isEmpty || model.working)
                if model.canUndo { Button("Undo replacement") { model.undo() } }
                else { Button("Replace selection") { model.apply() }.disabled(!model.canApply).keyboardShortcut(.return, modifiers: .command) }
            }
        }.padding(24).frame(minWidth: 430, minHeight: 425)
    }
}
