import AppKit
import ApplicationServices
import VoiceEditing
import VoiceAudio
import ModuleCore

/// Disposable authored fixtures only. Never included in the plugin package.
@main @MainActor struct ReviewApp {
    static var retained: AnyObject?
    static func main() {
        let app = NSApplication.shared
        if let mode = Bundle.main.object(forInfoDictionaryKey: "NeroReviewAppearance") as? String { app.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua) }
        if CommandLine.arguments.contains("--ax-probe") || Bundle.main.bundleIdentifier == "cafe.nero.review.selection-probe" {
            app.setActivationPolicy(.accessory)
            Task {
                var report: [String: Any] = ["trusted": AXIsProcessTrusted(), "fixture": true]
                do {
                    guard AXIsProcessTrusted() else { throw SelectionProblem.permission }
                    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "cafe.nero.review.selection-editor" else { throw SelectionProblem.changed }
                    let editor = AXSelectionEditor(), capture = try editor.capture()
                    guard capture.value == "Before 🧊\nmake this clear after", capture.text == "make this clear" else { throw SelectionProblem.changed }
                    let plan = try await editor.replace(capture, with: "Make this clearer")
                    report["replace"] = plan.after == "Before 🧊\nMake this clearer after"
                    try await editor.undo(capture, edit: plan); report["undo"] = true
                    // Same capture after a successful Undo, then test stale rejection.
                    let changed = try editor.capture()
                    let second = try await editor.replace(changed, with: "new selection")
                    do { _ = try await editor.replace(changed, with: "should not write"); report["staleRejected"] = false }
                    catch { report["staleRejected"] = true }
                    try await editor.undo(changed, edit: second)
                    editor.forget(); report["success"] = true
                } catch { report["success"] = false; report["error"] = error.localizedDescription }
                let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                if let path = Bundle.main.object(forInfoDictionaryKey: "NeroReviewReceipt") as? String { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
                print(String(data: data, encoding: .utf8)!)
                exit(report["success"] as? Bool == true ? 0 : 2)
            }
        } else if CommandLine.arguments.contains("--model-check") {
            app.setActivationPolicy(.accessory)
            Task {
                let passage = "We might send 3 drafts by Friday, but we have not agreed to that yet."
                do {
                    let reply = try await SelectionTransformer.transform(passage, operation: .formal)
                    print(String(data: try! JSONSerialization.data(withJSONObject: ["input": passage, "output": reply, "local": true], options: [.sortedKeys]), encoding: .utf8)!)
                    exit(0)
                } catch { print(error.localizedDescription); exit(2) }
            }
        } else if Bundle.main.bundleIdentifier == "cafe.nero.review.selection-editor" {
            app.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: .init(x: 180, y: 180, width: 620, height: 340), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Nero Rewrite · Disposable Editor"
            let scroll = NSScrollView(frame: window.contentView!.bounds); scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds); text.isRichText = false; text.font = .systemFont(ofSize: 22)
            text.string = "Before 🧊\nmake this clear after"; text.setSelectedRange(NSRange(location: 10, length: 15))
            scroll.documentView = text; window.contentView = scroll; window.makeFirstResponder(text)
            window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); retained = window
        } else {
            app.setActivationPolicy(.accessory)
            let editor = FixtureEditor()
            let model = SelectionRewrite(editor: editor) { _, _ in "We could share three drafts by Friday; this has not yet been agreed." }
            let window = SelectionRewriteWindow(model: model)
            model.changed = { if !model.active { window.hide(); NSApp.terminate(nil) } }
            try! model.begin(); window.show(); retained = window
        }
        app.run()
    }
}

@MainActor private final class FixtureEditor: SelectionEditor {
    let source: SelectionCapture = {
        let text = "We might share 3 drafts by Friday, but have not agreed yet."
        return try! SelectionCapture(app: "Offline fixture · scripted preview", value: text, range: NSRange(text.startIndex..., in: text))
    }()
    func capture() throws -> SelectionCapture { source }
    func replace(_ capture: SelectionCapture, with text: String) async throws -> DictationEdit { throw SelectionProblem.unsupported }
    func undo(_ capture: SelectionCapture, edit: DictationEdit) async throws { throw SelectionProblem.unsupported }
    func forget() {}
}
