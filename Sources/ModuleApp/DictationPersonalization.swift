import AppKit
import Foundation
import ModuleCore
import NookPluginSDK
import UniformTypeIdentifiers
import VoiceAudio

extension VoiceModel {
    func loadPersonalization() {
        guard !CommandLine.arguments.contains("--protocol-test") else { return }
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeroVoice/Dictation")
            personalizationStore = try DictationPersonalizationStore(root: root)
            personalization = try personalizationStore!.configuration()
        } catch { personalizationFault = true; personalizationStatus = "Settings unavailable; original file kept. \(error.localizedDescription)" }
        refreshHistory()
    }
    func refreshHistory() {
        guard let personalizationStore else { return }; historyLastRefresh = Date()
        do {
            var value = try personalizationStore.history(); let previous = value
            value.prune(days: personalization.retentionDays)
            if value != previous { try personalizationStore.save(value) }
            dictationHistory = value; historyFault = false; historyLastRefresh = Date()
        } catch { historyFault = true; personalizationStatus = "History unavailable; original file kept. \(error.localizedDescription)" }
    }
    func savePersonalization(_ value: DictationPersonalization) throws {
        guard !personalizationFault, let personalizationStore else { throw VoiceProblem.message("Dictation settings need recovery") }
        try personalizationStore.save(value)
        if value.historyEnabled != personalization.historyEnabled { historyEpoch = UUID() }
        personalization = value; refreshHistory(); changed?()
    }
    func saveDictationHistory(raw: String, text: String, tone: DictationTone, appID: String, appName: String, recognizer: String, ticket: UUID?) -> UUID? {
        guard let ticket, ticket == historyEpoch, personalization.historyEnabled, !historyFault, let personalizationStore else { return nil }
        do {
            var next = dictationHistory
            let entry = DictationHistoryEntry(raw: raw, text: text, appID: appID, appName: String(appName.prefix(80)), tone: tone, recognizer: recognizer)
            try next.append(entry, enabled: true, days: personalization.retentionDays)
            try personalizationStore.save(next); dictationHistory = next; return entry.id
        } catch { personalizationStatus = "Draft kept, but history could not be saved: \(error.localizedDescription)"; return nil }
    }
    func setHistoryOutcome(_ id: UUID?, value: String) {
        guard let id, let i = dictationHistory.entries.firstIndex(where: { $0.id == id }), let personalizationStore, !historyFault else { return }
        do { var next = dictationHistory; next.entries[i].outcome = value; try personalizationStore.save(next); dictationHistory = next }
        catch { personalizationStatus = "History outcome could not be updated; draft retained." }
    }
    func refreshStyleApps() {
        var apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != "cafe.nero.plugin.voice" }.compactMap { app -> DictationAppStyle? in
            guard let id = app.bundleIdentifier, DictationPersonalization.validApp(id) else { return nil }
            return .init(appID: id, name: String((app.localizedName ?? id).prefix(80)), tone: tone)
        }
        apps += personalization.apps
        styleApps = Dictionary(grouping: apps, by: \.appID).compactMap { $0.value.first }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if styleAppID.isEmpty { styleAppID = styleApps.first?.appID ?? "" }
    }
    func chooseStyleApp() {
        guard !busy, appPicker == nil else { return }
        let panel = NSOpenPanel(); appPicker = panel; panel.title = "Choose an app for dictation style"; panel.prompt = "Choose app"
        panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true); NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in Task { @MainActor in
            guard let self else { return }; self.appPicker = nil
            guard response == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, DictationPersonalization.validApp(id) else { return }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
            self.styleApps.removeAll { $0.appID == id }; self.styleApps.append(.init(appID: id, name: String(name.prefix(80)), tone: self.tone)); self.styleAppID = id
        } }; panel.makeKeyAndOrderFront(nil)
    }
    func applyDraftPersonalization() {
        guard !busy, !session.transcript.isEmpty else { return }
        let raw = session.transcript, selectedTone = personalization.tone(for: styleAppID, fallback: tone), snippets = personalization.snippets, terms = dictionary
        let generation = session.token; polishing = true; status = "Applying style and snippets on this Mac…"
        let worker = Task.detached { () -> Result<String, Error> in
            do {
                let plan = try DictationSnippetPlan(raw: raw, snippets: snippets)
                if let exact = plan.exactText { return .success(exact) }
                let cleaned = await VoicePolisher.polish(plan.prepared, tone: selectedTone, dictionary: terms)
                return .success(try plan.render(cleaned, fallback: VoiceCleanup.baseline(plan.prepared, tone: selectedTone, dictionary: terms)))
            } catch { return .failure(error) }
        }
        draftPersonalizationWorker = worker
        draftPersonalizationTask = Task { [weak self] in
            let result = await worker.value
            guard let self, !Task.isCancelled, self.session.token == generation else { return }
            self.polishing = false; self.draftPersonalizationWorker = nil; self.draftPersonalizationTask = nil
            do { let text = try result.get(); try self.session.edit(text); self.status = "Preview ready · nothing pasted or saved to history"; self.revision = UUID() }
            catch { self.status = error.localizedDescription }
        }
    }
    func handlePersonalization(_ values: [String: PluginValue]) throws {
        func string(_ key: String) -> String { if case .string(let value) = values[key] { return value }; return "" }
        let command = string("command")
        guard !busy || command == "page" || (command == "history" && values["enabled"] == .boolean(false)) else { return }
        switch command {
        case "page": if ["dictate", "styles", "snippets", "history"].contains(string("page")) { dictationPage = string("page"); personalizationPage = 0; personalizationStatus = ""; if dictationPage == "styles" { refreshStyleApps() }; if dictationPage == "history" { refreshHistory() } }
        case "defaultTone": if let value = DictationTone(rawValue: string("tone")) { tone = value }
        case "chooseApp": chooseStyleApp()
        case "appSearch": styleAppQuery = String(string("name").prefix(60))
        case "appSelect": if styleApps.contains(where: { $0.appID == string("app") }) { styleAppID = string("app") }
        case "appSave":
            guard let app = styleApps.first(where: { $0.appID == string("app") }), let selectedTone = DictationTone(rawValue: string("tone")) else { return }
            var next = personalization; next.apps.removeAll { $0.appID == app.appID }; next.apps.append(.init(appID: app.appID, name: app.name, tone: selectedTone)); try savePersonalization(next); personalizationStatus = "App style saved"
        case "appRemove": var next = personalization; next.apps.removeAll { $0.appID == string("app") }; try savePersonalization(next); personalizationStatus = "App uses your default style"
        case "snippetSelect": selectedSnippet = UUID(uuidString: string("id"))
        case "snippetSave":
            var next = personalization; let id = UUID(uuidString: string("id")) ?? UUID(), snippet = DictationSnippet(id: id, name: string("name").trimmingCharacters(in: .whitespacesAndNewlines), text: string("text"))
            next.snippets.removeAll { $0.id == id }; next.snippets.append(snippet); try savePersonalization(next); selectedSnippet = id; personalizationStatus = "Snippet saved · say insert snippet \(snippet.name)"
        case "snippetRemove": var next = personalization; next.snippets.removeAll { $0.id.uuidString == string("id") }; try savePersonalization(next); selectedSnippet = nil; personalizationStatus = "Snippet removed"
        case "snippetUse": if let value = personalization.snippets.first(where: { $0.id.uuidString == string("id") }) { try session.loadDraft(raw: value.text, text: value.text); dictationPage = "dictate"; status = "Snippet loaded · review or copy, nothing pasted" }
        case "applyDraft": applyDraftPersonalization()
        case "history":
            guard case .boolean(let enabled) = values["enabled"], case .number(let days) = values["days"], [1.0,7.0,30.0].contains(days) else { return }
            var next = personalization; next.historyEnabled = enabled; next.retentionDays = Int(days); try savePersonalization(next)
            personalizationStatus = enabled ? "Future completed dictation will be saved locally" : "Saving is off. Existing entries expire normally or can be cleared."
        case "historySelect": selectedHistory = UUID(uuidString: string("id"))
        case "historyLoad": if let value = dictationHistory.entries.first(where: { $0.id.uuidString == string("id") }) { try session.loadDraft(raw: value.raw, text: value.text); dictationPage = "dictate"; status = "History draft loaded · nothing pasted" }
        case "historyClear":
            let alert = NSAlert(); alert.messageText = "Erase local dictation history?"; alert.informativeText = "Saved words will be permanently removed from Nero Voice. App styles, snippets and meeting recordings remain."; alert.addButton(withTitle: "Erase history"); alert.addButton(withTitle: "Cancel"); NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }; try personalizationStore?.clearHistory(); dictationHistory = .init(); historyFault = false; historyEpoch = UUID(); selectedHistory = nil; personalizationStatus = "Local history erased"
        case "listPage": if case .number(let offset) = values["offset"], offset.isFinite, (0...100).contains(offset) { personalizationPage = Int(offset) }
        default: throw VoiceProblem.message("Unknown dictation preference")
        }
    }
    var personalizationViewState: [String: String] {
        func json<T: Encodable>(_ value: T) -> String { String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? "[]" }
        let snippet = selectedSnippet.flatMap { id in personalization.snippets.first { $0.id == id } }, entry = selectedHistory.flatMap { id in dictationHistory.entries.first { $0.id == id } }
        let snippets = personalization.snippets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let count = dictationPage == "snippets" ? snippets.count : dictationHistory.entries.count, page = min(personalizationPage, max(0,(count - 1) / 6))
        let app = styleApps.first { $0.appID == styleAppID }
        return ["page": dictationPage, "status": String(personalizationStatus.prefix(300)), "fault": personalizationFault || historyFault ? "yes" : "no", "defaultTone": tone.rawValue,
                "app": styleAppID, "appTone": personalization.tone(for: styleAppID, fallback: tone).rawValue, "appName": app?.name ?? "Default style", "appHasRule": personalization.apps.contains { $0.appID == styleAppID } ? "yes" : "no",
                "appQuery": styleAppQuery, "apps": json(dictationPage == "styles" ? Array(styleApps.filter { styleAppQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(styleAppQuery) }.prefix(30)) + (app.map { chosen in styleApps.filter { styleAppQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(styleAppQuery) }.prefix(30).contains(where: { $0.appID == chosen.appID }) ? [] : [chosen] } ?? []) : []), "ruleCount": String(personalization.apps.count),
                "snippets": json(dictationPage == "snippets" ? snippets.dropFirst(page*6).prefix(6).map { ["id": $0.id.uuidString, "name": $0.name] } : []),
                "snippetID": snippet?.id.uuidString ?? "", "snippetName": dictationPage == "snippets" ? snippet?.name ?? "" : "", "snippetText": dictationPage == "snippets" ? snippet?.text ?? "" : "",
                "historyEnabled": personalization.historyEnabled ? "yes" : "no", "days": String(personalization.retentionDays), "historyCount": String(dictationHistory.entries.count),
                "history": json(dictationPage == "history" ? dictationHistory.entries.dropFirst(page*6).prefix(6).map { ["id": $0.id.uuidString, "app": $0.appName, "when": $0.created.formatted(date: .abbreviated, time: .shortened), "preview": String($0.text.prefix(80)), "tone": $0.tone.rawValue, "outcome": $0.outcome] } : []),
                "historyID": entry?.id.uuidString ?? "", "historyText": dictationPage == "history" ? entry?.text ?? "" : "", "historyRaw": dictationPage == "history" ? entry?.raw ?? "" : "",
                "listPage": String(page), "pages": String(max(1,(count+5)/6)), "resolvedStyle": personalization.tone(for: styleAppID, fallback: tone).rawValue]
    }
}
