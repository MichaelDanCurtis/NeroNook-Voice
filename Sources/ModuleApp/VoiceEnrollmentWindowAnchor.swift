import AppKit
import SwiftUI

/// The setup view owns this binding. It never searches application windows and
/// cannot grant native service ownership or lifecycle admission.
@MainActor final class VoiceEnrollmentWindowAnchor: ObservableObject {
    private weak var view: VoiceEnrollmentAnchorView?
    private weak var window: NSWindow?
    private var generation = UUID()
    private var closeObserver: NSObjectProtocol?
    private var invalidations: [UUID: @MainActor () -> Void] = [:]

    @MainActor struct Snapshot {
        fileprivate let anchor: VoiceEnrollmentWindowAnchor
        let parent: NSWindow
        fileprivate let generation: UUID
        var isCurrent: Bool { anchor.isCurrent(self) }
        @discardableResult func onInvalidation(_ body: @escaping @MainActor () -> Void) -> UUID? {
            anchor.observe(self, body)
        }
        func removeObservation(_ token: UUID?) { if let token { anchor.invalidations[token] = nil } }
    }
    func capture() -> Snapshot? {
        guard let window else { return nil }
        let snapshot = Snapshot(anchor: self, parent: window, generation: generation)
        return isCurrent(snapshot) ? snapshot : nil
    }
    private func isCurrent(_ snapshot: Snapshot) -> Bool {
        snapshot.anchor === self && snapshot.generation == generation &&
            window === snapshot.parent && view?.window === snapshot.parent && snapshot.parent.isVisible
    }
    private func observe(_ snapshot: Snapshot, _ body: @escaping @MainActor () -> Void) -> UUID? {
        guard isCurrent(snapshot) else { body(); return nil }
        let token = UUID(); invalidations[token] = body; return token
    }
    fileprivate func attach(_ view: VoiceEnrollmentAnchorView) {
        guard self.view !== view || window !== view.window else { return }
        invalidate()
        self.view = view; window = view.window
        if let window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate() }
            }
        }
    }
    fileprivate func detach(_ view: VoiceEnrollmentAnchorView) {
        guard self.view === view else { return }; invalidate()
    }
    private func invalidate() {
        generation = UUID(); view = nil; window = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        let originals = Array(invalidations.values); invalidations.removeAll()
        for original in originals { original() }
    }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
}

/// This is the actual NSView installed by the setup view's representable.
@MainActor final class VoiceEnrollmentAnchorView: NSView {
    weak var anchor: VoiceEnrollmentWindowAnchor?
    init(anchor: VoiceEnrollmentWindowAnchor) { self.anchor = anchor; super.init(frame: .zero) }
    required init?(coder: NSCoder) { return nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { anchor?.detach(self) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); anchor?.attach(self) }
    func dismantle() { anchor?.detach(self); anchor = nil }
}

@MainActor struct VoiceEnrollmentWindowReader: NSViewRepresentable {
    let anchor: VoiceEnrollmentWindowAnchor
    func makeNSView(context: Context) -> VoiceEnrollmentAnchorView { VoiceEnrollmentAnchorView(anchor: anchor) }
    func updateNSView(_ nsView: VoiceEnrollmentAnchorView, context: Context) {}
    static func dismantleNSView(_ nsView: VoiceEnrollmentAnchorView, coordinator: ()) { nsView.dismantle() }
}

/// Each actual SwiftUI setup surface has its own anchor. Button admission
/// snapshots the parent before bootstrap schedules its retained original task.
@MainActor struct VoiceNormalSetupView: View {
    @ObservedObject var bootstrap: VoiceServiceBootstrap
    @StateObject private var anchor: VoiceEnrollmentWindowAnchor
    init(bootstrap: VoiceServiceBootstrap) {
        self.bootstrap = bootstrap; _anchor = StateObject(wrappedValue: VoiceEnrollmentWindowAnchor())
    }
    init(bootstrap: VoiceServiceBootstrap, anchor: VoiceEnrollmentWindowAnchor) {
        self.bootstrap = bootstrap; _anchor = StateObject(wrappedValue: anchor)
    }
    static func requestSetup(bootstrap: VoiceServiceBootstrap, anchor: VoiceEnrollmentWindowAnchor) {
        bootstrap.requestNormalEnrollment(from: anchor.capture())
    }
    var body: some View {
        VStack(spacing: 16) {
            Text("Nero Voice").font(.title2)
            Text(bootstrap.status).multilineTextAlignment(.center)
            if bootstrap.canEnroll { Button("Set up shared Voice…") { Self.requestSetup(bootstrap: bootstrap, anchor: anchor) } }
        }.padding(30).frame(width: 500)
            .background(VoiceEnrollmentWindowReader(anchor: anchor))
    }
}
