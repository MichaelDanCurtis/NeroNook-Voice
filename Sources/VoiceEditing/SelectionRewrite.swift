import AppKit
import Combine
import ModuleCore

@MainActor public protocol SelectionEditor: AnyObject {
    func capture() throws -> SelectionCapture
    func replace(_ capture: SelectionCapture, with text: String) async throws -> DictationEdit
    func undo(_ capture: SelectionCapture, edit: DictationEdit) async throws
    func forget()
    func restoreFocus()
}
public extension SelectionEditor { func restoreFocus() {} }

/// A separately admitted, transient edit. No audio, agent, clipboard or durable
/// history access. Late model/editor callbacks cannot revive a retired session.
@MainActor public final class SelectionRewrite: ObservableObject {
    public enum Phase: Equatable { case closed, reviewing, generating, applying, applied, undoing, undone, blocked }
    @Published public private(set) var phase: Phase = .closed
    @Published public private(set) var capture: SelectionCapture?
    @Published public var result = ""
    @Published public var operation: SelectionTransformation = .improve
    @Published public private(set) var status = ""
    public var changed: (() -> Void)?
    public var active: Bool { phase != .closed }
    public var working: Bool { [.generating, .applying, .undoing].contains(phase) }
    public var canApply: Bool { phase == .reviewing && !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result.utf8.count <= 12_000 && result != capture?.text }
    public var canUndo: Bool { phase == .applied && edit != nil }
    private let editor: any SelectionEditor
    private let generate: (String, SelectionTransformation) async throws -> String
    /// Native owner context captured synchronously for this original transform.
    /// Generic closure; the editing module has no dependency on speech/model APIs.
    public var captureGenerator: (() -> ((String, SelectionTransformation) async throws -> String))?
    private var edit: DictationEdit?
    private var epoch = UUID()
    private var sessionID = UUID()
    private var work: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var originalRetirement: Task<Void, Never>?
    private var retirementID: UUID?
    public var retiring: Bool { originalRetirement != nil }
    public func retirementCompletion() -> Task<Void, Never>? { originalRetirement }
    private let lifetime: Duration
    public init(editor: any SelectionEditor, lifetime: Duration = .seconds(300), generate: @escaping (String, SelectionTransformation) async throws -> String) {
        self.editor = editor; self.generate = generate; self.lifetime = lifetime
    }
    public func begin() throws {
        guard !active else { return }
        guard !retiring else { throw SelectionProblem.unavailable }
        let value = try editor.capture()
        capture = value; result = value.text; edit = nil; epoch = UUID(); sessionID = UUID()
        phase = .reviewing; status = "Choose a change, or edit the preview. Nothing changes until Replace."
        let expected = sessionID
        expiry = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: lifetime) } catch { return }
            guard !Task.isCancelled, sessionID == expected else { return }
            close()
        }
        changed?()
    }
    public func transform() {
        guard phase == .reviewing, let capture else { return }
        let token = UUID(); epoch = token; phase = .generating
        // Keep a single original-selection source across retries/operation changes.
        let operation = operation
        let generate = captureGenerator?() ?? self.generate
        status = "\(operation.rawValue) · Apple Intelligence · on this Mac"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let candidate = try await generate(capture.text, operation)
                guard !Task.isCancelled, epoch == token, phase == .generating else { return }
                let cleaned = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, cleaned.utf8.count <= 12_000 else { throw SelectionProblem.invalidResult }
                result = cleaned; phase = .reviewing; status = "Review meaning, names, numbers and commitments before Replace."
            } catch {
                guard !Task.isCancelled, epoch == token, phase == .generating else { return }
                phase = .reviewing; status = error.localizedDescription
            }
            changed?()
        }
    }
    public func apply() {
        guard canApply, let capture else { return }
        let token = epoch, text = result; phase = .applying; status = "Checking the original selection…"
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let verified = try await editor.replace(capture, with: text)
                guard !Task.isCancelled, epoch == token, phase == .applying else { return }
                edit = verified; phase = .applied; status = "Replaced in \(capture.app). Undo is available until you edit or move the cursor."
            } catch {
                guard epoch == token, phase == .applying else { return }
                edit = nil
                phase = (error as? SelectionProblem)?.allowsExplicitRetry == true ? .reviewing : .blocked
                status = error.localizedDescription
            }
            changed?()
        }
    }
    public func undo() {
        guard canUndo, let capture, let edit else { return }
        let token = epoch; phase = .undoing
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await editor.undo(capture, edit: edit)
                guard !Task.isCancelled, epoch == token, phase == .undoing else { return }
                self.edit = nil; phase = .undone; status = "Original selection restored."
            } catch {
                guard epoch == token, phase == .undoing else { return }
                self.edit = nil; phase = .blocked; status = error.localizedDescription
            }
            changed?()
        }
    }
    public func close(returnToEditor: Bool = false) {
        epoch = UUID(); sessionID = UUID()
        let originalWork = work, originalExpiry = expiry, previous = originalRetirement
        work = nil; expiry = nil
        originalWork?.cancel(); originalExpiry?.cancel()
        if originalWork != nil || originalExpiry != nil {
            let id = UUID(); retirementID = id
            originalRetirement = Task { [weak self] in
                await previous?.value; await originalWork?.value; await originalExpiry?.value
                guard let self, self.retirementID == id else { return }
                self.originalRetirement = nil; self.retirementID = nil; self.changed?()
            }
        }
        if returnToEditor { editor.restoreFocus() }
        capture = nil; result = ""; edit = nil; phase = .closed; status = ""; editor.forget(); changed?()
    }
}
