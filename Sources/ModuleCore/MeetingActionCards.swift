import Foundation

public struct MeetingActionCard: Encodable, Sendable {
    public struct Source: Encodable, Sendable {
        public let id: String
        public let quote: String
        public let start: Double
        public let track: String
        init(_ value: MeetingNoteEvidence) {
            id = value.id.uuidString; quote = value.quote; start = value.start; track = value.track
        }
    }
    public let id: String
    public let task: String
    public let owner: String?
    public let deadline: String?
    public let status: String
    public let sources: [Source]
}

extension MeetingNotebook {
    public var actionCards: [MeetingActionCard] {
        if let actionResolutions {
            return actionResolutions.map { .init(id: $0.id.uuidString, task: $0.task, owner: $0.presentedOwner,
                deadline: $0.deadline, status: $0.status.rawValue, sources: $0.evidence.map(MeetingActionCard.Source.init)) }
        }
        return (evidence ?? []).filter { $0.section == .actions }.prefix(12).map {
            .init(id: $0.id.uuidString, task: $0.fact, owner: nil, deadline: nil, status: "legacy", sources: [.init($0)])
        }
    }
}
