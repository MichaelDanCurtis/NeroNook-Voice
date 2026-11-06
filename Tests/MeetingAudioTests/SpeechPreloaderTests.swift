import XCTest
import Foundation
import Darwin
import Combine
import ModuleCore
@testable import VoiceAudio

final class SpeechPreloaderTests: XCTestCase {
    @MainActor private func fixture(hold: Duration = .seconds(10), slowExit: Bool = false, slowReady: Bool = false) throws -> (SpeechPreloader, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NeroPreload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("worker.py"), marker = folder.appendingPathComponent("input")
        try Data(Self.worker.utf8).write(to: script)
        let pool = SpeechPreloader(hold: hold) { service, _, _, _ in
            try await service.startPreparedWorker(executable: URL(fileURLWithPath:"/usr/bin/python3"),
                arguments:[script.path,marker.path,folder.appendingPathComponent("pid").path,slowExit ? "slow-exit":"normal",slowReady ? "slow-ready":"normal"], update:{ _ in }, failure:{ _ in })
        }
        return (pool, marker)
    }
    @MainActor func testPreparationHasNoAudioAndTransfersOnceToFreshCallbacks() async throws {
        let (pool, marker) = try fixture(); defer { pool.release() }
        let helper = URL(fileURLWithPath:"/authored-helper")
        try await pool.prepare(provider:.nemotron,locale:"en-US",helper:helper)
        XCTAssertTrue(pool.ready); XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
        var received = ""
        let service = try XCTUnwrap(pool.take(provider:.nemotron,locale:"en-US",helper:helper,update:{received=$0.text},failure:{_ in}))
        defer { service.cancel() }
        XCTAssertFalse(pool.ready)
        XCTAssertNil(pool.take(provider:.nemotron,locale:"en-US",helper:helper,update:{_ in},failure:{_ in}))
        service.feed.append(.init(track:"mic",start:0,pcm:Data(repeating:0,count:640)))
        for _ in 0..<100 where received.isEmpty { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(received,"Prepared recognizer used")
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        try await service.finish()
    }
    @MainActor func testWrongModelLanguageOrHelperNeverBorrowsPreparedState() async throws {
        let (pool, _) = try fixture(); defer { pool.release() }
        let helper=URL(fileURLWithPath:"/authored-helper")
        for (provider,locale,path) in [(VoiceASRProvider.parakeet,"en-US",helper),(.nemotron,"fr-FR",helper),(.nemotron,"en-US",URL(fileURLWithPath:"/different"))] {
            try await pool.prepare(provider:.nemotron,locale:"en-US",helper:helper)
            XCTAssertNil(pool.take(provider:provider,locale:locale,helper:path,update:{_ in},failure:{_ in}))
            XCTAssertFalse(pool.ready)
        }
    }
    @MainActor func testIdleExpiryAndOtherModelWorkReleaseTheLease() async throws {
        let (pool, _) = try fixture(hold:.milliseconds(80)); defer { pool.release() }
        let helper=URL(fileURLWithPath:"/authored-helper")
        try await pool.prepare(provider:.nemotron,locale:"en-US",helper:helper)
        try await Task.sleep(for:.milliseconds(150)); XCTAssertFalse(pool.ready)
        let (longPool, _) = try fixture(); defer { longPool.release() }
        try await longPool.prepare(provider:.nemotron,locale:"en-US",helper:helper)
        try await LocalModelProcess.waitForAvailable()
        XCTAssertFalse(longPool.ready)
    }
    @MainActor func testReleaseDuringPreparationCannotPublishReadyLater() async throws {
        let pool = SpeechPreloader(hold:.seconds(10)) { _, _, _, _ in
            try await Task.sleep(for:.milliseconds(100))
        }
        let pending=Task { try await pool.prepare(provider:.nemotron,locale:"en-US",helper:URL(fileURLWithPath:"/unused")) }
        for _ in 0..<20 where !pool.preparing { await Task.yield() }
        pool.release()
        do { try await pending.value; XCTFail("Retired preparation succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(pool.ready); XCTAssertFalse(pool.preparing)
    }
    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw NSError(domain: "SpeechPreloaderTests", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor private func pid(_ marker: URL) throws -> pid_t {
        let value = try XCTUnwrap(pid_t(String(contentsOf: marker.deletingLastPathComponent().appendingPathComponent("pid"), encoding: .utf8)))
        XCTAssertGreaterThan(value, 1); return value
    }
    @MainActor private func assertReaped(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        let present = kill(pid, 0), presenceError = errno
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG), waitError = errno
        XCTAssertEqual(present, -1, file: file, line: line); XCTAssertEqual(presenceError, ESRCH, file: file, line: line)
        XCTAssertEqual(waited, -1, file: file, line: line); XCTAssertEqual(waitError, ECHILD, file: file, line: line)
    }
    @MainActor func testReplacementWaitsForActualPriorWorkerRetirement() async throws {
        let (pool, marker) = try fixture(slowExit: true)
        defer { pool.release() }
        let helper = URL(fileURLWithPath: "/authored-helper")
        try await pool.prepare(provider: .nemotron, locale: "en-US", helper: helper)
        let first = try pid(marker)
        pool.release(); let original = pool.retirementCompletion()
        XCTAssertTrue(pool.busy); XCTAssertTrue(pool.retiring)
        let replacement = Task { try await pool.prepare(provider: .nemotron, locale: "en-US", helper: helper) }
        await original?.value; assertReaped(first)
        try await replacement.value
        let second = try pid(marker); XCTAssertNotEqual(first, second)
        let launchData = try Data(contentsOf: marker.deletingLastPathComponent().appendingPathComponent("launches"))
        let launches = try launchData.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        XCTAssertEqual(launches.count, 2)
        XCTAssertEqual(launches.last?["previousAlive"] as? Bool, false, "Replacement started before original worker exited")
        pool.release(); await pool.retirementCompletion()?.value
        assertReaped(second); XCTAssertFalse(pool.busy)
    }
    @MainActor func testReleaseDuringActualWorkerOpeningRetainsBusyUntilReturnAndReap() async throws {
        let (pool, marker) = try fixture(slowReady: true)
        defer { pool.release() }
        let pending = Task { try await pool.prepare(provider: .nemotron, locale: "en-US", helper: URL(fileURLWithPath: "/authored-helper")) }
        try await waitFor { FileManager.default.fileExists(atPath: marker.deletingLastPathComponent().appendingPathComponent("pid").path) }
        let originalPID = try pid(marker)
        pool.release(); let original = pool.retirementCompletion()
        XCTAssertTrue(pool.busy)
        do { try await pending.value; XCTFail("Released worker preparation succeeded") } catch {}
        await original?.value; await pool.retirementCompletion()?.value
        assertReaped(originalPID)
        XCTAssertFalse(pool.busy); XCTAssertFalse(pool.ready); XCTAssertFalse(pool.preparing)
    }
    @MainActor func testReentrantReleaseDuringReadyPublicationCannotLeaveReadyOrOwnedWorker() async throws {
        let (pool, marker) = try fixture()
        defer { pool.release() }
        var released = false
        let watch = pool.objectWillChange.sink {
            if !released, pool.status.hasPrefix("Talk ready"), !pool.preparing, !pool.ready {
                released = true; pool.release()
            }
        }
        defer { watch.cancel() }
        do { try await pool.prepare(provider: .nemotron, locale: "en-US", helper: URL(fileURLWithPath: "/authored-helper")); XCTFail("Retired ready publication succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await pool.retirementCompletion()?.value
        XCTAssertTrue(released); XCTAssertFalse(pool.ready); XCTAssertFalse(pool.preparing); XCTAssertFalse(pool.busy)
        assertReaped(try pid(marker))
    }
    @MainActor func testReleaseDuringInitialReleaseCannotBecomeANewPreparation() async throws {
        var started = 0, released = false
        let pool = SpeechPreloader(hold: .seconds(10)) { _, _, _, _ in started += 1 }
        let watch = pool.objectWillChange.sink {
            if !released { released = true; pool.release() }
        }
        defer { watch.cancel(); pool.release() }
        do { try await pool.prepare(provider: .nemotron, locale: "en-US", helper: URL(fileURLWithPath: "/unused")); XCTFail("Cancelled initial publication restarted preparation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await pool.retirementCompletion()?.value
        XCTAssertEqual(started, 0); XCTAssertTrue(released)
        XCTAssertFalse(pool.busy); XCTAssertFalse(pool.preparing); XCTAssertFalse(pool.ready)
    }
    @MainActor func testReleaseDuringLoadingStatusPublicationPreservesReleasedStatus() async throws {
        let (pool, marker) = try fixture()
        var released = false
        let watch = pool.objectWillChange.sink {
            if !released, pool.preparing, pool.status == "Prepared model released · microphone off" {
                released = true; pool.release()
            }
        }
        defer { watch.cancel(); pool.release() }
        do { try await pool.prepare(provider: .nemotron, locale: "en-US", helper: URL(fileURLWithPath: "/unused")); XCTFail("Retired loading status succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await pool.retirementCompletion()?.value
        XCTAssertTrue(released); XCTAssertFalse(pool.busy)
        XCTAssertEqual(pool.status, "Prepared model released · microphone off")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.deletingLastPathComponent().appendingPathComponent("pid").path))
    }
    @MainActor func testReleaseDuringReadyStatusPublicationPreservesReleasedStatusAndReapsWorker() async throws {
        let (pool, marker) = try fixture()
        var released = false
        let watch = pool.objectWillChange.sink {
            if !released, pool.preparing, pool.status == "Loading selected speech model · microphone off" {
                released = true; pool.release()
            }
        }
        defer { watch.cancel(); pool.release() }
        do { try await pool.prepare(provider: .nemotron, locale: "en-US", helper: URL(fileURLWithPath: "/unused")); XCTFail("Retired ready status succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        await pool.retirementCompletion()?.value
        XCTAssertTrue(released); XCTAssertFalse(pool.busy); XCTAssertFalse(pool.ready)
        XCTAssertEqual(pool.status, "Prepared model released · microphone off")
        assertReaped(try pid(marker))
    }
    private static let worker = #"""
import sys,json,struct,os,signal,time
from pathlib import Path
pidfile=Path(sys.argv[2]);previousAlive=False
if pidfile.exists():
    try: os.kill(int(pidfile.read_text()),0);previousAlive=True
    except ProcessLookupError: pass
with (pidfile.parent/'launches').open('a') as f: f.write(json.dumps({'pid':os.getpid(),'previousAlive':previousAlive})+'\n')
pidfile.write_text(str(os.getpid()))
if sys.argv[3]=='slow-exit':signal.signal(signal.SIGTERM,signal.SIG_IGN)
while sys.argv[4]=='slow-ready' and not (pidfile.parent/'allow-ready').exists():time.sleep(0.01)
def emit(x): print(json.dumps(x),flush=True)
def read(n):
    b=b''
    while len(b)<n:
        q=sys.stdin.buffer.read(n-len(b))
        if not q: raise EOFError()
        b+=q
    return b
emit({'type':'ready','version':2})
while True:
    n=struct.unpack('<I',read(4))[0]
    if n==0: break
    h=json.loads(read(n));read(h['length']);Path(sys.argv[1]).touch()
    emit({'type':'final','track':'mic','start':h['start'],'end':h['start']+h['length']/64000,'text':'Prepared recognizer used'})
    emit({'type':'ack'})
emit({'type':'closed'})
"""#
}
