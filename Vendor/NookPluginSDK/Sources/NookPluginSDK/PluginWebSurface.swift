import SwiftUI
import WebKit

/// Same custom view renderer for a host stage or a plugin-owned standalone window.
public struct PluginWebSurface: NSViewRepresentable {
    public let root: URL
    public let panelID: String
    public let definition: PluginCustomView
    public let onResource: ((PluginViewResourceRequest) async throws -> PluginViewResourceResult)?
    public let onEvent: (PluginViewEvent) throws -> Void
    public init(root: URL, panelID: String, definition: PluginCustomView, onResource: ((PluginViewResourceRequest) async throws -> PluginViewResourceResult)? = nil, onEvent: @escaping (PluginViewEvent) throws -> Void) {
        self.root = root; self.panelID = panelID; self.definition = definition; self.onEvent = onEvent; self.onResource = onResource
    }
    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: PluginViewResources.scheme)
        configuration.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "neroView")
        configuration.userContentController.addUserScript(.init(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator; web.uiDelegate = context.coordinator
        web.underPageBackgroundColor = .clear
        context.coordinator.load(web)
        return web
    }
    public func updateNSView(_ web: WKWebView, context: Context) {
        let previous = context.coordinator.owner
        context.coordinator.owner = self
        if previous.root != root || previous.panelID != panelID || previous.definition.entry != definition.entry || previous.definition.revision != definition.revision || previous.definition.frames != definition.frames {
            context.coordinator.load(web)
        } else if previous.definition.state != definition.state { context.coordinator.update(web) }
    }
    public static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.active = false; coordinator.cancelResources(); web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        web.navigationDelegate = nil; web.uiDelegate = nil
    }
    private static let bridge = """
    (() => {
      let state = Object.freeze({}); const listeners = new Set();
      Object.defineProperty(window, '__neroReceive', { value: value => { state = Object.freeze(value); for (const f of listeners) { try { f(state); } catch (_) {} } } });
      Object.defineProperty(window, 'nero', { value: Object.freeze({
        get state() { return state; },
        onState(callback) { listeners.add(callback); callback(state); return () => listeners.delete(callback); },
        emit(name, values = {}) { return window.webkit.messageHandlers.neroView.postMessage({name, values}); }
      }) });
    })();
    """
    @MainActor public final class Coordinator: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
        var owner: PluginWebSurface
        var active = true
        private var loaded = false
        private var eventsAt = Date.distantPast
        private var eventCount = 0
        private var assetRequests = 0
        private var assetBytes = 0
        private let resourceSlots = ViewResourceSlots()
        private var resourceTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var resourceWindow = Date()
        private var resourceCount = 0
        private var resourceBytes = 0
        func cancelResources() { let tasks = resourceTasks.values; resourceTasks.removeAll(); for task in tasks { task.cancel() } }
        init(_ owner: PluginWebSurface) { self.owner = owner }
        func load(_ web: WKWebView) {
            cancelResources(); loaded = false; active = true; assetRequests = 0; assetBytes = 0
            do {
                try owner.definition.validate()
                _ = try PluginViewResources.file(owner.definition.entry, root: owner.root)
                web.load(URLRequest(url: URL(string: "\(PluginViewResources.scheme)://surface/\(owner.definition.entry)")!))
            } catch { showError(web) }
        }
        private func showError(_ web: WKWebView) {
            loaded = false
            web.loadHTMLString("<html><body style='background:#19191f;color:#ddd;font:14px system-ui;padding:24px'>This plugin view could not load. Open its settings or restart the module.</body></html>", baseURL: nil)
        }
        func update(_ web: WKWebView) {
            guard loaded, active, let data = try? JSONEncoder().encode(owner.definition.state), let values = try? JSONSerialization.jsonObject(with: data) else { return }
            Task { @MainActor in _ = try? await web.callAsyncJavaScript("window.__neroReceive(state)", arguments: ["state": values], in: nil, contentWorld: .page) }
        }
        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = webView.url?.scheme == PluginViewResources.scheme; update(webView) }
        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { showError(webView) }
        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if webView.url?.scheme != "about" { showError(webView) } }
        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            // Only this document (and fragment links) can navigate. Never open a browser automatically.
            let allowed = !navigationAction.shouldPerformDownload && url?.scheme == PluginViewResources.scheme && url?.host == "surface" && url?.path == "/" + owner.definition.entry && navigationAction.targetFrame?.isMainFrame == true
            let embedded = !navigationAction.shouldPerformDownload && navigationAction.targetFrame?.isMainFrame == false && url.map { target in (owner.definition.frames ?? []).contains { $0.allows(target) } } == true
            decisionHandler(allowed || embedded || url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
        public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
        public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) { completionHandler(nil) }
        public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
            do {
                guard active, let url = urlSchemeTask.request.url, url.scheme == PluginViewResources.scheme, url.host == "surface", url.user == nil, url.password == nil,
                      urlSchemeTask.request.httpMethod == "GET" else { throw ModuleProblem("Invalid resource request.") }
                guard url.query == nil, url.fragment == nil, url.port == nil else { throw ModuleProblem("Invalid resource URL.") }
                if url.path.hasPrefix("/_plugin/") {
                    let request = PluginViewResourceRequest(panelID: owner.panelID, revision: owner.definition.revision, path: String(url.path.dropFirst(9)))
                    try owner.definition.validate(request)
                    guard let provider = owner.onResource else { throw ModuleProblem("Plugin resources are unavailable.") }
                    if Date().timeIntervalSince(resourceWindow) >= 60 { resourceWindow = Date(); resourceCount = 0; resourceBytes = 0 }
                    guard resourceTasks.count < 512, resourceCount < 1200, resourceBytes < 32 * 1024 * 1024 else { throw ModuleProblem("Resource budget exceeded.") }
                    resourceCount += 1
                    let key = ObjectIdentifier(urlSchemeTask)
                    resourceTasks[key] = Task { @MainActor [weak self] in
                        guard let self else { return }
                        do {
                            try await self.resourceSlots.acquire(key)
                            defer { self.resourceSlots.release() }
                            try Task.checkCancellation()
                            let result = try await provider(request)
                            guard self.active, self.resourceTasks[key] != nil else { return }
                            try self.owner.definition.validate(request); try result.validate()
                            guard result.id == request.id, let bytes = result.data, let mime = result.mime else { throw ModuleProblem("Resource unavailable.") }
                            self.resourceBytes += bytes.count
                            guard self.resourceBytes <= 32 * 1024 * 1024 else { throw ModuleProblem("Resource budget exceeded.") }
                            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store"])!
                            self.resourceTasks[key] = nil
                            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(bytes); urlSchemeTask.didFinish()
                        } catch {
                            guard self.active, self.resourceTasks.removeValue(forKey: key) != nil else { return }
                            urlSchemeTask.didFailWithError(ModuleProblem("Plugin imagery unavailable."))
                        }
                    }
                    return
                }
                guard assetRequests < 512, assetBytes < 32 * 1024 * 1024 else { throw ModuleProblem("View resource budget exceeded.") }; assetRequests += 1
                let file = try PluginViewResources.file(String(url.path.dropFirst()), root: owner.root)
                let data = try Data(contentsOf: file)
                guard data.count <= 2 * 1024 * 1024 else { throw ModuleProblem("Asset exceeded its limit.") }
                assetBytes += data.count
                guard assetBytes <= 32 * 1024 * 1024 else { throw ModuleProblem("View resource budget exceeded.") }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": PluginViewResources.mime(file.pathExtension)! + (file.pathExtension == "html" ? "; charset=utf-8" : ""),
                    "Content-Security-Policy": "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'none'; frame-src \((owner.definition.frames ?? []).isEmpty ? "'none'" : (owner.definition.frames ?? []).map(\.origin).joined(separator: " ")); object-src 'none'; base-uri 'none'; form-action 'none'; worker-src 'none'",
                    "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store"
                ])!
                urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch { urlSchemeTask.didFailWithError(ModuleProblem("Plugin asset unavailable.")) }
        }
        public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { resourceTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel() }
        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            do {
                guard active, loaded, message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == PluginViewResources.scheme,
                      message.frameInfo.request.url?.host == "surface", let body = message.body as? [String: Any],
                      Set(body.keys) == Set(["name", "values"]), let name = body["name"] as? String,
                      let values = body["values"] as? [String: Any], values.count <= 16,
                      JSONSerialization.isValidJSONObject(values) else { throw ModuleProblem("Invalid view event.") }
                if Date().timeIntervalSince(eventsAt) >= 1 { eventsAt = Date(); eventCount = 0 }
                guard eventCount < 30 else { throw ModuleProblem("View event rate exceeded.") }; eventCount += 1
                let data = try JSONSerialization.data(withJSONObject: values)
                guard data.count <= 32768 else { throw ModuleProblem("View event is too large.") }
                let event = PluginViewEvent(panelID: owner.panelID, revision: owner.definition.revision, name: name, values: try JSONDecoder().decode([String: PluginValue].self, from: data))
                try owner.definition.validate(event); try owner.onEvent(event)
                replyHandler(["accepted": true], nil)
            } catch { replyHandler(nil, "The plugin did not accept this view event.") }
        }
    }
}

/// Limit concurrent transport without dropping tiles during an ordinary resize.
@MainActor private final class ViewResourceSlots {
    private var available = 12
    private var order: [ObjectIdentifier] = []
    private var waiting: [ObjectIdentifier: CheckedContinuation<Void, Error>] = [:]
    func acquire(_ id: ObjectIdentifier) async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                order.append(id); waiting[id] = continuation
            }
        } onCancel: { Task { @MainActor [weak self] in
            guard let self, let continuation = self.waiting.removeValue(forKey: id) else { return }
            self.order.removeAll { $0 == id }; continuation.resume(throwing: CancellationError())
        } }
    }
    func release() {
        if let id = order.first {
            order.removeFirst(); waiting.removeValue(forKey: id)?.resume()
        } else { available += 1 }
    }
}
