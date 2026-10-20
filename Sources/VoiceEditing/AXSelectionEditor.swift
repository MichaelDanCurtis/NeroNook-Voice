import AppKit
import ApplicationServices
import ModuleCore

/// Exact AX edits only. Unsupported web/Electron editors are refused instead
/// of guessing a paste destination or replacing an entire field.
@MainActor public final class AXSelectionEditor: SelectionEditor {
    private struct Target {
        let capture: SelectionCapture
        let pid: pid_t
        let window: AXUIElement
        let element: AXUIElement
    }
    private var target: Target?
    public init() {}
    public func forget() { target = nil }
    public func restoreFocus() {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              let target, let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else { return }
        app.activate()
    }
    public func capture() throws -> SelectionCapture {
        forget()
        guard AXIsProcessTrusted() else { throw SelectionProblem.permission }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { throw SelectionProblem.invalidSelection }
        let ax = application(app.processIdentifier)
        guard let window = element(ax, kAXFocusedWindowAttribute),
              let field = element(ax, kAXFocusedUIElementAttribute) else { throw SelectionProblem.unsupported }
        try checkField(field)
        let (value, range) = try contents(field)
        let capture = try SelectionCapture(app: app.localizedName ?? "original app", value: value, range: range)
        guard (attribute(field, kAXSelectedTextAttribute) as? String) == capture.text else { throw SelectionProblem.unsupported }
        target = Target(capture: capture, pid: app.processIdentifier, window: window, element: field)
        return capture
    }
    public func replace(_ capture: SelectionCapture, with text: String) async throws -> DictationEdit {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 12_000,
              let plan = DictationEdit(value: capture.value, selection: capture.range, insertion: text) else { throw SelectionProblem.invalidResult }
        let target = try await prepare(capture, value: plan.before, range: plan.selection)
        try Task.checkCancellation()
        guard AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else { throw SelectionProblem.unsupported }
        // Once the write is sent, a failed readback is an uncertain outcome,
        // never a second automatic attempt or an unverified Undo promise.
        guard let current = try? contents(target.element), current.0 == plan.after, current.1 == plan.caret else { throw SelectionProblem.unverified }
        return plan
    }
    public func undo(_ capture: SelectionCapture, edit: DictationEdit) async throws {
        let target: Target
        do { target = try await prepare(capture, value: edit.after, range: edit.caret) }
        catch SelectionProblem.changed { throw SelectionProblem.undoChanged }
        try Task.checkCancellation()
        try select(edit.insertedRange, in: target.element)
        guard let current = try? contents(target.element), current.0 == edit.after, current.1 == edit.insertedRange else { throw SelectionProblem.unverified }
        guard AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, edit.replacedText as CFString) == .success else { throw SelectionProblem.unverified }
        guard let restored = try? contents(target.element), restored.0 == edit.before else { throw SelectionProblem.unverified }
        try select(edit.selection, in: target.element)
        guard let final = try? contents(target.element), final.0 == edit.before, final.1 == edit.selection else { throw SelectionProblem.unverified }
    }
    private func prepare(_ capture: SelectionCapture, value: String, range: NSRange) async throws -> Target {
        guard AXIsProcessTrusted() else { throw SelectionProblem.permission }
        guard let target, target.capture == capture else { throw SelectionProblem.changed }
        try validate(target, value: value, range: range)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard foreground == target.pid || foreground == ProcessInfo.processInfo.processIdentifier else { throw SelectionProblem.changed }
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else { throw SelectionProblem.changed }
        // Return to the exact original editor automatically; no five-second
        // countdown or requirement to click the selection again.
        if foreground != target.pid { app.activate() }
        for _ in 0..<20 {
            try Task.checkCancellation()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else { throw SelectionProblem.changed }
        try validate(target, value: value, range: range)
        return target
    }
    private func validate(_ target: Target, value: String, range: NSRange) throws {
        let ax = application(target.pid)
        guard let window = element(ax, kAXFocusedWindowAttribute), CFEqual(window, target.window),
              let field = element(ax, kAXFocusedUIElementAttribute), CFEqual(field, target.element) else { throw SelectionProblem.changed }
        try checkField(field)
        let current = try contents(field)
        guard current.0 == value, current.1 == range else { throw SelectionProblem.changed }
    }
    private func checkField(_ field: AXUIElement) throws {
        AXUIElementSetMessagingTimeout(field, 0.25)
        let role = attribute(field, kAXRoleAttribute) as? String
        guard (attribute(field, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole,
              (attribute(field, "AXProtectedContent") as? Bool) != true,
              [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role ?? "") else { throw SelectionProblem.unsupported }
        for key in [kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            var writable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(field, key as CFString, &writable) == .success, writable.boolValue else { throw SelectionProblem.unsupported }
        }
    }
    private func contents(_ field: AXUIElement) throws -> (String, NSRange) {
        guard let value = attribute(field, kAXValueAttribute) as? String, value.utf8.count <= 131_072,
              let raw = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { throw SelectionProblem.unsupported }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location != kCFNotFound,
              DictationEdit.valid(NSRange(location: range.location, length: range.length), in: value) else { throw SelectionProblem.unsupported }
        return (value, NSRange(location: range.location, length: range.length))
    }
    private func select(_ range: NSRange, in field: AXUIElement) throws {
        var cf = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cf), AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success else { throw SelectionProblem.unverified }
    }
    private func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.25); return app
    }
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }
    private func element(_ parent: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(parent, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
