import XCTest
import NookPluginSDK
@testable import ModuleCore

final class MeetingCalendarTests: XCTestCase {
    func event(_ occurrence: String = "single", calendar: String = "test-calendar") -> PluginCalendarEvent {
        .init(reference: .init(calendar: calendar, event: "test-event", occurrence: occurrence), title: "Design review", calendarName: "Local test calendar", start: Date(timeIntervalSince1970: 1_791_907_200), end: Date(timeIntervalSince1970: 1_791_910_800))
    }
    func testOldMeetingsStayReadableAndAttachmentDoesNotChangeArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), meeting = Meeting(title: "Existing recording", source: "none", microphone: true)
        try store.save(meeting); let original = try Data(contentsOf: store.folder(meeting.id).appendingPathComponent("meeting.json"))
        XCTAssertNil(try store.calendarLink(meeting.id))
        var notes = MeetingNotebook(meetingID: meeting.id); notes.thoughts = "Private thought"; try store.saveNotebook(notes)
        let noteBytes = try Data(contentsOf: store.folder(meeting.id).appendingPathComponent("notebook.json"))
        let link = MeetingCalendarLink(provider: "test.calendar", providerName: "Test calendar", event: event())
        try store.saveCalendarLink(link, id: meeting.id)
        XCTAssertEqual(try store.calendarLink(meeting.id), link)
        XCTAssertEqual(try Data(contentsOf: store.folder(meeting.id).appendingPathComponent("meeting.json")), original)
        XCTAssertEqual(try Data(contentsOf: store.folder(meeting.id).appendingPathComponent("notebook.json")), noteBytes)
        try store.saveCalendarLink(nil, id: meeting.id); XCTAssertNil(try store.calendarLink(meeting.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(meeting.id).appendingPathComponent("calendar-link.previous.json").path))
    }
    func testRecurringIdentityCannotRefreshToAnotherCalendarOrOccurrence() throws {
        let link = MeetingCalendarLink(provider: "test.calendar", providerName: "Test calendar", event: event("recurrence-one"))
        var moved = link.event; moved.start += 7200; moved.end += 7200; moved.title = "Updated review"
        XCTAssertEqual(try link.refreshed(with: moved).event.title, "Updated review")
        XCTAssertThrowsError(try link.refreshed(with: event("recurrence-two")))
        XCTAssertThrowsError(try link.refreshed(with: event("recurrence-one", calendar: "another-calendar")))
    }
    func testDaySelectionHandlesDSTAndRejectsInvalidDates() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let spring = try MeetingCalendarDay.range("2026-03-08", calendar: cal), autumn = try MeetingCalendarDay.range("2026-11-01", calendar: cal)
        XCTAssertEqual(spring.1.timeIntervalSince(spring.0), 23*3600)
        XCTAssertEqual(autumn.1.timeIntervalSince(autumn.0), 25*3600)
        for text in ["2026-02-30", "2026-1-01", "no date", "9999-01-01"] { XCTAssertThrowsError(try MeetingCalendarDay.range(text, calendar: cal)) }
    }
    func testScopedAttachmentRejectsForeignIDAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(root: root), one = Meeting(title: "One", source: "none", microphone: true), two = Meeting(title: "Two", source: "none", microphone: true)
        try store.save(one); try store.save(two); try store.saveCalendarLink(.init(provider: "test.calendar", providerName: "Test", event: event()), id: one.id)
        let src = store.folder(one.id).appendingPathComponent("calendar-link.json"), dst = store.folder(two.id).appendingPathComponent("calendar-link.json")
        try Data(contentsOf: src).write(to: dst); XCTAssertThrowsError(try store.calendarLink(two.id))
        try FileManager.default.removeItem(at: dst); try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)
        XCTAssertThrowsError(try store.saveCalendarLink(nil, id: two.id)); XCTAssertThrowsError(try store.calendarLink(two.id))
    }
    func testSharedCalendarPagingRangeAndURLValidation() throws {
        let rows = (0..<20).map { index -> PluginCalendarEvent in var e = event(); e.reference.event += String(index); return e }
        let page = try PluginCalendarContract.page(rows, offset: 0)
        try PluginCalendarContract.list.output.validate(page)
        guard case .string(let json) = page["events"], case .number(let next) = page["next"] else { return XCTFail("Missing page") }
        XCTAssertLessThanOrEqual(json.utf8.count, 2048); XCTAssertTrue(next > 0)
        XCTAssertThrowsError(try PluginCalendarContract.range(["start": .number(0), "end": .number(86400*4), "offset": .number(0)]))
        XCTAssertThrowsError(try PluginCalendarContract.range(["start": .number(0), "end": .number(86400), "offset": .number(1.5)]))
        var unsafe = event(); unsafe.url = URL(string: "https://user:password@example.com/event")
        XCTAssertThrowsError(try unsafe.validate())
    }
}
