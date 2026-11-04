import AppKit
import NookPluginSDK

/// Session-only native consent. The observed code identity comes from the
/// verified native FD; no renderer/descriptor/role Boolean supplies this decision.
@MainActor final class VoiceServiceApproval {
    private struct Pending {
        let token: UUID
        let request: UUID
        let context: VoiceClientContext
        let alert: NSAlert
        let parent: NSWindow
    }
    private var pending: Pending?
    func request(context: VoiceClientContext, request: UUID, capabilities: [String]) -> Bool {
        guard pending == nil, !context.closing else { return false }
        do { try context.native.revalidate() } catch { return false }
        let alert = NSAlert()
        alert.messageText = "Allow this app to use Nero Voice?"
        let scope = context.role == .moduleAdapter
            ? "Show the full Voice module, its settings and its local actions in this Nook session. Existing shared-action permissions still apply."
            : "Use only these local speech capabilities for this connection: " + capabilities.joined(separator: ", ") + "."
        alert.informativeText = context.native.peer.displayIdentifier + "\n\n" + scope + "\n\nThis does not start recording. Each speech or meeting action has its own controls and macOS permissions."
        // Safe default and an explicit session-only affirmative action.
        alert.addButton(withTitle: "Don't Allow")
        alert.addButton(withTitle: "Allow This Session")
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 110),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.title = "Connect to Nero Voice"; parent.center()
        let token = UUID()
        pending = Pending(token: token, request: request, context: context, alert: alert, parent: parent)
        parent.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: parent) { [weak self] response in
            Task { @MainActor in
                guard let self, let original = self.pending, original.token == token else { return }
                self.pending = nil; original.parent.orderOut(nil); original.parent.close()
                original.context.finishApproval(original.request, allowed: response == .alertSecondButtonReturn)
            }
        }
        return true
    }
    func cancel(context: VoiceClientContext) {
        guard let original = pending, original.context === context else { return }
        // Retire the exact prompt before callbacks. A late affirmative cannot
        // grant a detached/replaced context or consume a future prompt.
        pending = nil
        original.parent.endSheet(original.alert.window, returnCode: .abort)
        original.parent.orderOut(nil); original.parent.close()
    }
}
