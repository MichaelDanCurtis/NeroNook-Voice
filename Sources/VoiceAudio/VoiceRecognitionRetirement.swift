import Foundation

/// Process-local recognition retirement only. A caller captures the previous
/// tail before starting; it must never reread a tail containing its own drain.
/// This is not a cross-process microphone lease or an OS release guarantee.
@MainActor public enum VoiceRecognitionRetirement {
    private static var tail: Task<Void, Never>?
    private static var identity: UUID?

    public static func pending() -> Task<Void, Never>? { tail }

    static func retain(_ original: Task<Void, Never>) {
        let previous = tail, id = UUID()
        identity = id
        tail = Task {
            await previous?.value
            await original.value
            if identity == id { tail = nil; identity = nil }
        }
    }
}
