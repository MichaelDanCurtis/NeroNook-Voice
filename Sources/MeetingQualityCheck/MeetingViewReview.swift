import AppKit
import WebKit
import NookPluginSDK

/// Authored, nonpersistent visual fixture. No VoiceModel, recordings,
/// preferences, account, microphone, plugin grant or real meeting store.
@MainActor final class MeetingViewReview: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    private let resources: URL, output: URL
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    private let status = NSTextField(labelWithString: "Authored local meeting · no audio or account")
    private let web: WKWebView
    init(resources: URL, output: URL) {
        self.resources = resources; self.output = output
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(); configuration.userContentController.add(self, name: "review")
    }
    static func run(resources: URL, output: URL) throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let review = MeetingViewReview(resources: resources, output: output)
        app.delegate = review; try review.show(); app.run()
        review.web.configuration.userContentController.removeScriptMessageHandler(forName: "review")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    private func show() throws {
        window.title = "Nero Voice · Meeting task review"; window.isReleasedWhenClosed = false
        let bar = NSStackView(); bar.orientation = .horizontal; bar.spacing = 10
        for (label, action) in [("Dark", #selector(dark)), ("Light", #selector(light)), ("Compact", #selector(compact))] {
            bar.addArrangedSubview(NSButton(title: label, target: self, action: action))
        }
        bar.addArrangedSubview(status)
        let root = NSStackView(views: [bar, web]); root.orientation = .vertical; root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        window.contentView = root; web.translatesAutoresizingMaskIntoConstraints = false
        web.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16).isActive = true
        try load(.dark); window.center(); window.makeKeyAndOrderFront(nil)
    }
    @objc private func dark() { try? load(.dark) }
    @objc private func light() { try? load(.light) }
    @objc private func compact() { window.setContentSize(NSSize(width: 820, height: 550)) }
    private func load(_ scheme: PluginColorScheme) throws {
        let action1 = ["id":"00000000-0000-4000-8000-000000000001", "task":"Maya will review the results on Friday.", "quote":"I will review the results on Friday.", "start":"24", "track":"mic"]
        let action2 = ["id":"00000000-0000-4000-8000-000000000002", "task":"Check the invoice tomorrow.", "quote":"I will check the invoice tomorrow.", "start":"32", "track":"system"]
        let state: [String: Any] = ["selected":"authored-review", "title":"Planning review", "hasTranscript":true, "hasAudio":false, "duration":45, "notebookPage":"notes", "library":"[]", "sources":"[]", "transcript":"[]", "speakers":"{}", "summaryAvailable":true, "summary":"[00:08] No launch date has been agreed.", "decisions":"", "actionItems":"[00:24] Maya will review the results on Friday.\n[00:32] Check the invoice tomorrow.", "actionCards":[action1, action2]]
        let seed = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        let theme = try PluginThemeWeb.bootstrap(.init(mode: scheme == .dark ? .dark : .light, scheme: scheme), documentID: "authored-meeting-review")
        let bridge = "window.nero={onState:f=>f(\(seed)),emit:(name,values)=>{window.webkit.messageHandlers.review.postMessage({name,values});return Promise.resolve();}};"
        let css = try String(contentsOf: resources.appendingPathComponent("meeting.css"), encoding: .utf8)
        let js = try String(contentsOf: resources.appendingPathComponent("meeting.js"), encoding: .utf8)
        var html = try String(contentsOf: resources.appendingPathComponent("index.html"), encoding: .utf8)
        html = html.replacingOccurrences(of: "<link rel=\"stylesheet\" href=\"meeting.css\">", with: "<style>\(css)</style>")
        html = html.replacingOccurrences(of: "<script src=\"meeting.js\"></script>", with: "<script>\(theme)\n\(bridge)\n\(js)</script>")
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        web.loadHTMLString(html, baseURL: nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any] else { return }
        status.stringValue = "Fixture event · " + (value["name"] as? String ?? "")
        if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: output.appendingPathComponent("native-event.json"), options: .atomic)
        }
    }
}
