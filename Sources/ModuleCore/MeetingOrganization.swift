import Foundation

public struct MeetingFolder: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public init(name: String) { id = UUID(); self.name = name }
}

/// Membership never changes recording paths or their citation identities.
public struct MeetingOrganization: Codable, Equatable, Sendable {
    public var version = 1
    public var folders: [MeetingFolder] = []
    public var membership: [String: UUID] = [:]
    public init() {}
    public func validate() throws {
        guard version == 1, folders.count <= 40, Set(folders.map(\.id)).count == folders.count,
              membership.count <= 10000, Set(folders.map { $0.name.lowercased() }).count == folders.count,
              folders.allSatisfy({ !$0.name.isEmpty && $0.name == $0.name.trimmingCharacters(in: .whitespacesAndNewlines) && $0.name.utf8.count <= 80 && !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              membership.allSatisfy({ item in UUID(uuidString: item.key)?.uuidString == item.key && folders.contains(where: { $0.id == item.value }) }) else {
            throw VoiceProblem.message("Folder data is invalid or exceeds its limit")
        }
    }
    @discardableResult public mutating func create(_ name: String) throws -> UUID {
        var next = self; let folder = MeetingFolder(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        next.folders.append(folder); try next.validate(); self = next; return folder.id
    }
    public mutating func rename(_ id: UUID, name: String) throws {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { throw VoiceProblem.message("Folder no longer exists") }
        var next = self; next.folders[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines); try next.validate(); self = next
    }
    public mutating func remove(_ id: UUID) throws {
        guard folders.contains(where: { $0.id == id }) else { throw VoiceProblem.message("Folder no longer exists") }
        folders.removeAll { $0.id == id }; membership = membership.filter { $0.value != id }; try validate()
    }
    public mutating func move(_ meeting: UUID, to folder: UUID?) throws {
        var next = self; next.membership[meeting.uuidString] = folder; try next.validate(); self = next
    }
    public func contains(_ meeting: UUID, scope: String) -> Bool {
        if scope == "all" { return true }
        if scope == "unfiled" { return membership[meeting.uuidString] == nil }
        return UUID(uuidString: scope).map { membership[meeting.uuidString] == $0 } ?? false
    }
}

extension MeetingStore {
    private func organizationURL(previous: Bool) throws -> URL {
        let parent = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parent.isDirectory == true, parent.isSymbolicLink != true else { throw VoiceProblem.message("Meeting library unavailable") }
        let url = root.appendingPathComponent(previous ? "folders.previous-v1.json" : "folders-v1.json")
        if FileManager.default.fileExists(atPath: url.path) {
            let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 1_000_000 else { throw VoiceProblem.message("Folder file unavailable or oversized") }
        }
        return url
    }
    public func organization(previous: Bool = false) throws -> MeetingOrganization {
        let url = try organizationURL(previous: previous)
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let value = try JSONDecoder().decode(MeetingOrganization.self, from: Data(contentsOf: url)); try value.validate(); return value
    }
    public var hasPreviousOrganization: Bool { (try? organizationURL(previous: true)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    public func saveOrganization(_ value: MeetingOrganization, preservePrevious: Bool = true) throws {
        try value.validate(); let current = try organizationURL(previous: false), data = try JSONEncoder().encode(value)
        guard data.count <= 1_000_000 else { throw VoiceProblem.message("Folder storage limit reached") }
        if preservePrevious, FileManager.default.fileExists(atPath: current.path) {
            _ = try organization(); let previous = try organizationURL(previous: true)
            try Data(contentsOf: current).write(to: previous, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
        } else if preservePrevious {
            let previous = try organizationURL(previous: true)
            try JSONEncoder().encode(MeetingOrganization()).write(to: previous, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
        }
        try data.write(to: current, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
    }
}

public struct MeetingImportOrigin: Codable, Equatable, Sendable {
    public let version: Int
    public let meetingID: UUID
    public let filename: String
    public let bytes: Int
    public let sha256: String
    public let imported: Date
    public init(meetingID: UUID, filename: String, bytes: Int, sha256: String) {
        version = 1; self.meetingID = meetingID; self.filename = String(filename.prefix(180)); self.bytes = bytes; self.sha256 = sha256; imported = Date()
    }
    public func validate() throws {
        guard version == 1, !filename.isEmpty, filename.utf8.count <= 720, !filename.contains("/"), !filename.contains("\\"),
              bytes > 0, bytes <= 2_000_000_000, sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }), imported.timeIntervalSince1970.isFinite else { throw VoiceProblem.message("Invalid recording import information") }
    }
}
extension MeetingStore {
    public func importOrigin(_ id: UUID) throws -> MeetingImportOrigin? {
        _ = try load(id); let url = folder(id).appendingPathComponent("import-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 4096 else { throw VoiceProblem.message("Recording import information unavailable") }
        let value = try JSONDecoder().decode(MeetingImportOrigin.self, from: Data(contentsOf: url)); try value.validate()
        guard value.meetingID == id else { throw VoiceProblem.message("Recording import identity changed") }; return value
    }
}
