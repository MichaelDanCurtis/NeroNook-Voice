import XCTest
import Foundation
@testable import ModuleApp

final class VoiceServiceBootstrapTests: XCTestCase {
    private func bundle(kind: String, identifier: String = "example.authored.invalid") throws -> (Bundle, URL) {
        let root = URL(fileURLWithPath: "/private/tmp/voice-entry-" + UUID().uuidString + ".bundle")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "Authored entry refusal",
            "CFBundlePackageType": "BNDL", "NeroVoiceRuntimeKind": kind]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return (try XCTUnwrap(Bundle(url: root)), root)
    }
    @MainActor func testUnknownSelectedKindDoesNotConstructLegacyOrResourceRuntime() throws {
        let (bundle, root) = try bundle(kind: "not-a-supported-kind")
        defer { try? FileManager.default.removeItem(at: root) }
        let bootstrap = VoiceServiceBootstrap(bundle: bundle)
        XCTAssertNil(bootstrap.legacy); XCTAssertNil(bootstrap.runtime)
        XCTAssertTrue(bootstrap.status.contains("No resources have started"))
    }
    @MainActor func testSelectedSharedKindWithWrongBundleIdentityCannotFallBackToLegacy() throws {
        let (bundle, root) = try bundle(kind: "shared-service-v1")
        defer { try? FileManager.default.removeItem(at: root) }
        let bootstrap = VoiceServiceBootstrap(bundle: bundle)
        XCTAssertNil(bootstrap.legacy); XCTAssertNil(bootstrap.runtime)
        XCTAssertTrue(bootstrap.status.contains("could not verify native ownership"))
    }
    func testViewRevisionPreservesLeadingCombiningFilenameBytes() throws {
        let root = URL(fileURLWithPath: "/private/tmp/voice-views-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("authored index".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("authored combining path".utf8).write(to: root.appendingPathComponent("\u{0301}echo.txt"))
        // Independent Python hashlib vector: sorted exact UTF8 relative path,
        // NUL, raw32 file SHA256, NUL. Not hex-file-digest concatenation.
        XCTAssertEqual(try VoiceServicePolicy.viewsRevision(root),
                       "945feaf79d22d3b838d7bf5a2a528e7b7cf683bfb83eb5504b856e2a34dcfd7e")
    }

    func testBundleStyleAliasAndPhysicalRootPreserveExactCombiningFileDigest() throws {
        let root = URL(fileURLWithPath: "/private/tmp/voice-alias-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("authored index".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("authored combining path".utf8).write(to: root.appendingPathComponent("\u{0301}echo.txt"))
        let alias = URL(fileURLWithPath: String(root.path.dropFirst("/private".count)), isDirectory: true)
        // Same independent Python hashlib vector as the original physical-only
        // case; aliases must not change relative UTF8 bytes or admit a link leaf.
        let expected = "945feaf79d22d3b838d7bf5a2a528e7b7cf683bfb83eb5504b856e2a34dcfd7e"
        XCTAssertEqual(try VoiceServicePolicy.viewsRevision(alias), expected)
        XCTAssertEqual(try VoiceServicePolicy.viewsRevision(root), expected)
    }

}
