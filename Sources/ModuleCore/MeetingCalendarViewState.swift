import Foundation

public struct MeetingCalendarViewState: Codable {
    public var open: Bool
    public var busy: Bool
    public var day: String
    public var provider: String
    public var providers: [[String: String]]
    public var linked: Event?
    public var events: [Event]
    public var status: String
    public var next: Int
    public var total: Int
    public var canVerify: Bool
    public var canOpen: Bool
    public struct Event: Codable {
        public let id: String
        public let title: String
        public let calendar: String
        public let when: String
        public init(id: String, title: String, calendar: String, when: String) { self.id = id; self.title = title; self.calendar = calendar; self.when = when }
    }
    public init(open: Bool, busy: Bool, day: String, provider: String, providers: [[String: String]], linked: Event?, events: [Event], status: String, next: Int, total: Int, canVerify: Bool, canOpen: Bool) {
        self.open = open; self.busy = busy; self.day = day; self.provider = provider; self.providers = providers; self.linked = linked
        self.events = events; self.status = status; self.next = next; self.total = total; self.canVerify = canVerify; self.canOpen = canOpen
    }
}
