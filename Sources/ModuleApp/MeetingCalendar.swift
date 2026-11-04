import AppKit
import Foundation
import ModuleCore
import VoiceAudio
import NookPluginSDK

extension MeetingModel {
    func calendarCatalog(_ entries: [PluginCatalogEntry]) {
        calendarReadEntries = entries.filter { PluginCalendarContract.accepts($0, action: PluginCalendarContract.read) }
        calendarProviders = Array(entries.filter { PluginCalendarContract.accepts($0, action: PluginCalendarContract.list) }
            .filter { entry in calendarReadEntries.contains { $0.address.plugin == entry.address.plugin } }.sorted { $0.address.key < $1.address.key }.prefix(8))
        if let calendarPendingEntry, !entries.contains(calendarPendingEntry) { cancelCalendar(); calendarStatus = "Calendar access changed. Saved link kept." }
        if !calendarProviders.contains(where: { $0.address.key == calendarProvider }) { calendarProvider = calendarProviders.first?.address.key ?? "" }
    }
    func cancelCalendar(force: Bool = false) {
        if !force, (calendarTask != nil || calendarRequest != nil), let calendarOwner,
           calendarOwner != LocalFoundationModelWork.currentOwner { return }
        let originalTask = calendarTask
        if let calendarRequest {
            if let original = capturedMeetingProviders[calendarRequest] {
                do { try original.request.cancel() }
                catch { providerCancelIssues[calendarRequest] = "cancel-enqueue-failed" }
            } else if captureProviderRequest == nil { cancelCalendarInvocation?(calendarRequest) }
            settleMeetingProvider(calendarRequest, originalTask: originalTask)
        }
        calendarRequest = nil; calendarPendingEntry = nil; calendarTask?.cancel(); calendarTask = nil; calendarBusy = false; calendarPurpose = ""
    }
    func loadCalendarLink() {
        cancelCalendar(); calendarPickerOpen = false; calendarEvents = []; calendarNext = -1; calendarStatus = ""
        do { calendarLink = try selected.flatMap { try store?.calendarLink($0.id) } }
        catch { calendarLink = nil; calendarStatus = error.localizedDescription }
        calendarDay = MeetingCalendarDay.text(calendarLink.map { Date(timeIntervalSince1970: $0.event.start) } ?? selected?.created ?? Date())
    }
    func refreshCalendarLibrary() {
        calendarLibrary = [:]
        guard let store else { return }
        for value in library.prefix(500) { if let link = try? store.calendarLink(value.id) { calendarLibrary[value.id] = link } }
    }
    func showCalendarPicker() {
        guard !askingQuestion, !processing, !summarizing, !["preparing", "finishing"].contains(phase) else { return }
        calendarPickerOpen = true
        if calendarEvents.isEmpty { listCalendar(day: calendarDay, provider: calendarProvider, offset: 0) }
    }
    func listCalendar(day: String, provider: String, offset: Int = 0) {
        guard allowProductEffect(.provider) else{return}
        guard !calendarBusy, !askingQuestion else { return }
        do {
            let (start, end) = try MeetingCalendarDay.range(day)
            guard let entry = calendarProviders.first(where: { $0.address.key == provider }), invokeCalendar != nil else { throw VoiceProblem.message("Allow Calendar's two read actions for Voice in Nook Settings → Modules.") }
            calendarDay = day; calendarProvider = provider; calendarEvents = []; calendarNext = -1; calendarTotal = 0
            invokeCalendarAction(entry, values: ["start": .number(start.timeIntervalSince1970), "end": .number(end.timeIntervalSince1970), "offset": .number(Double(offset))], purpose: "list")
        } catch { calendarStatus = error.localizedDescription }
    }
    private func invokeCalendarAction(_ entry: PluginCatalogEntry, values: [String: PluginValue], purpose: String) {
        guard allowProductEffect(.provider) else{return}
        guard permitMeetingWork() else { return }
        guard permitsMeetingProvider() else { calendarStatus = "Provider request limit reached; no new request was sent."; return }
        let owner = LocalFoundationModelWork.currentOwner
        do {
            try entry.action!.input.validate(values)
            let request = UUID(); calendarOwner = owner
            let original = captureProviderRequest?(request)
            if let original { capturedMeetingProviders[request] = (owner, original) }
            else if captureProviderRequest != nil { throw VoiceProblem.message("The original provider connection is no longer available.") }
            else { markMeetingUnverified("provider-local-write-return-unavailable", owner: owner) }
            pendingMeetingProviders[request] = owner; providerEffectUncertain.insert(owner)
            calendarRequest = request; calendarPendingEntry = entry; calendarBusy = true; calendarPurpose = purpose
            calendarStatus = purpose == "list" ? "Reading selected calendar events…" : "Checking the linked event…"
            if let original { try original.invoke(address: entry.address, values: values) }
            else { invokeCalendar?(request, entry.address, values) }
            calendarTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(65)); guard !Task.isCancelled, let self, self.calendarRequest == request else { return }
                self.cancelCalendar(); self.calendarStatus = "Calendar did not respond. Saved link kept."
            }
            retainMeetingTask(calendarTask, owner: owner)
        } catch { cancelCalendar(force: true); calendarStatus = error.localizedDescription }
    }
    func receiveCalendar(_ request: UUID, update: PluginRunUpdate) {
        if update.phase.terminal { settleMeetingProvider(request, originalTask: calendarRequest == request ? calendarTask : nil) }
        guard calendarRequest == request, let entry = calendarPendingEntry, update.phase.terminal else { return }
        let purpose = calendarPurpose
        calendarRequest = nil; calendarPendingEntry = nil; calendarTask?.cancel(); calendarTask = nil; calendarBusy = false; calendarPurpose = ""
        do {
            guard update.phase == .succeeded else { throw VoiceProblem.message(update.message.isEmpty ? "Calendar unavailable. Saved link kept." : String(update.message.prefix(240))) }
            guard (purpose == "list" ? calendarProviders : calendarReadEntries).contains(entry) else { throw VoiceProblem.message("Calendar access changed. Result discarded.") }
            try entry.action!.output.validate(update.values)
            guard case .number(let observed) = update.values["observed_at"], observed.isFinite,
                  observed <= Date().timeIntervalSince1970 + 30, observed >= Date().timeIntervalSince1970 - 120 else { throw VoiceProblem.message("Calendar result is stale. Refresh it.") }
            if purpose == "list" {
                guard case .string(let text) = update.values["events"], case .number(let next) = update.values["next"], case .number(let total) = update.values["total"],
                      next.rounded() == next, (-1...10000).contains(next), total.rounded() == total, (0...10000).contains(total) else { throw VoiceProblem.message("Invalid calendar page") }
                let events = try JSONDecoder().decode([PluginCalendarEvent].self, from: Data(text.utf8)); guard events.count <= 6, Set(events.map(\.reference)).count == events.count else { throw VoiceProblem.message("Invalid calendar event list") }
                for event in events { try event.validate() }
                let (start, end) = try MeetingCalendarDay.range(calendarDay)
                guard events.allSatisfy({ $0.start < end.timeIntervalSince1970 && ($0.end > start.timeIntervalSince1970 || $0.start == $0.end && $0.start >= start.timeIntervalSince1970) }) else { throw VoiceProblem.message("Calendar returned events outside the selected day") }
                calendarEvents = events; calendarNext = Int(next); calendarTotal = Int(total); calendarObserved = Date(timeIntervalSince1970: observed)
                calendarStatus = events.isEmpty ? "No events on this day. Choose another date." : "Choose the exact meeting occurrence. Nothing starts recording."
            } else {
                guard var link = calendarLink, link.provider == entry.address.plugin, case .string(let state) = update.values["status"] else { throw VoiceProblem.message("Linked meeting changed. Result discarded.") }
                if state == "missing" { calendarStatus = "Event no longer found in this calendar. The saved link and recording are kept."; return }
                guard state == "found", case .string(let text) = update.values["event"] else { throw VoiceProblem.message("Calendar returned an invalid event") }
                let event = try JSONDecoder().decode(PluginCalendarEvent.self, from: Data(text.utf8))
                link = try link.refreshed(with: event, at: Date(timeIntervalSince1970: observed))
                if let selected { try store?.saveCalendarLink(link, id: selected.id); calendarLibrary[selected.id] = link }
                calendarLink = link; calendarStatus = "Linked meeting verified · recording, transcript and notes stay together"
                if purpose == "open", let url = event.url { NSWorkspace.shared.open(url) }
            }
        } catch { calendarStatus = error.localizedDescription }
    }
    func linkCalendar(_ index: String) {
        guard permitMeetingWork(), !calendarBusy, !askingQuestion, let i = Int(index), calendarEvents.indices.contains(i), let entry = calendarProviders.first(where: { $0.address.key == calendarProvider }),
              Date().timeIntervalSince(calendarObserved) <= 120 else { calendarStatus = "Refresh the calendar list before linking."; return }
        do {
            let link = MeetingCalendarLink(provider: entry.address.plugin, providerName: entry.action!.title, event: calendarEvents[i], verifiedAt: calendarObserved)
            try link.validate()
            if let selected { try store?.saveCalendarLink(link, id: selected.id); calendarLibrary[selected.id] = link }
            calendarLink = link; calendarPickerOpen = false; calendarStatus = selected == nil ? "Meeting selected · press Start recording when ready" : "Calendar linked to this recording, every transcript and its notes"
            searchLibrary()
        } catch { calendarStatus = error.localizedDescription }
    }
    func unlinkCalendar() {
        guard permitMeetingWork(), !calendarBusy, !askingQuestion else { return }
        do {
            if let selected { try store?.saveCalendarLink(nil, id: selected.id); calendarLibrary[selected.id] = nil }
            calendarLink = nil; calendarStatus = "Calendar link removed · recording, transcripts and notes retained"; searchLibrary()
        } catch { calendarStatus = error.localizedDescription }
    }
    func verifyCalendar(open: Bool = false) {
        guard allowProductEffect(.provider) else{return}
        guard !calendarBusy, let link = calendarLink else { return }
        guard let entry = calendarReadEntries.first(where: { $0.address.plugin == link.provider }) else { calendarStatus = "Calendar provider unavailable. Saved link kept."; return }
        do { invokeCalendarAction(entry, values: ["reference": .string(try PluginCalendarContract.json(link.event.reference))], purpose: open ? "open" : "verify") }
        catch { calendarStatus = error.localizedDescription }
    }
}
