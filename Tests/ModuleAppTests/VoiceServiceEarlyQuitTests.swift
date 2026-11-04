import AppKit
import XCTest
import Darwin
@testable import ModuleApp

@MainActor final class VoiceServiceEarlyQuitTests: XCTestCase {
    func testUnboundDelegateDefersTerminationUntilBootstrapCanOwnQuit() {
        let delegate = VoiceServiceAppDelegate()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
    }

    @MainActor private final class HeldOriginal {
        private let arrival = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { original in
                continuation = original
                arrival.continuation.yield(())
            }
        }
        func entered() async {
            var iterator = arrival.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        func release() {
            released = true
            let original = continuation; continuation = nil
            original?.resume()
            arrival.continuation.finish()
        }
    }

    func testPendingQuitJoinsActualBootstrapOriginalStartupBeforeReply() async throws {
        let held = HeldOriginal(); defer { held.release() }
        let originalStart = Task { @MainActor in await held.wait() }
        await held.entered()
        let bootstrap = VoiceServiceBootstrap(retainedStartup: originalStart)
        let enteredShutdown = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var replies: [Bool] = []
        let delegate = VoiceServiceAppDelegate(shutdown: { original in
            enteredShutdown.continuation.yield(())
            enteredShutdown.continuation.finish()
            return await original.shutdown()
        }, reply: { _, clean in replies.append(clean) })
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertNil(delegate.terminationCompletion)
        delegate.bootstrap = bootstrap
        let originalQuit = try XCTUnwrap(delegate.terminationCompletion)
        var entered = enteredShutdown.stream.makeAsyncIterator()
        let shutdownSignal = await entered.next()
        XCTAssertNotNil(shutdownSignal)
        XCTAssertTrue(replies.isEmpty)
        // This is the actual bootstrap's irreversible retiring guard while its
        // original startup is still held; no replacement cleanup is invoked.
        let repeatedShutdown = await bootstrap.shutdown()
        XCTAssertFalse(repeatedShutdown)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        held.release()
        await originalQuit.value
        await originalStart.value
        XCTAssertEqual(replies, [true])
    }

    func testBoundSharedQuitRetainsOriginalUntilShutdownReturns() async throws {
        let bootstrap = VoiceServiceBootstrap(retainedStartup: Task {})
        let held = HeldOriginal(); defer { held.release() }
        var calls = 0
        var replies: [Bool] = []
        let delegate = VoiceServiceAppDelegate(shutdown: { original in
            XCTAssertTrue(original === bootstrap)
            calls += 1
            await held.wait()
            return await original.shutdown()
        }, reply: { _, clean in replies.append(clean) })
        delegate.bootstrap = bootstrap
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        let original = try XCTUnwrap(delegate.terminationCompletion)
        await held.entered()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(replies.isEmpty)
        held.release()
        await original.value
        XCTAssertEqual(replies, [true])
    }

    func testDuplicateQuitAndLateBindingCannotRetargetOriginal() async throws {
        let first = VoiceServiceBootstrap(retainedStartup: Task {})
        let replacement = VoiceServiceBootstrap(retainedStartup: Task {})
        let held = HeldOriginal(); defer { held.release() }
        var originals: [ObjectIdentifier] = []
        var replies: [Bool] = []
        let delegate = VoiceServiceAppDelegate(shutdown: { original in
            originals.append(ObjectIdentifier(original))
            await held.wait()
            return await original.shutdown()
        }, reply: { _, clean in replies.append(clean) })
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        delegate.bootstrap = first
        let original = try XCTUnwrap(delegate.terminationCompletion)
        delegate.bootstrap = replacement
        delegate.bootstrap = nil
        delegate.bootstrap = first
        await held.entered()
        XCTAssertTrue(delegate.bootstrap === first)
        XCTAssertEqual(originals, [ObjectIdentifier(first)])
        XCTAssertTrue(replies.isEmpty)
        held.release()
        await original.value
        XCTAssertEqual(replies, [true])
    }

    func testFalseDrainRepliesFalseRetainsOwnerAndNeverInventsRetry() async throws {
        var bootstrap: VoiceServiceBootstrap? = VoiceServiceBootstrap(retainedStartup: Task {})
        weak var originalOwner = bootstrap
        var calls = 0
        var replies: [Bool] = []
        let delegate = VoiceServiceAppDelegate(shutdown: { _ in calls += 1; return false },
            reply: { _, clean in replies.append(clean) })
        delegate.bootstrap = bootstrap
        bootstrap = nil
        XCTAssertNotNil(originalOwner)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        let original = try XCTUnwrap(delegate.terminationCompletion)
        await original.value
        XCTAssertEqual(replies, [false])
        XCTAssertNotNil(originalOwner)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(replies, [false])
    }

    private struct IsolatedProduct: Sendable {
        let parent: URL
        let device: dev_t
        let inode: ino_t
        init() throws {
            parent = URL(fileURLWithPath: try VoiceProductConfiguration.physicalPath(FileManager.default.temporaryDirectory), isDirectory: true)
                .appendingPathComponent("VoiceQuit-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var value = stat()
            guard lstat(parent.path, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
            device = value.st_dev; inode = value.st_ino
        }
        func validate() throws {
            var value = stat()
            guard lstat(parent.path, &value) == 0, value.st_dev == device, value.st_ino == inode,
                  value.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileReadUnknown) }
        }
        @MainActor func plugin() throws -> VoicePlugin {
            VoicePlugin(sharedService: false, configuration: try .isolated(root: parent.appendingPathComponent("Product", isDirectory: true),
                revalidate: { try self.validate() }))
        }
        func remove() { try? FileManager.default.removeItem(at: parent) }
    }

    func testActualBoundLegacyProductCanTerminateNow() throws {
        let fixture = try IsolatedProduct(); defer { fixture.remove() }
        let plugin = try fixture.plugin()
        let bootstrap = VoiceServiceBootstrap(legacyPlugin: plugin)
        var replies: [Bool] = []
        let delegate = VoiceServiceAppDelegate(reply: { _, clean in replies.append(clean) })
        delegate.bootstrap = bootstrap
        XCTAssertTrue(bootstrap.legacy === plugin)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertNil(delegate.terminationCompletion)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertFalse(plugin.hasAmbientProductObservers)
        XCTAssertFalse(plugin.model.nativeSpeechOutputIsConstructed)
    }

    func testPendingQuitGetsReplyOnlyAfterActualLegacyBinding() async throws {
        let fixture = try IsolatedProduct(); defer { fixture.remove() }
        let plugin = try fixture.plugin()
        let bootstrap = VoiceServiceBootstrap(legacyPlugin: plugin)
        var shutdowns = 0
        var replies: [Bool] = []
        let delegate = VoiceServiceAppDelegate(shutdown: { _ in shutdowns += 1; return false },
            reply: { _, clean in replies.append(clean) })
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateLater)
        XCTAssertTrue(replies.isEmpty)
        delegate.bootstrap = bootstrap
        let original = try XCTUnwrap(delegate.terminationCompletion)
        await original.value
        XCTAssertEqual(shutdowns, 0)
        XCTAssertEqual(replies, [true])
    }
}
