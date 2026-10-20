import Foundation
import NookPluginSDK

/// One local attachment shared by every audio/transcript/notebook in a meeting
/// folder. No changes to old meeting.json, audio or transcript formats.
public struct MeetingCalendarLink: Codable, Equatable, Sendable {
    public var provider: String
    public var providerName: String
    public var event: PluginCalendarEvent
    public var linkedAt: Date
    public var verifiedAt: Date?
    public init(provider: String, providerName: String, event: PluginCalendarEvent, linkedAt: Date = Date(), verifiedAt: Date? = nil) {
        self.provider = provider; self.providerName = providerName; self.event = event; self.linkedAt = linkedAt; self.verifiedAt = verifiedAt
    }
    public func validate() throws {
        try PluginActionAddress(provider, PluginCalendarContract.list.id).validate(); try event.validate()
        guard !providerName.isEmpty, providerName.utf8.count <= 180, linkedAt.timeIntervalSince1970.isFinite,
              verifiedAt?.timeIntervalSince1970.isFinite ?? true else { throw VoiceProblem.message("Invalid calendar attachment") }
    }
    public func refreshed(with value: PluginCalendarEvent, at date: Date = Date()) throws -> Self {
        try value.validate()
        guard value.reference == event.reference else { throw VoiceProblem.message("The calendar returned a different event occurrence. Saved link kept.") }
        var updated = self; updated.event = value; updated.verifiedAt = date; return updated
    }
    public var searchableText: String { event.title + "\n" + event.calendarName }
    public var markdown: String {
        let start = Date(timeIntervalSince1970: event.start).formatted(date: .abbreviated, time: event.allDay ? .omitted : .shortened)
        var value = "## Calendar meeting\n\n\(event.title)\n\(start) · \(event.calendarName)\n"
        if let url = event.url { value += "\(url.absoluteString)\n" }
        return value + "\n"
    }
}
private struct MeetingCalendarAttachment: Codable {
    let version: Int
    let meetingID: UUID
    let link: MeetingCalendarLink?
}
extension MeetingStore {
    private func calendarAttachmentURL(_ id: UUID) throws -> URL {
        _ = try load(id)
        let url = folder(id).appendingPathComponent("calendar-link.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 16384 else { throw VoiceProblem.message("Calendar attachment unavailable") }
        }
        return url
    }
    public func calendarLink(_ id: UUID) throws -> MeetingCalendarLink? {
        let url = try calendarAttachmentURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attachment = try JSONDecoder().decode(MeetingCalendarAttachment.self, from: Data(contentsOf: url))
        guard attachment.version == 1, attachment.meetingID == id else { throw VoiceProblem.message("Calendar attachment belongs to another meeting") }
        try attachment.link?.validate(); return attachment.link
    }
    public func saveCalendarLink(_ link: MeetingCalendarLink?, id: UUID) throws {
        try link?.validate(); let url = try calendarAttachmentURL(id)
        // Keep one bounded recovery copy for relink/unlink, including malformed
        // prior JSON. Never follow a pre-existing backup symlink.
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = folder(id).appendingPathComponent("calendar-link.previous.json")
            if FileManager.default.fileExists(atPath: backup.path) {
                let attrs = try backup.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attrs.isRegularFile == true, attrs.isSymbolicLink != true else { throw VoiceProblem.message("Calendar recovery copy unavailable") }
            }
            try Data(contentsOf: url).write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let data = try JSONEncoder().encode(MeetingCalendarAttachment(version: 1, meetingID: id, link: link))
        guard data.count <= 16384 else { throw VoiceProblem.message("Calendar attachment exceeds its limit") }
        try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum MeetingCalendarDay {
    public static func text(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    public static func range(_ text: String, calendar: Calendar = .current) throws -> (Date, Date) {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard text.count == 10, parts.count == 3, (1900...2100).contains(parts[0]),
              let start = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Self.text(start, calendar: calendar) == text, let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { throw VoiceProblem.message("Choose a valid calendar date") }
        return (start, end)
    }
}
