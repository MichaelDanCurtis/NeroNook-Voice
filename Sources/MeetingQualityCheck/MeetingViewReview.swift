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
        let action1: [String: Any] = ["id":"original-task", "task":"prepare the launch checklist", "owner":"Omar", "deadline":"Wednesday", "status":"active",
            "sources":[["id":"original-task", "quote":"I will prepare the launch checklist by Monday.", "start":0, "track":"mic"],
                       ["id":"takeover-source", "quote":"I will take over the launch checklist from Lena and finish it Wednesday instead.", "start":10, "track":"system"]]]
        let action2: [String: Any] = ["id":"cancelled-task", "task":"email the sales report", "status":"cancelled",
            "sources":[["id":"cancelled-task", "quote":"I will email the sales report by Thursday.", "start":24, "track":"mic"],
                       ["id":"cancellation-source", "quote":"Cancel my promise to email the sales report. We will not send that report.", "start":32, "track":"mic"]]]
        let state: [String: Any] = ["selected":"authored-review", "title":"Planning review", "hasTranscript":true, "hasAudio":false, "duration":45, "notebookPage":"notes", "library":"[]", "sources":"[]", "transcript":"[]", "speakers":"{}", "summaryAvailable":true, "summary":"[00:10] Omar takes over the launch checklist; Wednesday replaces Monday.", "decisions":"", "actionItems":"[00:00] Omar: prepare the launch checklist · Due Wednesday", "actionCards":[action1, action2]]
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
