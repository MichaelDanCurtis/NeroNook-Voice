import AppKit
import Foundation
import ModuleCore
import VoiceAudio
import UniformTypeIdentifiers

extension MeetingModel {
    var organizationViewState: [String: String] {
        var choices: [[String: String]] = [["id": "all", "name": "All meetings", "count": String(library.count)], ["id": "unfiled", "name": "Unfiled", "count": String(library.filter { organization.membership[$0.id.uuidString] == nil }.count)]]
        // Hidden options need not compete with the bounded evidence preview.
        choices += organization.folders.filter { questionSnapshot == nil || $0.id.uuidString == folderScope || $0.id == selected.flatMap { organization.membership[$0.id.uuidString] } }.map { folder in
            ["id": folder.id.uuidString, "name": folder.name, "count": String(library.filter { organization.membership[$0.id.uuidString] == folder.id }.count)]
        }
        return ["scope": folderScope, "name": folderName, "options": String(data: (try? JSONEncoder().encode(choices)) ?? Data(), encoding: .utf8) ?? "[]",
                "member": selected.flatMap { organization.membership[$0.id.uuidString]?.uuidString } ?? "unfiled",
                "status": String(organizationStatus.prefix(300)), "failed": organizationFailed ? "yes" : "no", "canUndo": store?.hasPreviousOrganization == true ? "yes" : "no",
                "locked": occupied || questionSnapshot != nil ? "yes" : "no", "importing": importing ? "yes" : "no", "progress": String(importProgress), "importStatus": String(importStatus.prefix(300)),
                "origin": selected.flatMap { try? store?.importOrigin($0.id)?.filename } ?? ""]
    }
    var folderLibrary: [Meeting] { library.filter { organization.contains($0.id, scope: folderScope) } }
    var folderName: String { folderScope == "all" ? "All meetings" : folderScope == "unfiled" ? "Unfiled" : organization.folders.first { $0.id.uuidString == folderScope }?.name ?? "All meetings" }
    func loadOrganization() {
        guard let store else { return }
        do { organization = try store.organization(); organizationFailed = false }
        catch { organizationFailed = true; organizationStatus = "Folder data needs recovery. Original file kept. \(error.localizedDescription)" }
        if !["all", "unfiled"].contains(folderScope), !organization.folders.contains(where: { $0.id.uuidString == folderScope }) { folderScope = "all" }
    }
    func chooseFolder(_ scope: String) {
        guard !occupied, questionSnapshot == nil, ["all", "unfiled"].contains(scope) || organization.folders.contains(where: { $0.id.uuidString == scope }) else { return }
        folderScope = scope; UserDefaults.standard.set(scope, forKey: "meetingFolder"); libraryPage = 0
        resetQuestion(); searchLibrary(); organizationStatus = ""
    }
    func changeFolder(command: String, id: String, name: String) {
        guard !occupied, questionSnapshot == nil, let store, !organizationFailed || command == "folderUndo" else { return }
        do {
            var next = organization
            switch command {
            case "folderCreate": let created = try next.create(name); try store.saveOrganization(next); organization = next; chooseFolder(created.uuidString); organizationStatus = "Folder created"
            case "folderRename": guard let uuid = UUID(uuidString: id) else { return }; try next.rename(uuid, name: name); try store.saveOrganization(next); organization = next; organizationStatus = "Folder renamed"
            case "folderRemove": guard let uuid = UUID(uuidString: id) else { return }; try next.remove(uuid); try store.saveOrganization(next); organization = next; chooseFolder("unfiled"); organizationStatus = "Folder removed · recordings kept in Unfiled"
            case "folderMove":
                guard let selected, id == "unfiled" || UUID(uuidString: id) != nil else { return }
                _ = try store.load(selected.id); try next.move(selected.id, to: UUID(uuidString: id)); try store.saveOrganization(next); organization = next; organizationStatus = "Meeting moved · recordings and links kept"
            case "folderUndo":
                guard store.hasPreviousOrganization else { return }
                next = try store.organization(previous: true)
                // Recovery never overwrites a damaged current index.
                if organizationFailed {
                    let damaged = store.root.appendingPathComponent("folders-v1.json")
                    let backup = store.root.appendingPathComponent("folders.recovery-" + UUID().uuidString + ".json")
                    try FileManager.default.copyItem(at: damaged, to: backup)
                    try store.saveOrganization(next, preservePrevious: false)
                } else { try store.saveOrganization(next) }
                organization = next; organizationFailed = false; chooseFolder("all"); organizationStatus = "Previous folder arrangement restored"
            default: return
            }
            libraryPage = 0
        } catch { organizationStatus = error.localizedDescription }
    }
    func fileNewMeeting(_ id: UUID, scope: String) {
        guard !organizationFailed, let folder = UUID(uuidString: scope), organization.folders.contains(where: { $0.id == folder }), let store else { return }
        do { var next = organization; try next.move(id, to: folder); try store.saveOrganization(next); organization = next }
        catch { organizationStatus = "Meeting saved in Unfiled. \(error.localizedDescription)" }
    }
    func chooseRecordingImport() {
        guard !occupied, !organizationFailed, canStart?() != false else { return }
        let panel = NSOpenPanel(); panel.title = "Import recording"; panel.message = "Choose audio or video. Nero Voice saves its own audio copy; your original stays intact."
        panel.prompt = "Import recording"; panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie] + ["caf", "m4a", "mp3", "wav", "aiff", "mp4", "mov", "flac"].compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        importPicker = panel; choosingImport = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in Task { @MainActor in
            guard let self else { return }; self.importPicker = nil; self.choosingImport = false
            guard response == .OK, let url = panel.url, !self.occupied else { return }; self.importRecording(url)
        } }
        panel.makeKeyAndOrderFront(nil)
    }
    func importRecording(_ source: URL) {
        guard !occupied, !organizationFailed, let store, canStart?() != false else { return }
        stopPlayback(); resetCatchUp(); resetQuestion(); cancelCalendar(); calendarPickerOpen = false
        let scope = folderScope, epoch = UUID(); importEpoch = epoch; importing = true; importProgress = 0; importStatus = "Importing \(source.lastPathComponent)…"
        let progress = ImportProgress { [weak self] value in Task { @MainActor in
            guard let self, self.importEpoch == epoch, self.importing else { return }; self.importProgress = value
        } }
        let worker = Task.detached(priority: .utility) { try await MeetingRecordingImport.run(source: source, store: store) { progress.update($0) } }
        importWorker = worker
        importTask = Task { [weak self] in
            do {
                let meeting = try await worker.value
                guard let self, self.importEpoch == epoch else { return }
                self.importing = false; self.importWorker = nil; self.importTask = nil
                let duplicate = self.library.contains { $0.id == meeting.id }; if !duplicate { self.fileNewMeeting(meeting.id, scope: scope) }; self.refresh(); self.select(meeting.id); self.notebookPage = "transcript"
                self.importStatus = duplicate ? "Already imported · opened the existing meeting" : "Imported · original unchanged"; self.status = "Recording saved on this Mac · choose Transcribe to create its transcript"
            } catch {
                guard let self, self.importEpoch == epoch else { return }
                self.importing = false; self.importWorker = nil; self.importTask = nil
                self.importStatus = error is CancellationError ? "Import cancelled · no partial recording saved" : "Import failed: \(error.localizedDescription)"
            }
        }
    }
    func cancelImport() { guard importing else { return }; importWorker?.cancel(); importStatus = "Cancelling import…" }
}

private final class ImportProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0
    private let changed: @Sendable (Double) -> Void
    init(changed: @escaping @Sendable (Double) -> Void) { self.changed = changed }
    func update(_ value: Double) {
        lock.lock(); let now = ProcessInfo.processInfo.systemUptime
        let emit = value == 1 || now - last > 0.15; if emit { last = now }; lock.unlock()
        if emit { changed(value) }
    }
}
